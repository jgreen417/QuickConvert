import Foundation

/// Format catalog shared by the Finder extension (to build the menu) and the app (to route jobs).
enum Kind {
    case image, svg, pdf, video, audio, text, slides, sheet
}

enum Formats {
    static let libreOffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    static let urlScheme = "quickconvert"
    static let extensionID = "com.joshgreen.quickconvert.findersync"
    static let maxFiles = 500

    /// A Finder menu request. The extension writes it into its own sandbox container and sends only the
    /// job's UUID in a quickconvert://job/<uuid> URL, so a link from a website or another app can't name files.
    struct Job: Codable {
        let to: String
        let files: [String]
    }

    /// The extension's sandboxed Caches/Jobs, as seen from the unsandboxed host.
    static var hostJobsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/\(extensionID)/Data/Library/Caches/Jobs")
    }

    static let kinds: [String: Kind] = {
        var m: [String: Kind] = [:]
        for e in ["jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "gif", "tiff", "tif", "bmp", "ico", "tga", "psd", "qoi", "exr", "ppm"] { m[e] = .image }
        m["svg"] = .svg
        m["pdf"] = .pdf
        for e in ["mp4", "mov", "m4v", "webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "3gp"] { m[e] = .video }
        for e in ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "aif", "wma", "caf"] { m[e] = .audio }
        for e in ["txt", "rtf", "doc", "docx", "odt", "html", "htm"] { m[e] = .text }
        for e in ["pptx", "ppt", "odp", "key"] { m[e] = .slides }
        for e in ["xlsx", "xls", "ods", "csv", "numbers"] { m[e] = .sheet }
        return m
    }()

    /// Every target in menu order. Menu item tags index into this list.
    static let allTargets = [
        "jpg", "png", "webp", "heic", "avif", "gif", "tiff", "bmp", "ico", "pdf",
        "mp4", "mov", "webm", "mkv",
        "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff",
        "docx", "doc", "odt", "rtf", "txt", "html",
        "pptx", "odp", "xlsx", "ods", "csv",
    ]

    static func kind(of url: URL) -> Kind? { kinds[url.pathExtension.lowercased()] }

    static func targets(for kind: Kind, office: Bool) -> [String] {
        switch kind {
        case .image: return ["jpg", "png", "webp", "heic", "avif", "gif", "tiff", "bmp", "ico", "pdf"]
        case .svg: return ["png", "jpg", "webp", "pdf"]
        case .pdf: return ["png", "jpg"]
        case .video: return ["mp4", "mov", "webm", "mkv", "gif", "mp3", "m4a", "wav"]
        case .audio: return ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"]
        case .text: return ["docx", "doc", "odt", "rtf", "txt", "html"] + (office ? ["pdf"] : [])
        case .slides: return office ? ["pdf", "pptx", "odp"] : []
        case .sheet: return office ? ["pdf", "xlsx", "ods", "csv"] : []
        }
    }

    /// Targets valid for every selected file, minus formats they already are.
    static func commonTargets(for urls: [URL], office: Bool) -> [String] {
        var common: Set<String>?
        var sources = Set<String>()
        for url in urls {
            guard let k = kind(of: url) else { return [] }
            let t = Set(targets(for: k, office: office))
            common = common.map { $0.intersection(t) } ?? t
            sources.insert(normalize(url.pathExtension))
        }
        // Converting a.png + b.jpg to png is still useful for b; only hide a target when every file already has it.
        let hide = sources.count == 1 ? sources : []
        return allTargets.filter { common?.contains($0) == true && !hide.contains($0) }
    }

    static func normalize(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "htm": return "html"
        case "aif": return "aiff"
        case "heif": return "heic"
        default: return ext.lowercased()
        }
    }

    static func label(_ ext: String) -> String {
        ext == "jpg" ? "JPEG" : ext.uppercased()
    }
}
