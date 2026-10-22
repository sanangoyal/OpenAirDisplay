import Foundation

private let ringLock = NSLock()
private var ring: [String] = []

/// Last events (kept in memory always, so a diagnose report has context without any flag).
func recentLog(_ n: Int = 60) -> [String] { ringLock.lock(); defer { ringLock.unlock() }; return Array(ring.suffix(n)) }

/// Debug trace: always kept in a small in-memory ring; also written to ~/openairdisplay.log when ~/.openairdisplay-debug exists (touch it to enable).
func dlog(_ s: @autoclosure () -> String) {
    let line = "\(Date().description.suffix(14)) \(s())\n"
    ringLock.lock(); ring.append(String(line.dropLast())); if ring.count > 300 { ring.removeFirst(ring.count - 300) }; ringLock.unlock()
    let home = NSHomeDirectory()
    guard FileManager.default.fileExists(atPath: home + "/.openairdisplay-debug") else { return }
    let path = home + "/openairdisplay.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}
