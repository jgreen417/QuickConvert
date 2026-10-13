// Test driver: qct <target> <file>... converts all files concurrently through Converter and prints
// "<name> -> OK <outputs>" or "<name> -> ERR <message>", plus the highest progress reported.
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let group = DispatchGroup()
let lock = NSLock()
for f in args.dropFirst() {
    group.enter()
    DispatchQueue.global().async {
        var maxProgress = -1.0
        let r: String
        do {
            let outs = try Converter.convert(URL(fileURLWithPath: f), to: args[0]) { p in lock.withLock { maxProgress = max(maxProgress, p) } }
            r = "OK " + outs.map(\.lastPathComponent).joined(separator: ", ")
        } catch {
            r = "ERR " + error.localizedDescription
        }
        lock.withLock {
            print("\((f as NSString).lastPathComponent) -> \(r)" + (maxProgress >= 0 ? " [progress \(Int(maxProgress * 100))%]" : ""))
        }
        group.leave()
    }
}
group.wait()
