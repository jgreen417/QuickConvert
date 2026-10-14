import Foundation

struct ConversionError: LocalizedError {
    let message: String
    /// false when retrying can't help (missing input, unsupported format pair).
    let retryable: Bool
    init(_ message: String, retryable: Bool = true) { self.message = message; self.retryable = retryable }
    var errorDescription: String? { message }
}

struct CancelledError: Error {}

/// The document is encrypted. The app asks for the password and retries with it.
struct PasswordRequired: LocalizedError {
    let wrong: Bool
    var errorDescription: String? { wrong ? "Incorrect password" : "This document is password-protected" }
}

/// Converts one file. Engines only ever see fixed names inside a private per-job staging
/// directory (ImageMagick and FFmpeg treat things like `%03d` in paths as patterns), outputs are
/// validated there, then published next to the original with no-overwrite renames.
enum Converter {
    /// QC_NO_OFFICE (tests only) simulates a Mac without LibreOffice.
    static var officeAvailable: Bool {
        ProcessInfo.processInfo.environment["QC_NO_OFFICE"] == nil && FileManager.default.isExecutableFile(atPath: Formats.libreOffice)
    }

    static func validate(_ input: URL, to ext: String) throws {
        var st = stat()
        guard stat(input.path, &st) == 0 else { throw ConversionError("File not found") }
        guard st.st_mode & S_IFMT == S_IFREG else { throw ConversionError("Not a regular file") }
        guard access(input.path, R_OK) == 0 else { throw ConversionError("Can't read the file") }
        guard let kind = Formats.kind(of: input), Formats.targets(for: kind, office: officeAvailable).contains(ext) else {
            throw ConversionError("Can't convert .\(input.pathExtension) to \(Formats.label(ext))")
        }
    }

    /// `progress` (0...1) is reported for audio/video jobs, from a background thread.
    @discardableResult
    static func convert(_ input: URL, to ext: String, password: String? = nil, progress: ((Double) -> Void)? = nil) throws -> [URL] {
        try validate(input, to: ext)
        let kind = Formats.kind(of: input)!
        let srcExt = Formats.normalize(input.pathExtension)
        let job = try Staging(input)
        defer { job.remove() }
        let out = job.out.appendingPathComponent("out.\(ext)")

        switch kind {
        case .image, .svg:
            // rsvg-convert and textutil don't interpret patterns in paths, so they get the original path:
            // that keeps relative references (<image href="logo.png">) resolving next to the source.
            if kind == .svg && ext == "pdf" {
                try run("rsvg-convert", ["-f", "pdf", "-o", out.path, input.path], timeout: 300)
                return try publish([(out, ".\(ext)")], for: input)
            }
            var src = job.input.path
            if kind == .svg {
                let raster = job.input.deletingLastPathComponent().appendingPathComponent("raster.png")
                try run("rsvg-convert", ["-f", "png", "-z", "2", "-o", raster.path, input.path], timeout: 300)
                src = raster.path
            }
            // Keep animation (GIF<->WebP) and pages (TIFF/GIF->TIFF/PDF); otherwise take the first frame,
            // since any animated/multi-image input (WebP, HEIC, AVIF, ICO, PSD layers) would write one file per frame.
            let keepFrames = (["gif", "webp"].contains(ext) && ["gif", "webp"].contains(srcExt))
                || (["tiff", "pdf"].contains(ext) && ["tiff", "gif"].contains(srcExt))
            if kind == .image && (!keepFrames || srcExt == "psd") { src += "[0]" }
            // Bake in EXIF rotation; metadata is otherwise kept.
            var opts = ["-auto-orient"]
            let losslessSource = kind == .svg || ["png", "tiff", "bmp", "gif", "tga", "qoi", "ppm", "exr", "psd", "ico"].contains(srcExt)
            switch ext {
            case "jpg": opts += ["-background", "white", "-alpha", "remove", "-alpha", "off", "-quality", "95", "-sampling-factor", "4:4:4"]
            case "bmp": opts += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
            // Lossless sources stay lossless; photos get near-transparent lossy settings.
            case "webp": opts += losslessSource ? ["-define", "webp:lossless=true", "-quality", "100"] : ["-quality", "95"]
            case "avif", "heic": opts += ["-quality", "90"]
            case "ico": opts += ["-background", "none", "-resize", "256x256>", "-define", "icon:auto-resize=256,128,64,48,32,16"]
            default: break
            }
            try run("magick", [src] + opts + [out.path])
            return try publish([(out, ".\(ext)")], for: input)

        case .pdf:
            // pdftoppm writes out-<n>.<ext>, zero-padded so names sort in page order.
            do {
                try run("pdftoppm", (ext == "jpg" ? ["-jpeg", "-jpegopt", "quality=95"] : ["-png"])
                    + ["-r", "300", job.input.path, job.out.appendingPathComponent("out").path])
            } catch let error as ConversionError where error.message.contains("Incorrect password") {
                throw ConversionError("This PDF is password-protected")
            }
            let pages = job.outputs()
            if let expected = pageCount(job.input), pages.count != expected {
                throw ConversionError("Rendered \(pages.count) of \(expected) pages")
            }
            return try publish(pages.map { ($0, String($0.lastPathComponent.dropFirst(3))) }, for: input)

        case .video, .audio:
            try ffmpeg(job.input, out, ext, kind, progress: progress)
            return try publish([(out, ".\(ext)")], for: input)

        case .text, .slides, .sheet:
            // Protected documents are decrypted to a staged copy first (needs the password from the user).
            var doc = job.input
            // Legacy .doc/.xls/.ppt can't be checked up front, so a supplied password means "decrypt it".
            if try isEncrypted(input, srcExt) || (password != nil && ["doc", "xls", "ppt"].contains(srcExt)) {
                doc = try decrypt(job, srcExt, password: password)
            }

            // Undecrypted .doc goes to LibreOffice when present: it detects encryption, where textutil
            // would turn an encrypted file into pages of garbage.
            let legacyWordViaOffice = srcExt == "doc" && doc == job.input && officeAvailable
            if kind == .text && ext != "pdf" && !legacyWordViaOffice {
                try checkDocumentSignature(doc, srcExt)
                if doc == job.input && srcExt == "doc" && wordDocumentIsEncrypted(doc) {
                    throw ConversionError("This document is password-protected. Install LibreOffice to convert protected documents.")
                }
                // The original path keeps relative references (HTML images) resolving; a decrypted copy has none.
                try run("textutil", ["-convert", ext, doc == job.input ? input.path : doc.path, "-output", out.path], timeout: 300)
                let size = (try? out.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0 else {
                    throw ConversionError("Couldn't read this document. It may be damaged.")
                }
                return try publish([(out, ".\(ext)")], for: input)
            }

            // Private profile per job: isolated from the GUI and from parallel jobs, removed with the staging dir.
            let profile = job.dir.appendingPathComponent("profile").absoluteString
            do {
                try run(Formats.libreOffice, ["-env:UserInstallation=\(profile)", "--headless",
                                              "--convert-to", ext, "--outdir", job.out.path, doc.path], timeout: 600)
            } catch let error as ConversionError where error.message.contains("could not be loaded") {
                // Legacy .doc/.xls/.ppt don't reveal encryption up front; a load failure may mean a password.
                if doc == job.input && ["doc", "xls", "ppt"].contains(srcExt) && password == nil {
                    throw PasswordRequired(wrong: false)
                }
                throw ConversionError("LibreOffice couldn't open this file. It may be damaged.")
            }
            let produced = job.out.appendingPathComponent("\(doc.deletingPathExtension().lastPathComponent).\(ext)")
            if ext == "txt" { stripByteOrderMark(produced) } // LibreOffice's text export starts with one; textutil's doesn't
            return try publish([(produced, ".\(ext)")], for: input)
        }
    }

    /// textutil reads anything it doesn't recognise as plain text and exits 0, so an encrypted or damaged
    /// DOCX would "convert" into pages of binary garbage. Check the container signature first.
    private static func checkDocumentSignature(_ url: URL, _ srcExt: String) throws {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 8))
        let zip = head.starts(with: [0x50, 0x4B, 0x03, 0x04])
        let compound = head.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) // OLE: legacy .doc, encrypted OOXML
        let rtf = head.starts(with: Array("{\\rtf".utf8))
        let damaged = ConversionError("This file isn't a valid .\(srcExt) document. It may be damaged.")
        switch srcExt {
        case "docx":
            if !zip { throw damaged }
        case "odt":
            if !zip { throw damaged }
        case "doc":
            // Word also saves RTF and HTML with a .doc name; textutil handles those fine.
            if !(compound || rtf || head.first == UInt8(ascii: "<")) { throw damaged }
        case "rtf":
            if !rtf { throw damaged }
        default:
            break // txt/html: any text is valid input
        }
    }

    /// Encrypted OOXML is an OLE compound file instead of a zip; encrypted ODF lists encryption data in its manifest.
    private static func isEncrypted(_ url: URL, _ srcExt: String) throws -> Bool {
        switch srcExt {
        case "docx", "xlsx", "pptx":
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
            defer { try? handle.close() }
            return [UInt8](handle.readData(ofLength: 8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        case "odt", "ods", "odp":
            let manifest = (try? run("unzip", ["-p", url.path, "META-INF/manifest.xml"], timeout: 30)) ?? ""
            return manifest.contains("encryption-data")
        default:
            return false
        }
    }

    /// Checks only the first 3 bytes; when there is a BOM, streams the rest into a new file in 1 MB chunks
    /// instead of loading the whole export into memory.
    private static func stripByteOrderMark(_ url: URL) {
        guard let input = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? input.close() }
        guard input.readData(ofLength: 3) == Data([0xEF, 0xBB, 0xBF]) else { return }
        let trimmed = url.appendingPathExtension("trimmed")
        guard FileManager.default.createFile(atPath: trimmed.path, contents: nil),
              let output = FileHandle(forWritingAtPath: trimmed.path) else { return }
        while case let chunk = input.readData(ofLength: 1 << 20), !chunk.isEmpty { output.write(chunk) }
        try? output.close()
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: trimmed)
    }

    /// Reads the fEncrypted flag from a Word 97–2003 file. Walks the OLE compound file: FAT from the header's
    /// DIFAT, the directory chain to the "WordDocument" stream (in the mini stream when it's small), then
    /// checks the FIB: magic 0xA5EC at 0x00 and bit 8 of the flags word at 0x0A.
    private static func wordDocumentIsEncrypted(_ url: URL) -> Bool {
        // Memory-mapped and read in place: only the header, FAT and directory pages are touched.
        guard let b = try? Data(contentsOf: url, options: .alwaysMapped), b.count >= 512 else { return false }
        func u16(_ o: Int) -> Int { o >= 0 && o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let end = 0xFFFF_FFFA
        let sectorSize = 1 << u16(0x1E), miniSize = 1 << u16(0x20), cutoff = u32(0x38)
        guard sectorSize >= 512, sectorSize <= 4096 else { return false }

        var fat: [Int] = []
        for i in 0..<109 {
            let sector = u32(0x4C + 4 * i)
            guard sector < end else { break }
            let base = (sector + 1) * sectorSize
            fat += (0..<sectorSize / 4).map { u32(base + $0 * 4) }
        }
        func chain(_ start: Int) -> [Int] {
            var out: [Int] = [], s = start
            while s < end, s < fat.count, out.count < fat.count { out.append(s); s = fat[s] }
            return out
        }

        let target = Array("WordDocument".utf16)
        var rootStart = -1
        for sector in chain(u32(0x30)) {
            for slot in 0..<sectorSize / 128 {
                let e = (sector + 1) * sectorSize + slot * 128
                let length = max(u16(e + 0x40) / 2 - 1, 0)
                let name = (0..<length).map { UInt16(u16(e + $0 * 2)) }
                if rootStart < 0 { rootStart = u32(e + 0x74) } // first entry is the Root Entry
                guard name == target else { continue }
                let start = u32(e + 0x74), size = u32(e + 0x78)
                var fib: Int
                if size < cutoff { // small streams live in the mini stream, inside the root's sectors
                    let offset = start * miniSize, rootChain = chain(rootStart)
                    guard offset / sectorSize < rootChain.count else { return false }
                    fib = (rootChain[offset / sectorSize] + 1) * sectorSize + offset % sectorSize
                } else {
                    fib = (start + 1) * sectorSize
                }
                return u16(fib) == 0xA5EC && u16(fib + 0x0A) & 0x0100 != 0
            }
        }
        return false
    }

    /// LibreOffice macro that opens a protected document with the password from the environment and saves an
    /// unprotected copy in the same format. It runs inside LibreOffice (its Python can't be launched on its own).
    private static let decryptMacro = """
    import os, uno
    from com.sun.star.beans import PropertyValue
    def P(n, v):
        p = PropertyValue(); p.Name = n; p.Value = v; return p
    def main(*args):
        desk = XSCRIPTCONTEXT.getDesktop()
        try:
            d = desk.loadComponentFromURL(uno.systemPathToFileUrl(os.environ["QC_SRC"]), "_blank", 0,
                                          (P("Hidden", True), P("Password", os.environ["QC_PASSWORD"])))
            if d is not None:
                flt = [a.Value for a in d.getArgs() if a.Name == "FilterName"][0]
                d.storeToURL(uno.systemPathToFileUrl(os.environ["QC_DST"]), (P("FilterName", flt),))
                d.close(True)
        finally:
            desk.terminate()
    """

    /// Decrypts into the job's staging dir; the password only travels through the LibreOffice process environment.
    private static func decrypt(_ job: Staging, _ srcExt: String, password: String?) throws -> URL {
        guard let password, !password.isEmpty else { throw PasswordRequired(wrong: false) }
        guard officeAvailable else {
            throw ConversionError("This document is password-protected. Install LibreOffice to convert protected documents.")
        }
        let profileDir = job.dir.appendingPathComponent("decrypt-profile")
        let profile = profileDir.absoluteString
        try run(Formats.libreOffice, ["-env:UserInstallation=\(profile)", "--headless", "--terminate_after_init"], timeout: 120)
        let scripts = profileDir.appendingPathComponent("user/Scripts/python")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try decryptMacro.write(to: scripts.appendingPathComponent("qcdecrypt.py"), atomically: true, encoding: .utf8)

        let plain = job.dir.appendingPathComponent("src/plain.\(srcExt)")
        try run(Formats.libreOffice, ["-env:UserInstallation=\(profile)", "--headless",
                                      "vnd.sun.star.script:qcdecrypt.py$main?language=Python&location=user"],
                timeout: 300, environment: ["QC_SRC": job.input.path, "QC_DST": plain.path, "QC_PASSWORD": password])
        guard FileManager.default.fileExists(atPath: plain.path) else { throw PasswordRequired(wrong: true) }
        return plain
    }

    // MARK: - FFmpeg

    private static let audioTargets: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"]

    /// Codecs each container can hold as-is. nil means anything goes (MKV).
    private static let copyable: [String: (video: Set<String>?, audio: Set<String>?)] = [
        "mp4": (["h264", "hevc", "av1"], ["aac", "alac", "mp3", "ac3", "eac3"]),
        "mov": (["h264", "hevc", "prores"], ["aac", "alac", "mp3", "pcm_s16le", "pcm_s24le"]),
        "webm": (["vp8", "vp9", "av1"], ["opus", "vorbis"]),
        "mkv": (nil, nil),
        "m4a": ([], ["aac", "alac"]),
        "aac": ([], ["aac"]),
        "mp3": ([], ["mp3"]),
        "ogg": ([], ["opus", "vorbis", "flac"]),
        "opus": ([], ["opus"]),
    ]

    /// Stream policy, identical on the copy and re-encode paths:
    /// - video targets: every real video track (not cover art), every audio track, and subtitles when the
    ///   container accepts them (dropped otherwise);
    /// - audio targets: the first audio track, plus album art when both source and target are audio files that carry it.
    /// Attempts run in order: stream copy first (lossless), then re-encode; each with extras, then without.
    private static func ffmpeg(_ input: URL, _ out: URL, _ ext: String, _ kind: Kind, progress: ((Double) -> Void)?) throws {
        let (video, audio, duration) = probe(input)
        let rule = copyable[ext]
        var attempts: [[String]] = []

        if audioTargets.contains(ext) {
            let canCopy = audio.first.map { rule?.audio?.contains($0) == true } ?? false
            let art = kind == .audio && ["mp3", "m4a", "flac"].contains(ext)
                ? ["-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic"] : []
            for codec in canCopy ? [["-c:a", "copy"], audioCodec(ext)] : [audioCodec(ext)] {
                if !art.isEmpty { attempts.append(["-map", "0:a:0"] + art + codec) }
                attempts.append(["-map", "0:a:0"] + codec)
            }
        } else if ext == "gif" {
            attempts = [["-map", "0:V:0", "-vf", "fps=15,scale='min(960,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"]]
        } else {
            let maps = ["-map", "0:V", "-map", "0:a?"]
            let subs = ["-map", "0:s?", "-c:s", ext == "mkv" ? "copy" : ext == "webm" ? "webvtt" : "mov_text"]
            let faststart = ext == "mp4" || ext == "mov" ? ["-movflags", "+faststart"] : []
            let audioFits = rule?.audio.map { allowed in audio.allSatisfy(allowed.contains) } ?? true
            let audioArgs = audioFits ? ["-c:a", "copy"] : (ext == "webm" ? ["-c:a", "libopus", "-b:a", "192k"] : ["-c:a", "aac", "-b:a", "256k"])
            let videoFits = !video.isEmpty && (rule?.video.map { allowed in video.allSatisfy(allowed.contains) } ?? true)
            if videoFits {
                // hvc1 tag so QuickTime/Finder can play copied HEVC.
                let tag = (ext == "mp4" || ext == "mov") && video.contains("hevc") ? ["-tag:v", "hvc1"] : []
                let copy = maps + ["-c:v", "copy"] + tag + audioArgs + faststart
                attempts += [copy + subs, copy]
            }
            let encode = maps + videoCodec(ext) + audioArgs + faststart
            attempts += [encode + subs, encode]
        }

        // -progress writes key=value lines to stdout; out_time_us is the position written so far.
        let onLine: ((String) -> Void)? = progress.flatMap { report in
            duration.map { total in
                { line in
                    guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
                    report(min(1, max(0, us / 1_000_000 / total)))
                }
            }
        }
        var lastError: Error = ConversionError("No conversion route")
        for args in attempts {
            try? FileManager.default.removeItem(at: out)
            do {
                try run("ffmpeg", ["-hide_banner", "-nostdin", "-nostats", "-progress", "pipe:1", "-y", "-i", input.path]
                    + args + [out.path], onLine: onLine)
                return
            } catch let e as CancelledError {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func videoCodec(_ ext: String) -> [String] {
        // x264 4:2:0 rejects odd sizes (common in screen recordings); trim the stray pixel row/column.
        let even = ["-vf", "crop=trunc(iw/2)*2:trunc(ih/2)*2"]
        switch ext {
        // CRF 18 is visually lossless for x264; VP9 CRF 24 is comparable.
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "24", "-b:v", "0", "-row-mt", "1"]
        case "mkv": return even + ["-c:v", "libx264", "-crf", "18", "-preset", "slow"]
        default: return even + ["-c:v", "libx264", "-crf", "18", "-preset", "slow", "-pix_fmt", "yuv420p"]
        }
    }

    private static func audioCodec(_ ext: String) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "0"]
        case "m4a", "aac": return ["-c:a", "aac", "-b:a", "256k"]
        case "ogg", "opus": return ["-c:a", "libopus", "-b:a", "192k"]
        // 24-bit so hi-res sources aren't truncated to ffmpeg's 16-bit default.
        case "wav": return ["-c:a", "pcm_s24le"]
        case "aiff": return ["-c:a", "pcm_s24be"]
        default: return ["-c:a", "flac"]
        }
    }

    private struct Probe: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let disposition: [String: Int]?
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]?
        let format: Format?
    }

    /// One ffprobe call for codecs and duration. Cover art shows up as an attached-picture video stream,
    /// which is excluded from the video list.
    private static func probe(_ input: URL) -> (video: [String], audio: [String], duration: Double?) {
        let json = (try? run("ffprobe", ["-v", "error", "-of", "json", "-show_entries",
                                         "stream=codec_type,codec_name:stream_disposition=attached_pic:format=duration",
                                         input.path], timeout: 60)) ?? ""
        guard let p = try? JSONDecoder().decode(Probe.self, from: Data(json.utf8)) else { return ([], [], nil) }
        let streams = p.streams ?? []
        let video = streams.filter { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }.compactMap(\.codec_name)
        let audio = streams.filter { $0.codec_type == "audio" }.compactMap(\.codec_name)
        let duration = p.format?.duration.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        return (video, audio, duration)
    }

    private static func pageCount(_ pdf: URL) -> Int? {
        guard let info = try? run("pdfinfo", [pdf.path], timeout: 60) else { return nil }
        for line in info.split(separator: "\n") where line.hasPrefix("Pages:") {
            return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: - Staging and publishing

    private struct Staging {
        let dir: URL, input: URL, out: URL

        init(_ source: URL) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuickConvert-\(UUID().uuidString)")
            let src = dir.appendingPathComponent("src")
            out = dir.appendingPathComponent("out")
            for d in [dir, src, out] {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            // Input and outputs live in separate dirs so a same-format output can never write through the symlink.
            input = src.appendingPathComponent("in.\(source.pathExtension.lowercased())")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: source)
        }

        func outputs() -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
            return names.sorted().map { out.appendingPathComponent($0) }
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    /// Moves staged files next to `source` as "<base><variant><suffix>", trying variants "", " 2", " 3"…
    /// until every name in the group is free. Never overwrites; a partially placed group is rolled back.
    private static func publish(_ files: [(staged: URL, suffix: String)], for source: URL) throws -> [URL] {
        guard !files.isEmpty else { throw ConversionError("Produced no output") }
        for f in files {
            var st = stat()
            guard lstat(f.staged.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0 else {
                throw ConversionError("Produced no output")
            }
        }
        // Outputs get the source's read/write bits so a private file doesn't become a world-readable copy.
        var srcStat = stat()
        let mode = stat(source.path, &srcStat) == 0 ? srcStat.st_mode & 0o666 : 0o600
        for f in files { chmod(f.staged.path, mode) }

        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        for n in 1...1000 {
            let variant = n == 1 ? "" : " \(n)"
            var placed: [(staged: URL, dest: URL)] = []
            var collided = false
            do {
                for f in files {
                    let dest = dir.appendingPathComponent(base + variant + f.suffix)
                    guard try place(f.staged, at: dest, mode: mode) else { collided = true; break }
                    placed.append((f.staged, dest))
                }
            } catch {
                rollBack(placed)
                throw error
            }
            if !collided { return placed.map(\.dest) }
            rollBack(placed)
        }
        throw ConversionError("No free output name")
    }

    /// Returns false if `dest` already exists.
    private static func place(_ staged: URL, at dest: URL, mode: mode_t) throws -> Bool {
        if renamex_np(staged.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return true }
        var err = errno
        if err == EEXIST { return false }
        if err == EXDEV { // destination is on another volume
            if copyfile(staged.path, dest.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 {
                chmod(dest.path, mode)
                return true
            }
            err = errno
            if err == EEXIST { return false }
            unlink(dest.path)
        }
        throw ConversionError("Couldn't write \(dest.lastPathComponent): \(String(cString: strerror(err)))")
    }

    private static func rollBack(_ placed: [(staged: URL, dest: URL)]) {
        for p in placed {
            // Renamed files go back to staging; cross-volume copies still have their staged original.
            if FileManager.default.fileExists(atPath: p.staged.path) { unlink(p.dest.path) } else { rename(p.dest.path, p.staged.path) }
        }
    }

    // MARK: - Processes

    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: Process] = [:]
    private static var _generation = 0

    /// Bumped by cancelAll(); jobs started under an older generation report as cancelled.
    static var generation: Int { lock.withLock { _generation } }

    /// Removes work folders left by a previous run that was force-quit or crashed mid-job.
    /// Only safe before this run starts any job, so it's called once at launch.
    static func removeStaleStaging() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("QuickConvert-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// Engine errors mention the private staging paths (`…/QuickConvert-<uuid>/src/in.png`). Show the user's
    /// file name instead, and drop other staging paths, so messages are readable and don't expose temp folders.
    static func friendlyMessage(_ message: String, fileName: String) -> String {
        let staging = #"(?:/private)?/[^\s'"`]*?/QuickConvert-[0-9A-F-]{36}"#
        var out = message.replacingOccurrences(of: staging + #"/src/(?:in|plain)\.[A-Za-z0-9]+"#, with: fileName,
                                               options: .regularExpression)
        out = out.replacingOccurrences(of: staging + #"[^\s'"`]*"#, with: "(temporary file)", options: .regularExpression)
        return out
    }

    static func cancelAll() {
        let procs = lock.withLock { () -> [Process] in
            _generation += 1
            return Array(running.values)
        }
        procs.forEach { $0.terminate() }
    }

    private static func tool(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        // GUI apps don't inherit the shell PATH, so look in the usual places.
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs a tool and returns its stdout (first 1 MB). Keeps only the last 16 KB of stderr.
    /// `timeout` stops tools that should never take long; open-ended media jobs rely on Cancel All instead.
    @discardableResult
    private static func run(_ name: String, _ args: [String], timeout: TimeInterval? = nil,
                            environment: [String: String] = [:], onLine: ((String) -> Void)? = nil) throws -> String {
        guard let path = tool(name) else {
            let formula = ["magick": "imagemagick", "pdftoppm": "poppler", "pdfinfo": "poppler", "rsvg-convert": "librsvg", "ffprobe": "ffmpeg"][name]
            throw ConversionError(name.hasPrefix("/") ? "\(name) not found" : "\(name) not found (brew install \(formula ?? name))")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let startGeneration = generation
        let id = ObjectIdentifier(p)
        try lock.withLock {
            guard _generation == startGeneration else { throw CancelledError() }
            try p.run()
            running[id] = p
        }
        defer { _ = lock.withLock { running.removeValue(forKey: id) } }

        let expired = Flag()
        let deadline = timeout.map { seconds -> DispatchWorkItem in
            let item = DispatchWorkItem { expired.set(); p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }

        // Drain both pipes concurrently so neither can fill up and stall the tool.
        var stdout = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdout = drain(out.fileHandleForReading, limit: 1 << 20, keepTail: false, onLine: onLine)
            group.leave()
        }
        let stderr = drain(err.fileHandleForReading, limit: 16 << 10, keepTail: true)
        group.wait()
        p.waitUntilExit()
        deadline?.cancel()

        if generation != startGeneration { throw CancelledError() }
        if expired.isSet, let timeout {
            throw ConversionError("\((name as NSString).lastPathComponent) was stopped after \(Int(timeout / 60)) minutes without finishing")
        }
        guard p.terminationStatus == 0 else {
            // Homebrew's fontconfig warns on every LibreOffice/ImageMagick start; it's never the cause.
            let msg = String(decoding: stderr, as: UTF8.self)
                .split(separator: "\n").filter { !$0.hasPrefix("Fontconfig warning") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError("\((name as NSString).lastPathComponent) failed: \(msg.suffix(400))")
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private static func drain(_ handle: FileHandle, limit: Int, keepTail: Bool, onLine: ((String) -> Void)? = nil) -> Data {
        var buf = Data()
        var pending = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            if let onLine {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if keepTail {
                buf.append(chunk)
                if buf.count > limit { buf = Data(buf.suffix(limit)) }
            } else if buf.count < limit {
                buf.append(chunk.prefix(limit - buf.count))
            }
        }
        return buf
    }
}
