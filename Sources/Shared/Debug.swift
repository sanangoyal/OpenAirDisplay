import Foundation

/// Debug trace: only written when the file ~/.airdisplay-debug exists (touch it to enable).
func dlog(_ s: @autoclosure () -> String) {
    let home = NSHomeDirectory()
    guard FileManager.default.fileExists(atPath: home + "/.airdisplay-debug") else { return }
    let line = "\(Date().description.suffix(14)) \(s())\n"
    let path = home + "/airdisplay.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}
