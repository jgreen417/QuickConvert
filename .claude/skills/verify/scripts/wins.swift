// wins [owner...]: one line per on-screen window: id owner layer width height
// (owner names with spaces are joined with "_"). Used to capture one app's window and nothing else.
import CoreGraphics
import Foundation
let owners = Set(CommandLine.arguments.dropFirst())
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []) {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owners.isEmpty || owners.contains(owner) else { continue }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print(w[kCGWindowNumber as String] as? Int ?? 0, owner.replacingOccurrences(of: " ", with: "_"),
          w[kCGWindowLayer as String] as? Int ?? 0, Int(b["Width"] ?? 0), Int(b["Height"] ?? 0))
}
