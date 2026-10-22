import Cocoa
import ApplicationServices

/// Replays keyboard / mouse events from the extra screen on this Mac. Needs Accessibility permission.
final class Injector {
    static let shared = Injector()
    private let src = CGEventSource(stateID: .hidSystemState)
    private var keys = Set<UInt16>()
    private var buttons = Set<Int>()
    private var asked = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: "acceptInput") as? Bool ?? true }
    static var trusted: Bool { AXIsProcessTrusted() }

    func handle(_ e: InputEvent, display: CGDirectDisplayID) {
        guard Injector.enabled else { return }
        guard AXIsProcessTrusted() else {
            if !asked { asked = true; _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            return
        }
        let b = CGDisplayBounds(display)
        let pos = CGPoint(x: b.minX + CGFloat(min(max(e.x, 0), 1)) * b.width, y: b.minY + CGFloat(min(max(e.y, 0), 1)) * b.height)
        let fl = CGEventFlags(rawValue: e.flags)
        switch e.kind {
        case .move:
            post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left), fl)
        case .down, .up, .drag:
            let btn = Int(e.code & 0xFF), clicks = Int64(e.code >> 8)
            let (t, mb): (CGEventType, CGMouseButton)
            switch (btn, e.kind) {
            case (0, .down): (t, mb) = (.leftMouseDown, .left)
            case (0, .up): (t, mb) = (.leftMouseUp, .left)
            case (0, _): (t, mb) = (.leftMouseDragged, .left)
            case (1, .down): (t, mb) = (.rightMouseDown, .right)
            case (1, .up): (t, mb) = (.rightMouseUp, .right)
            case (1, _): (t, mb) = (.rightMouseDragged, .right)
            case (_, .down): (t, mb) = (.otherMouseDown, .center)
            case (_, .up): (t, mb) = (.otherMouseUp, .center)
            default: (t, mb) = (.otherMouseDragged, .center)
            }
            if e.kind == .down { buttons.insert(btn) } else if e.kind == .up { buttons.remove(btn) }
            let ev = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: pos, mouseButton: mb)
            if e.kind != .drag { ev?.setIntegerValueField(.mouseEventClickState, value: max(clicks, 1)) }
            post(ev, fl)
        case .scroll:
            let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(e.y), wheel2: Int32(e.x), wheel3: 0)
            post(ev, fl)
        case .keyDown, .keyUp:
            let down = e.kind == .keyDown
            if down { keys.insert(e.code) } else { keys.remove(e.code) }
            post(CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(e.code), keyDown: down), fl)
        case .flags:
            let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(e.code), keyDown: true)
            ev?.type = .flagsChanged
            post(ev, fl)
        }
    }

    private func post(_ ev: CGEvent?, _ flags: CGEventFlags) {
        guard let ev = ev else { return }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }

    /// Called when the connection ends: never leave a key or button stuck down.
    func releaseAll() {
        guard AXIsProcessTrusted() else { keys.removeAll(); buttons.removeAll(); return }
        for k in keys { CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: false)?.post(tap: .cghidEventTap) }
        let p = CGEvent(source: nil)?.location ?? .zero
        for b in buttons {
            let t: CGEventType = b == 0 ? .leftMouseUp : (b == 1 ? .rightMouseUp : .otherMouseUp)
            CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b == 0 ? .left : (b == 1 ? .right : .center))?.post(tap: .cghidEventTap)
        }
        keys.removeAll(); buttons.removeAll()
        CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false).map { ev in ev.type = .flagsChanged; ev.flags = []; ev.post(tap: .cghidEventTap) }
    }
}
