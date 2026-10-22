import Foundation

/// Keyboard / mouse event sent from the extra screen (receiver) to the main Mac (sender).
/// Positions are normalized 0...1 across the picture, origin top-left. 19 bytes on the wire.
struct InputEvent {
    enum Kind: UInt8 { case move = 1, down, up, drag, scroll, keyDown, keyUp, flags }
    var kind: Kind
    var code: UInt16 = 0      // key code; for mouse buttons: button | clickCount << 8
    var flags: UInt64 = 0     // modifier flags (CGEventFlags raw value)
    var x: Float = 0, y: Float = 0   // position, or scroll delta in pixels

    func encode() -> Data {
        var d = Data(); d.append(kind.rawValue)
        d.append(UInt8(code >> 8)); d.append(UInt8(code & 0xFF))
        for i in (0..<8).reversed() { d.append(UInt8((flags >> UInt64(i * 8)) & 0xFF)) }
        for v in [x.bitPattern, y.bitPattern] { for i in (0..<4).reversed() { d.append(UInt8((v >> UInt32(i * 8)) & 0xFF)) } }
        return d
    }

    init(kind: Kind, code: UInt16 = 0, flags: UInt64 = 0, x: Float = 0, y: Float = 0) {
        self.kind = kind; self.code = code; self.flags = flags; self.x = x; self.y = y
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 19, let k = Kind(rawValue: b[0]) else { return nil }
        kind = k
        code = UInt16(b[1]) << 8 | UInt16(b[2])
        flags = b[3..<11].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        x = Float(bitPattern: b[11..<15].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        y = Float(bitPattern: b[15..<19].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
}
