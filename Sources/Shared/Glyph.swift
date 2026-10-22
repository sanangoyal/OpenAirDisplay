import Cocoa

/// Menu-bar glyph: two overlapping screens (template image, adapts to light/dark menu bar).
/// filled: front screen solid (streaming / active); otherwise outlines (idle).
func menuGlyph(filled: Bool, slashed: Bool = false, back: Bool = false) -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
        NSColor.black.setStroke(); NSColor.black.setFill()
        let backP = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 6.5, width: 10, height: 7.5), xRadius: 2, yRadius: 2)
        if back && filled { backP.fill() } else { backP.lineWidth = 1.4; backP.stroke() }
        let front = NSBezierPath(roundedRect: NSRect(x: 8, y: 1.5, width: 10.5, height: 8), xRadius: 2.2, yRadius: 2.2)
        // knock out the overlap so the front reads cleanly
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: 6.8, y: 0.3, width: 12.9, height: 10.4), xRadius: 3, yRadius: 3).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        if filled && !back { front.fill() } else { front.lineWidth = 1.4; front.stroke() }
        if slashed {
            let s = NSBezierPath(); s.move(to: NSPoint(x: 2, y: 14)); s.line(to: NSPoint(x: 18, y: 1.5)); s.lineWidth = 1.6; s.lineCapStyle = .round; s.stroke()
        }
        return true
    }
    img.isTemplate = true
    return img
}

