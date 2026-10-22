import Cocoa

/// One app, two jobs. The role is chosen on first launch and can be changed later.
enum Role: String {
    case sender, receiver     // sender = main Mac (sends its desktop); receiver = the extra screen
    var title: String { self == .sender ? "Use another Mac as my display" : "Be the extra screen for another Mac" }
    var shortName: String { self == .sender ? "Main Mac" : "Extra screen" }
}

/// Sending needs ScreenCaptureKit audio/config APIs from macOS 13.
var senderSupported: Bool { if #available(macOS 13.0, *) { return true } else { return false } }
func osVersionString() -> String { let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") }

var currentRole: Role? { UserDefaults.standard.string(forKey: "role").flatMap(Role.init(rawValue:)) }

func hardwareModel() -> String {
    var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
    var m = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.model", &m, &size, nil, 0)
    return String(cString: m)
}

/// Laptops are usually the main Mac; desktops (iMac, Mac mini, Mac Studio) are usually the spare screen.
func suggestedRole() -> Role {
    if !senderSupported { return .receiver }
    let m = hardwareModel()
    if m.hasPrefix("MacBook") { return .sender }
    if m.hasPrefix("iMac") || m.hasPrefix("Macmini") || m.hasPrefix("MacPro") || m.hasPrefix("Mac1") { return .receiver }
    return .sender
}

func relaunchSelf() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
    try? p.run()
    NSApp.terminate(nil)
}

/// Ask, then switch role and restart the app. Pairings are kept separately for each role.
func switchRole(to r: Role) {
    if r == .sender && !senderSupported {
        let a = NSAlert(); a.messageText = "This Mac can only be the extra screen"
        a.informativeText = "Using this Mac as the main Mac needs macOS 13 or later (this Mac runs macOS \(osVersionString()))."
        NSApp.activate(ignoringOtherApps: true); a.runModal(); return
    }
    let a = NSAlert()
    a.messageText = r == .sender ? "Use this Mac as the main Mac?" : "Make this Mac the extra screen?"
    a.informativeText = r == .sender ? "This Mac will send its desktop to another Mac's screen. The app restarts."
                                     : "This Mac will show another Mac's desktop full-screen. The app restarts."
    a.addButton(withTitle: "Switch and Restart"); a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    if a.runModal() == .alertFirstButtonReturn {
        UserDefaults.standard.set(r.rawValue, forKey: "role")
        relaunchSelf()
    }
}

// MARK: first-run chooser
final class RoleCard: NSButton {
    var onPick: (() -> Void)?
    override func hitTest(_ p: NSPoint) -> NSView? { frame.contains(p) ? self : nil }
    override func mouseDown(with e: NSEvent) { layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor }
    override func mouseUp(with e: NSEvent) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onPick?() }
    }
}

final class RolePickerApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var win: NSWindow?
    var picked = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AirDisplay"; w.isReleasedWhenClosed = false; w.delegate = self

        let h1 = NSTextField(labelWithString: "What will this Mac do?"); h1.font = .systemFont(ofSize: 22, weight: .bold)
        let h2 = NSTextField(wrappingLabelWithString: "Install this same app on both Macs, then pick one role on each.")
        h2.font = .systemFont(ofSize: 13); h2.textColor = .secondaryLabelColor; h2.alignment = .center
        let rec = suggestedRole()
        let cards = NSStackView(views: [card(.sender, rec == .sender), card(.receiver, rec == .receiver)])
        if !senderSupported { cards.views.first?.alphaValue = 0.45 }
        cards.orientation = .horizontal; cards.spacing = 18
        let foot = NSTextField(labelWithString: "You can change this later in Settings."); foot.font = .systemFont(ofSize: 11); foot.textColor = .tertiaryLabelColor

        let s = NSStackView(views: [h1, h2, cards, foot]); s.orientation = .vertical; s.alignment = .centerX; s.spacing = 14
        s.setCustomSpacing(22, after: h2); s.setCustomSpacing(18, after: cards)
        s.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 22, right: 28)
        w.contentView = s
        w.setContentSize(s.fittingSize)
        w.center(); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        win = w
    }

    func card(_ r: Role, _ recommended: Bool) -> NSView {
        let b = RoleCard(frame: .zero)
        b.title = ""; b.isBordered = false; b.wantsLayer = true
        b.layer?.cornerRadius = 14; b.layer?.borderWidth = recommended ? 2 : 1
        b.layer?.borderColor = (recommended ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        b.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        b.onPick = { [weak self] in self?.pick(r) }

        let img = NSImageView()
        if #available(macOS 11.0, *) {
            img.image = NSImage(systemSymbolName: r == .sender ? "laptopcomputer" : "display", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 46, weight: .light))
            img.contentTintColor = .controlAccentColor
        }
        let t = NSTextField(wrappingLabelWithString: r.title); t.font = .systemFont(ofSize: 15, weight: .semibold); t.alignment = .center
        t.preferredMaxLayoutWidth = 210
        let d = NSTextField(wrappingLabelWithString: r == .sender ? "This Mac sends its desktop to a second screen. Pick this on your MacBook." : "This Mac shows the other Mac's desktop full-screen. Pick this on the Mac you want to use as a monitor.")
        d.font = .systemFont(ofSize: 12); d.textColor = .secondaryLabelColor; d.alignment = .center; d.preferredMaxLayoutWidth = 210
        let locked = r == .sender && !senderSupported
        let badge = NSTextField(labelWithString: locked ? "Needs macOS 13 or later" : (recommended ? "✓ Recommended for this Mac" : " "))
        badge.font = .systemFont(ofSize: 11, weight: .medium); badge.textColor = locked ? .systemOrange : (recommended ? .systemGreen : .clear)

        let v = NSStackView(views: [img, t, d, badge]); v.orientation = .vertical; v.alignment = .centerX; v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: b.topAnchor, constant: 22), v.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -18),
            v.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 16), v.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -16),
            b.widthAnchor.constraint(equalToConstant: 266),
        ])
        return b
    }

    func pick(_ r: Role) {
        if r == .sender && !senderSupported { switchRole(to: .sender); return }
        picked = true
        UserDefaults.standard.set(r.rawValue, forKey: "role")
        win?.close()
        relaunchSelf()
    }

    func windowWillClose(_ n: Notification) { if !picked { NSApp.terminate(nil) } }
}
