import Cocoa

/// Background agent (no Dock icon). Entry points:
/// - Finder Sync menu: quickconvert://job/<uuid>, job details read from the extension's container;
/// - Services / Quick Actions "Convert with QuickConvert…", which works where Finder Sync doesn't (e.g. iCloud Drive);
/// - files dropped on the app, or picked from its welcome window.
/// Shows progress in the menu bar while working and quits once idle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        return q
    }()
    private var total = 0
    private var done = 0

    /// What happened to each file in the current batch; the end-of-batch summary is built from these.
    private enum Outcome {
        case converted([URL])
        case failed(String, retryable: Bool)
        case cancelled
        case skipped // password prompt dismissed with Skip
    }
    private struct JobResult {
        let file: URL
        let ext: String
        let outcome: Outcome
    }
    private var results: [JobResult] = []
    private struct Running {
        let id: UUID
        let name: String
        var progress: Double?
    }
    private var active: [Running] = []
    private var cancelled = false
    private var statusItem: NSStatusItem?
    private var sawRequest = false
    private var modalDepth = 0
    private var quitTimer: Timer?

    private var busy: Bool { done < total }

    // Test mode for Tests/lifecycle.sh. Only `open --env` can set these, so links and websites can't.
    // Every dialog is logged and answered automatically after QC_TEST_DWELL seconds, while still running
    // as a real modal session, so jobs can arrive mid-dialog exactly as they would for a person.
    private let testDwell = ProcessInfo.processInfo.environment["QC_TEST_DWELL"].flatMap(Double.init)
    private let testLog = ProcessInfo.processInfo.environment["QC_TEST_LOG"]
    private var testPasswords = ProcessInfo.processInfo.environment["QC_TEST_PASSWORDS"]?
        .split(separator: ",").map(String.init) ?? []

    private func log(_ event: String) {
        guard let testLog, let data = "\(event)\n".data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: testLog) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            FileManager.default.createFile(atPath: testLog, contents: data)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { log("quit") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if arch(x86_64)
        log("launch x86_64")
        #else
        log("launch arm64")
        #endif
        NSApp.servicesProvider = self
        // Test mode: press Cancel All after N seconds, the same action as the menu-bar item.
        if testDwell != nil, let after = ProcessInfo.processInfo.environment["QC_TEST_CANCEL_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { self.log("cancel all"); self.cancelAll() }
        }
        // Requests arrive right after launch; a plain launch means the user opened the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !self.sawRequest { self.showWelcome() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        sawRequest = true
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { pickFormat(for: files) }
        for url in urls where !url.isFileURL { handleJob(url) }
        scheduleQuitIfIdle()
    }

    /// NSServices entry (NSMessage "convertFiles").
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        sawRequest = true
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { pickFormat(for: urls) }
        scheduleQuitIfIdle()
    }

    // MARK: - Requests

    private func handleJob(_ url: URL) {
        guard url.scheme == Formats.urlScheme, url.host == "job",
              let id = UUID(uuidString: url.lastPathComponent) else { return }
        let file = Formats.jobsDirectory.appendingPathComponent("\(id.uuidString).json")
        // Only a regular file you own, written in the last two minutes, and only once.
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let data = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        guard let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 120,
              let job = try? JSONDecoder().decode(Formats.Job.self, from: data) else { return }
        submit(job.files.map { URL(fileURLWithPath: $0) }, to: job.to)
    }

    private func pickFormat(for files: [URL]) {
        let targets = Formats.commonTargets(for: files, office: Converter.officeAvailable)
        let alert = NSAlert()
        guard !targets.isEmpty else {
            alert.messageText = "Nothing to convert"
            alert.informativeText = "QuickConvert has no format that all of these files can be converted to."
            runModal(alert)
            return
        }
        alert.messageText = files.count == 1 ? "Convert \(files[0].lastPathComponent)" : "Convert \(files.count) files"
        alert.informativeText = files.count == 1
            ? "The result is saved next to the original."
            : "\(describe(files)). Results are saved next to the originals."
        // Labeled format control (also named for VoiceOver).
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 0, y: 4, width: 58, height: 18)
        let popup = NSPopUpButton(frame: NSRect(x: 62, y: 0, width: 190, height: 26), pullsDown: false)
        popup.addItems(withTitles: targets.map(Formats.label))
        popup.setAccessibilityLabel("Output format")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 26))
        accessory.addSubview(label)
        accessory.addSubview(popup)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        if runModal(alert) == .alertFirstButtonReturn {
            submit(files, to: targets[popup.indexOfSelectedItem])
        }
    }

    /// "2 images and 1 video" for the picker.
    private func describe(_ files: [URL]) -> String {
        let names: [(Kind, String, String)] = [
            (.image, "image", "images"), (.svg, "SVG", "SVGs"), (.pdf, "PDF", "PDFs"), (.video, "video", "videos"),
            (.audio, "audio file", "audio files"), (.text, "document", "documents"),
            (.slides, "presentation", "presentations"), (.sheet, "spreadsheet", "spreadsheets"),
        ]
        let parts = names.compactMap { kind, one, many -> String? in
            let n = files.filter { Formats.kind(of: $0) == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? "\(files.count) files"
    }

    private func submit(_ files: [URL], to ext: String) {
        guard Formats.allTargets.contains(ext), !files.isEmpty else { return }
        guard files.count <= Formats.maxFiles else {
            let alert = NSAlert()
            alert.messageText = "Too many files"
            alert.informativeText = "QuickConvert converts up to \(Formats.maxFiles) files at a time."
            runModal(alert)
            return
        }
        quitTimer?.invalidate()
        for f in files { enqueue(f, ext) }
    }

    // MARK: - Work

    private func enqueue(_ file: URL, _ ext: String, password: String? = nil, attempt: Int = 0) {
        total += 1
        updateStatus()
        let generation = Converter.generation
        let name = file.lastPathComponent
        let id = UUID()
        queue.addOperation {
            var outcome: Outcome?
            var needsPassword: PasswordRequired?
            if Converter.generation != generation {
                outcome = .cancelled
            } else {
                DispatchQueue.main.async { self.active.append(Running(id: id, name: name)); self.updateStatus() }
                var lastShown = -1
                let report = { (fraction: Double) in
                    let percent = Int(fraction * 100)
                    guard percent != lastShown else { return } // ffmpeg reports twice a second; only redraw on change
                    lastShown = percent
                    DispatchQueue.main.async {
                        if let i = self.active.firstIndex(where: { $0.id == id }) { self.active[i].progress = fraction }
                        self.updateStatus()
                    }
                }
                do {
                    // Input problems (missing file, unsupported pair) won't fix themselves, so they aren't offered for retry.
                    do { try Converter.validate(file, to: ext) } catch {
                        throw ConversionError("\(error.localizedDescription)", retryable: false)
                    }
                    outcome = .converted(try Converter.convert(file, to: ext, password: password, progress: report))
                }
                catch is CancelledError { outcome = .cancelled }
                catch let error as PasswordRequired { needsPassword = error }
                catch let error as ConversionError {
                    outcome = .failed("\(name): \(Converter.friendlyMessage(error.message, fileName: name))", retryable: error.retryable)
                }
                catch { outcome = .failed("\(name): \(Converter.friendlyMessage(error.localizedDescription, fileName: name))", retryable: true) }
            }
            DispatchQueue.main.async {
                let label: String
                switch outcome {
                case .converted: label = "ok"
                case .failed: label = "failed"
                case .cancelled: label = "cancelled"
                case .skipped: label = "skipped"
                case nil: label = needsPassword?.wrong == true ? "wrong password" : "needs password"
                }
                self.log("finished: \(name) \(label)")
                self.active.removeAll { $0.id == id }
                self.done += 1
                if let outcome { self.results.append(JobResult(file: file, ext: ext, outcome: outcome)) }
                // Ask before the idle check below, so a retry is queued before the app could decide it's done.
                if let needsPassword { self.askPassword(for: file, to: ext, wrong: needsPassword.wrong, attempt: attempt) }
                self.updateStatus()
                if !self.busy { self.finish() }
            }
        }
    }

    private func askPassword(for file: URL, to ext: String, wrong: Bool, attempt: Int) {
        let name = file.lastPathComponent
        guard attempt < 3 else {
            results.append(JobResult(file: file, ext: ext, outcome: .failed("\(name): Incorrect password", retryable: true)))
            return
        }
        let alert = NSAlert()
        alert.messageText = wrong ? "Incorrect password for “\(name)”" : "“\(name)” is password-protected"
        alert.informativeText = "Enter its password to convert it. QuickConvert uses it only for this conversion and doesn't save it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.setAccessibilityLabel("Password for \(name)")
        alert.accessoryView = field
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Skip")
        alert.window.initialFirstResponder = field
        if runModal(alert) == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            enqueue(file, ext, password: field.stringValue, attempt: attempt + 1)
        } else {
            results.append(JobResult(file: file, ext: ext, outcome: .skipped))
        }
    }

    @objc private func cancelAll() {
        cancelled = true
        Converter.cancelAll()
    }

    private func updateStatus() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Converting")
            statusItem?.button?.imagePosition = .imageLeading
        }
        let percent = { (r: Running) in r.progress.map { " — \(Int($0 * 100))%" } ?? "" }
        if total > 1 {
            statusItem?.button?.title = " \(done)/\(total)"
        } else {
            statusItem?.button?.title = active.first.map { r in r.progress.map { " \(Int($0 * 100))%" } ?? "" } ?? ""
        }
        statusItem?.button?.setAccessibilityLabel("QuickConvert: \(done) of \(total) conversions done")
        let menu = NSMenu()
        menu.addItem(withTitle: "\(done) of \(total) done", action: nil, keyEquivalent: "")
        for r in active.prefix(5) { menu.addItem(withTitle: "Converting \(r.name)\(percent(r))", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "Cancel All", action: #selector(cancelAll), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        statusItem?.menu = menu
        // Test mode: where the menu-bar item is (top-left origin, points), for README screenshots.
        if testLog != nil, let window = statusItem?.button?.window, let screen = window.screen {
            let f = window.frame
            log("status: \(Int(f.minX)) \(Int(screen.frame.maxY - f.maxY)) \(Int(f.width)) \(Int(f.height)) \(statusItem?.button?.title ?? "")")
        }
    }

    private func finish() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        let batch = results
        results = []; total = 0; done = 0; cancelled = false

        var outputs: [URL] = [], errors: [String] = [], again: [JobResult] = []
        var converted = 0, failed = 0, stopped = 0, skipped = 0
        for r in batch {
            switch r.outcome {
            case .converted(let urls): converted += 1; outputs += urls
            case .failed(let message, let retryable): failed += 1; errors.append(message); if retryable { again.append(r) }
            case .cancelled: stopped += 1; again.append(r)
            case .skipped: skipped += 1
            }
        }
        log("summary: converted=\(converted) failed=\(failed) cancelled=\(stopped) skipped=\(skipped)")

        guard failed + stopped > 0 else {
            if converted > 0 { NSSound(named: "Glass")?.play() }
            scheduleQuitIfIdle()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = failed > 0 ? .warning : .informational
        let n = batch.count
        if failed > 0 {
            alert.messageText = failed == n ? (n == 1 ? "Conversion failed" : "\(n) conversions failed") : "\(failed) of \(n) conversions failed"
        } else {
            alert.messageText = stopped == n ? (n == 1 ? "Conversion cancelled" : "\(n) conversions cancelled") : "\(stopped) of \(n) conversions cancelled"
        }
        alert.informativeText = [(converted, "converted"), (failed, "failed"), (stopped, "cancelled"), (skipped, "skipped")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        if !errors.isEmpty {
            // Every error, selectable for copying, instead of a truncated list.
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 10))
            text.string = errors.joined(separator: "\n\n")
            text.isEditable = false
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textContainerInset = NSSize(width: 4, height: 4)
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(160, CGFloat(40 + errors.count * 34))))
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.setAccessibilityLabel("Errors")
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "OK")
        var actions: [() -> Void] = [{}]
        if !outputs.isEmpty {
            alert.addButton(withTitle: outputs.count == 1 ? "Show Converted File" : "Show Converted Files")
            actions.append { [self] in
                log("reveal: \(outputs.map(\.lastPathComponent).joined(separator: ", "))")
                if testDwell == nil { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            }
        }
        if !again.isEmpty {
            alert.addButton(withTitle: again.count == 1 ? "Try Again" : "Try \(again.count) Again")
            actions.append { [self] in
                log("retry: \(again.map(\.file.lastPathComponent).joined(separator: ", "))")
                quitTimer?.invalidate()
                for r in again { enqueue(r.file, r.ext) }
            }
        }
        // Test mode: QC_TEST_SUMMARY_ANSWER=show|retry picks that button instead of OK.
        let wanted = ProcessInfo.processInfo.environment["QC_TEST_SUMMARY_ANSWER"]
        let titles = alert.buttons.map(\.title)
        let index = titles.firstIndex { t in (wanted == "show" && t.hasPrefix("Show")) || (wanted == "retry" && t.hasPrefix("Try")) } ?? 0
        let response = runModal(alert, testAnswer: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        let chosen = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(chosen) { actions[chosen]() }
        scheduleQuitIfIdle()
    }

    // MARK: - Lifecycle

    @discardableResult
    private func runModal(_ alert: NSAlert, testAnswer: NSApplication.ModalResponse = .alertFirstButtonReturn) -> NSApplication.ModalResponse {
        modalDepth += 1
        defer { modalDepth -= 1 }
        log("dialog: \(alert.messageText)")
        if let testDwell {
            // Answer only once this dialog is the frontmost modal, so a nested dialog's timer never closes an outer one.
            var waited = 0.0
            let timer = Timer(timeInterval: 0.1, repeats: true) { t in
                waited += 0.1
                guard waited >= testDwell, NSApp.modalWindow === alert.window else { return }
                t.invalidate()
                if let field = alert.accessoryView as? NSSecureTextField, !self.testPasswords.isEmpty {
                    field.stringValue = self.testPasswords.removeFirst()
                }
                NSApp.stopModal(withCode: testAnswer)
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        log("closed: \(alert.messageText)")
        return response
    }

    /// Quits a few seconds after the last work or dialog, re-checking at fire time in case a job arrived.
    private func scheduleQuitIfIdle() {
        quitTimer?.invalidate()
        guard !busy, modalDepth == 0 else { return }
        quitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, !self.busy, self.modalDepth == 0 else { return }
            NSApp.terminate(nil)
        }
    }

    private func showWelcome() {
        let enabled = extensionEnabled()
        let alert = NSAlert()
        alert.messageText = "QuickConvert"
        alert.informativeText = (enabled
            ? "Right-click files in Finder and choose Convert to."
            : "The Finder extension is off, so Convert to won't appear in Finder's right-click menu.")
            + "\n\nWhere that menu isn't available (like iCloud Drive), right-click › Services › Convert with QuickConvert…, drop files on this app, or choose them here."
        alert.addButton(withTitle: "Choose Files…")
        alert.addButton(withTitle: enabled ? "Done" : "Enable Finder Extension")
        let response = runModal(alert, testAnswer: .alertSecondButtonReturn)
        if response == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            modalDepth += 1
            let ok = panel.runModal() == .OK
            modalDepth -= 1
            if ok { pickFormat(for: panel.urls) }
        } else if response == .alertSecondButtonReturn && !enabled {
            pluginkit(["-e", "use", "-i", Formats.extensionID])
        }
        scheduleQuitIfIdle()
    }

    private func extensionEnabled() -> Bool {
        // pluginkit prints "+    <id>" for enabled extensions.
        pluginkit(["-m", "-i", Formats.extensionID]).trimmingCharacters(in: .whitespaces).hasPrefix("+")
    }

    @discardableResult
    private func pluginkit(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// Before the run loop starts: a file-open launch delivers its job before applicationDidFinishLaunching.
Converter.removeStaleStaging()
try? FileManager.default.createDirectory(at: Formats.jobsDirectory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
