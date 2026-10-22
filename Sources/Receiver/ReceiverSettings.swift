import Cocoa
import AVFoundation

/// Settings window for the "extra screen" role. Plain AppKit so it works on macOS 12.
final class ReceiverSettings: NSObject, NSWindowDelegate {
    unowned let app: ReceiverApp
    var win: NSWindow?
    var tabs: NSTabView?
    var timer: Timer?
    var stat: [String: NSTextField] = [:]
    var peersBox = NSStackView()
    var lastDecoded: UInt32 = 0, lastBytes = 0, lastT = Date()
    var fps = 0.0, mbps = 0.0

    init(_ a: ReceiverApp) { app = a }

    // MARK: helpers
    func text(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s); t.font = .systemFont(ofSize: size, weight: weight); t.textColor = color; return t
    }
    func hint(_ s: String) -> NSTextField {
        let t = text(s, size: 11, color: .secondaryLabelColor); t.preferredMaxLayoutWidth = 340; return t
    }
    func check(_ title: String, _ on: Bool, _ sel: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: sel); b.state = on ? .on : .off; return b
    }
    func row(_ title: String, _ v: NSView) -> NSView {
        let l = text(title); l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false; l.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let s = NSStackView(views: [l, v]); s.orientation = .horizontal; s.alignment = .firstBaseline; s.spacing = 12; return s
    }
    func page(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = 12
        s.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let c = NSView(); s.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(s)
        NSLayoutConstraint.activate([s.topAnchor.constraint(equalTo: c.topAnchor), s.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                                     s.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor)])
        return c
    }
    func tab(_ name: String, _ v: NSView) -> NSTabViewItem { let t = NSTabViewItem(identifier: name); t.label = name; t.view = v; return t }
    func valueLabel(_ key: String) -> NSTextField {
        let t = text("–", color: .secondaryLabelColor); t.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); stat[key] = t; return t
    }

    // MARK: show
    func show() {
        if let w = win { reload(); center(w); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); startTimer(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "OpenAirDisplay Settings"; w.isReleasedWhenClosed = false; w.delegate = self
        let t = NSTabView(frame: w.contentView!.bounds); t.autoresizingMask = [.width, .height]
        tabs = t; w.contentView!.addSubview(t); win = w
        build(); center(w)
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); startTimer()
    }
    func center(_ w: NSWindow) {
        let s = (NSScreen.screens.first ?? NSScreen.main)!.frame
        w.setFrameOrigin(NSPoint(x: s.midX - w.frame.width / 2, y: s.midY - w.frame.height / 2 + 40))
    }
    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func windowWillClose(_ n: Notification) { timer?.invalidate(); timer = nil }

    func reload() { guard let t = tabs else { return }; for i in t.tabViewItems { t.removeTabViewItem(i) }; stat = [:]; build() }

    func build() {
        guard let t = tabs else { return }
        // General
        let roleBtn = NSButton(title: "Use this Mac as the main Mac…", target: self, action: #selector(toSender))
        var gen: [NSView] = [row("This Mac is", text("The extra screen")), row("", roleBtn)]
        if !senderSupported { gen.append(row("", hint("Sending needs macOS 13 or later. This Mac runs macOS \(osVersionString()), so it can only be the extra screen."))); roleBtn.isEnabled = false }
        gen += [row("Launch at login", check("Start automatically", FileManager.default.fileExists(atPath: agentPath), #selector(toggleLogin))),
                row("Receiving", check("Pause (use this Mac normally)", app.paused, #selector(togglePause))),
                row("Sound", check("Play sound from the other Mac", app.soundOn, #selector(toggleSound)))]
        t.addTabViewItem(tab("General", page(gen)))

        // Display
        let fit = NSPopUpButton(frame: .zero, pullsDown: false); fit.addItems(withTitles: ["Fit (keep proportions)", "Fill (crop edges)"])
        fit.selectItem(at: app.fillMode ? 1 : 0); fit.target = self; fit.action = #selector(fitChanged)
        let dis: [NSView] = [row("Scaling", fit),
            row("", hint("Fit shows the whole picture. Fill zooms to remove black bars if the other Mac's shape differs.")),
            row("Mouse pointer", check("Hide pointer on the extra screen", app.hidePointer, #selector(togglePointer))),
            row("Input", check("Send this Mac's keyboard & mouse to the main Mac", app.forwardInput, #selector(toggleForward))),
            row("", hint("Tap Esc is sent on. Hold Esc for 1.5 s to leave the extra screen. The main Mac must allow it (Settings › General › Accept keyboard & mouse) and grant Accessibility.")),
            row("Power", check("Keep this Mac awake while showing", app.keepAwake, #selector(toggleAwake))),
            row("", hint("Without input forwarding, press Esc to pause and use this Mac normally.")),
            row("Resolution", valueLabel("res"))]
        t.addTabViewItem(tab("Display", page(dis)))

        // Connection
        peersBox = NSStackView(); peersBox.orientation = .vertical; peersBox.alignment = .leading; peersBox.spacing = 6
        let pairBtn = NSButton(title: "Pair new Mac…", target: self, action: #selector(pair))
        let con: [NSView] = [row("Status", valueLabel("status")), row("Paired Macs", peersBox), row("", pairBtn),
            row("This Mac's ID", text(app.keys.myID, color: .secondaryLabelColor)), row("Port", text("7777 (TCP)", color: .secondaryLabelColor))]
        t.addTabViewItem(tab("Connection", page(con)))
        fillPeers()

        // Statistics
        let st: [NSView] = [row("Receiving from", valueLabel("from")), row("Frame rate", valueLabel("fps")), row("Bit rate", valueLabel("mbps")),
            row("Frame size", valueLabel("size")), row("Frames shown", valueLabel("total")), row("Decoder", valueLabel("dec"))]
        t.addTabViewItem(tab("Statistics", page(st)))

        // About
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let copy = NSButton(title: "Copy diagnostics", target: self, action: #selector(copyDiag))
        let reset = NSButton(title: "Show role chooser at next launch…", target: self, action: #selector(resetRole))
        let ab: [NSView] = [text("OpenAirDisplay", size: 20, weight: .bold), row("Version", text("\(v) (\(b))")), row("Role", text("Extra screen")),
            row("Mac", text(hardwareModel(), color: .secondaryLabelColor)), row("macOS", text(osVersionString(), color: .secondaryLabelColor)),
            row("", copy), row("", reset),
            row("Made by", text("Sanan Goyal · sanangoyal.com", color: .secondaryLabelColor)),
            row("", hint("No accounts, no analytics, no servers: everything goes directly between your Macs, encrypted, and only to Macs you paired. Free software under the MIT License, provided “as is” without warranty. Use at your own risk. Not affiliated with or endorsed by Apple. Mac, macOS and iMac are trademarks of Apple Inc."))]
        t.addTabViewItem(tab("About", page(ab)))
        tick()
    }

    func fillPeers() {
        for v in peersBox.arrangedSubviews { peersBox.removeArrangedSubview(v); v.removeFromSuperview() }
        if app.keys.peers.isEmpty { peersBox.addArrangedSubview(text("None yet", color: .secondaryLabelColor)); return }
        for p in app.keys.peers {
            let n = text(p.name); let b = NSButton(title: "Forget", target: self, action: #selector(forget(_:))); b.identifier = NSUserInterfaceItemIdentifier(p.id)
            b.controlSize = .small; b.bezelStyle = .rounded
            let s = NSStackView(views: [n, b]); s.spacing = 10; peersBox.addArrangedSubview(s)
        }
    }

    // MARK: live stats
    func tick() {
        let now = Date(), dt = max(now.timeIntervalSince(lastT), 0.2)
        let d = app.decoded, by = app.rxBytes
        if app.streaming { fps = Double(d &- lastDecoded) / dt; mbps = Double(by - lastBytes) * 8 / dt / 1e6 } else { fps = 0; mbps = 0 }
        lastDecoded = d; lastBytes = by; lastT = now
        func set(_ k: String, _ s: String) { stat[k]?.stringValue = s }
        set("status", app.paused ? "Paused" : (app.streaming ? "Showing \(app.peerName)" : "Ready · waiting for a Mac"))
        set("from", app.streaming ? app.peerName : "–")
        set("fps", app.streaming ? String(format: "%.0f fps", fps) : "–")
        set("mbps", app.streaming ? String(format: "%.1f Mbps", mbps) : "–")
        if let fd = app.fd { let dm = CMVideoFormatDescriptionGetDimensions(fd); set("size", "\(dm.width)×\(dm.height)") } else { set("size", "–") }
        set("total", "\(d)")
        set("dec", "Hardware H.264")
        let s = NSScreen.screens.first; let sc = s?.backingScaleFactor ?? 1
        set("res", s.map { "\(Int($0.frame.width * sc))×\(Int($0.frame.height * sc)) px (native)" } ?? "–")
    }

    // MARK: actions
    @objc func toSender() { switchRole(to: .sender) }
    @objc func toggleLogin() { app.toggleLogin() }
    @objc func togglePause() { app.togglePause(); tick() }
    @objc func toggleSound() { app.toggleSound() }
    @objc func fitChanged(_ p: NSPopUpButton) { app.fillMode = p.indexOfSelectedItem == 1; app.layer.videoGravity = app.fillMode ? .resizeAspectFill : .resizeAspect }
    @objc func togglePointer(_ b: NSButton) { app.hidePointer = b.state == .on }
    @objc func toggleForward(_ b: NSButton) { app.forwardInput = b.state == .on }
    @objc func toggleAwake(_ b: NSButton) { app.keepAwake = b.state == .on }
    @objc func pair() { app.openPairing() }
    @objc func forget(_ b: NSButton) { if let id = b.identifier?.rawValue { app.forgetID(id); fillPeers() } }
    @objc func resetRole() {
        let a = NSAlert(); a.messageText = "Show the role chooser?"; a.informativeText = "The app restarts and asks what this Mac should do."
        a.addButton(withTitle: "Restart"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { UserDefaults.standard.removeObject(forKey: "role"); relaunchSelf() }
    }
    @objc func copyDiag() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let s = "OpenAirDisplay \(v) · receiver · \(hardwareModel()) · macOS \(osVersionString()) · paired \(app.keys.peers.count) · streaming \(app.streaming) · \(String(format: "%.0f fps %.1f Mbps", fps, mbps))"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}
