import Cocoa

// Renders "Light / Overlap" app icon (1024 px) to the path in argv[1].
let size = 1024
guard CommandLine.arguments.count > 1 else { print("usage: make-icon out.png"); exit(1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
func grad(_ a: UInt32, _ b: UInt32, alpha: CGFloat = 1) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: [col(a, alpha), col(b, alpha)] as CFArray, locations: [0, 1])!
}

// Tile (824 px, macOS icon grid) with soft shadow
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: col(0x000000, 0.28))
cg.addPath(tilePath); cg.setFillColor(col(0xF4F5F9)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(tilePath); cg.clip()
cg.drawLinearGradient(grad(0xFFFFFF, 0xE7E9F0), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
cg.restoreGState()

// Glyph in SVG coordinates (y down), mapped into the tile
let k: CGFloat = 824.0 / 976.0
cg.saveGState()
cg.translateBy(x: 100, y: 924); cg.scaleBy(x: k, y: -k); cg.translateBy(x: -24, y: -24)
func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, alpha: CGFloat) {
    let rect = CGRect(x: x, y: y, width: w, height: h)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 16 * k, color: col(0x000000, 0.25))
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)); cg.setFillColor(col(0x0A60FF, alpha)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)); cg.clip()
    cg.drawLinearGradient(grad(0x5AC8FA, 0x0A60FF, alpha: alpha), start: CGPoint(x: x, y: y), end: CGPoint(x: x + w, y: y + h), options: [])
    cg.restoreGState()
}
rrect(196, 300, 400, 300, 52, alpha: 0.45)
rrect(408, 400, 420, 320, 56, alpha: 1.0)
cg.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
