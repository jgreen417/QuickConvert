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
    private var failures: [String] = []
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
        alert.informativeText = "Results are saved next to the originals."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: targets.map(Formats.label))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        if runModal(alert) == .alertFirstButtonReturn {
            submit(files, to: targets[popup.indexOfSelectedItem])
        }
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
            var failure: String?
            var needsPassword: PasswordRequired?
            var wasCancelled = Converter.generation != generation
            if !wasCancelled {
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
                do { try Converter.convert(file, to: ext, password: password, progress: report) }
                catch is CancelledError { wasCancelled = true }
                catch let error as PasswordRequired { needsPassword = error }
                catch { failure = "\(name): \(error.localizedDescription)" }
            }
            DispatchQueue.main.async {
                let outcome = wasCancelled ? "cancelled" : needsPassword.map { $0.wrong ? "wrong password" : "needs password" } ?? (failure == nil ? "ok" : "failed")
                self.log("finished: \(name) \(outcome)")
                self.active.removeAll { $0.id == id }
                self.done += 1
                if let failure { self.failures.append(failure) }
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
            failures.append("\(name): Incorrect password")
            return
        }
        let alert = NSAlert()
        alert.messageText = wrong ? "Incorrect password for “\(name)”" : "“\(name)” is password-protected"
        alert.informativeText = "Enter its password to convert it. QuickConvert uses it only for this conversion and doesn't save it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Skip")
        alert.window.initialFirstResponder = field
        if runModal(alert) == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            enqueue(file, ext, password: field.stringValue, attempt: attempt + 1)
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
        let errors = failures, wasCancelled = cancelled
        total = 0; done = 0; failures = []; cancelled = false

        if !errors.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = errors.count == 1 ? "Conversion failed" : "\(errors.count) conversions failed"
            alert.informativeText = errors.prefix(10).joined(separator: "\n\n") + (errors.count > 10 ? "\n\n…and \(errors.count - 10) more" : "")
            runModal(alert)
        } else if !wasCancelled {
            NSSound(named: "Glass")?.play()
        }
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
