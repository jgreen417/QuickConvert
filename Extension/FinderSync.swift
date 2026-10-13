import Cocoa
import FinderSync

/// Runs sandboxed inside Finder. It only builds the menu and hands the job to the
/// unsandboxed host app through a URL, since the sandbox can't write next to the user's files.
@objc(FinderSync)
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty
        else { return nil }

        let office = FileManager.default.fileExists(atPath: Formats.libreOffice)
        let targets = Formats.commonTargets(for: items, office: office)
        guard !targets.isEmpty else { return nil }

        let submenu = NSMenu(title: "Convert to")
        for ext in targets {
            let item = NSMenuItem(title: Formats.label(ext), action: #selector(convert(_:)), keyEquivalent: "")
            item.tag = Formats.allTargets.firstIndex(of: ext)!
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        parent.submenu = submenu

        let menu = NSMenu(title: "")
        menu.addItem(parent)
        return menu
    }

    @objc func convert(_ sender: NSMenuItem) {
        guard Formats.allTargets.indices.contains(sender.tag),
              let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty
        else { return }

        let job = Formats.Job(to: Formats.allTargets[sender.tag], files: items.map(\.path))
        let id = UUID().uuidString
        // Inside the sandbox this resolves to the extension's container, which the host reads.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Jobs")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(job).write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            NSLog("QuickConvert: couldn't write job: \(error)")
            return
        }
        if let url = URL(string: "\(Formats.urlScheme)://job/\(id)") { NSWorkspace.shared.open(url) }
    }
}
