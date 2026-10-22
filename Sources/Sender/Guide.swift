import Cocoa

@available(macOS 13.0, *) enum StepState { case pending, current, done }

/// Round step badge: number / check.
@available(macOS 13.0, *) final class Badge: NSView {
    var state: StepState = .pending { didSet { needsDisplay = true } }
    var number = 1
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }
    override func draw(_ r: NSRect) {
        let c = bounds.insetBy(dx: 1, dy: 1)
        let circle = NSBezierPath(ovalIn: c)
        switch state {
        case .done:
            NSColor.systemGreen.setFill(); circle.fill()
            let p = NSBezierPath(); p.lineWidth = 2.4; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: 9, y: 15.5)); p.line(to: NSPoint(x: 13, y: 11)); p.line(to: NSPoint(x: 21, y: 20))
            NSColor.white.setStroke(); p.stroke()
        case .current, .pending:
            let cur = state == .current
            (cur ? NSColor.controlAccentColor : NSColor.clear).setFill(); circle.fill()
            if !cur { NSColor.tertiaryLabelColor.setStroke(); circle.lineWidth = 1.5; circle.stroke() }
            let s = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: cur ? NSColor.white : NSColor.secondaryLabelColor])
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
        }
    }
}

/// One step row: badge, title, status line, (i) info popover, action button.
@available(macOS 13.0, *) final class StepCard: NSView {
    let badge = Badge()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(wrappingLabelWithString: "")
    let info = NSButton()
    let action = NSButton(title: "", target: nil, action: nil)
    var infoText = ""
    var state: StepState = .pending { didSet { apply() } }
    private var pop: NSPopover?

    init(number: Int, heading: String, info text: String) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.borderWidth = 1
        badge.number = number; infoText = text
        title.stringValue = heading; title.font = .systemFont(ofSize: 14, weight: .semibold)
        sub.font = .systemFont(ofSize: 12); sub.textColor = .secondaryLabelColor
        sub.maximumNumberOfLines = 2; sub.preferredMaxLayoutWidth = 290
        info.bezelStyle = .regularSquare; info.isBordered = false
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "More info")
        info.contentTintColor = .secondaryLabelColor
        info.target = self; info.action = #selector(showInfo)
        action.bezelStyle = .rounded; action.controlSize = .regular
        let texts = NSStackView(views: [title, sub]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 2
        let row = NSStackView(views: [badge, texts, NSView(), info, action]); row.orientation = .horizontal
        row.spacing = 12; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }

    func apply() {
        badge.state = state
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (state == .current ? NSColor.controlAccentColor.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).cgColor
            layer?.borderColor = (state == .current ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.separatorColor).cgColor
        }
        title.textColor = state == .pending ? .secondaryLabelColor : .labelColor
    }

    func set(_ status: String, button: String? = nil, state s: StepState) {
        sub.stringValue = status
        action.isHidden = button == nil || s == .pending
        if let b = button { action.title = b }
        state = s
    }

    @objc func showInfo() {
        if let p = pop, p.isShown { p.close(); return }
        let l = NSTextField(wrappingLabelWithString: infoText)
        l.font = .systemFont(ofSize: 12); l.preferredMaxLayoutWidth = 280
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 308, height: 10))
        l.frame = NSRect(x: 14, y: 12, width: 280, height: 10)
        l.sizeToFit(); l.frame.size.width = 280
        let h = l.fittingSize.height
        l.frame = NSRect(x: 14, y: 12, width: 280, height: h)
        v.frame.size.height = h + 24
        v.addSubview(l)
        let vc = NSViewController(); vc.view = v
        let p = NSPopover(); p.behavior = .transient; p.contentViewController = vc
        p.show(relativeTo: info.bounds, of: info, preferredEdge: .maxY)
        pop = p
    }
}

/// Guided setup: 4 steps, live status, one clear action at a time.
@available(macOS 13.0, *) final class Guide: NSObject, NSWindowDelegate {
    unowned let app: SenderApp
    var win: NSWindow?
    var timer: Timer?
    var cards: [StepCard] = []
    var progress = NSTextField(labelWithString: "")
    var bar = NSProgressIndicator()
    var done = NSButton()

    init(app: SenderApp) { self.app = app }

    func show() {
        if let w = win { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let W: CGFloat = 540
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "OpenAirDisplay Setup"; w.isReleasedWhenClosed = false; w.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let h1 = NSTextField(labelWithString: "Use another Mac as a display"); h1.font = .systemFont(ofSize: 18, weight: .bold)
        let h2 = NSTextField(wrappingLabelWithString: "Four quick steps. This window updates live, so just follow the highlighted step.")
        h2.font = .systemFont(ofSize: 12); h2.textColor = .secondaryLabelColor; h2.preferredMaxLayoutWidth = 400
        let ht = NSStackView(views: [h1, h2]); ht.orientation = .vertical; ht.alignment = .leading; ht.spacing = 2
        let header = NSStackView(views: [icon, ht]); header.orientation = .horizontal; header.spacing = 14; header.alignment = .centerY

        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 4; bar.style = .bar
        progress.font = .systemFont(ofSize: 11, weight: .medium); progress.textColor = .secondaryLabelColor
        let pr = NSStackView(views: [bar, progress]); pr.orientation = .horizontal; pr.spacing = 10; pr.alignment = .centerY
        progress.setContentHuggingPriority(.required, for: .horizontal)
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        cards = [
            StepCard(number: 1, heading: "Install on both Macs", info:
                "Both Macs run the same app.\n\n• This Mac: “OpenAirDisplay” (you're running it).\n• Other Mac (the screen you want to use): copy this same “OpenAirDisplay” app to its Applications folder and open it. When asked, choose “Be the extra screen for another Mac”. Use “Show app” below to find the file to copy.\n\nBoth Macs must be on the same network, or joined by an Ethernet or Thunderbolt cable."),
            StepCard(number: 2, heading: "Allow Screen Recording", info:
                "macOS requires this permission before an app can capture a display.\n\nThe app only captures its own virtual display. Nothing is stored, and everything sent to the other Mac is encrypted.\n\nIf macOS also asks about Local Network access, click Allow: it is how the two Macs find each other."),
            StepCard(number: 3, heading: "Pair the two Macs", info:
                "Pairing is done once.\n\nThe other Mac says it is ready to pair and a window here asks to pair with it. Click Pair on both Macs after checking they show the same 6-digit number. The Macs then remember each other, and no one else on your network can pair without you being at both Macs.\n\nAfter pairing, they reconnect on their own."),
            StepCard(number: 4, heading: "Connect", info:
                "This creates a virtual display sized to the other Mac's screen. Drag windows onto it like any monitor.\n\nFor the lowest lag use an Ethernet or Thunderbolt cable. Wi-Fi works, but quality is lowered automatically (Quality › Auto)."),
        ]
        cards[0].action.target = self; cards[0].action.action = #selector(revealReceiver)
        cards[1].action.target = self; cards[1].action.action = #selector(grantPermission)
        cards[2].action.target = self; cards[2].action.action = #selector(pair)
        cards[3].action.target = self; cards[3].action.action = #selector(connectNow)

        done = NSButton(title: "Close", target: self, action: #selector(finish)); done.keyEquivalent = "\r"; done.bezelStyle = .rounded
        let foot = NSStackView(views: [NSView(), done]); foot.orientation = .horizontal

        var views: [NSView] = [header, pr] + cards + [foot]
        let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = 12
        s.setCustomSpacing(18, after: header)
        s.setCustomSpacing(18, after: cards[3])
        s.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 18, right: 24)
        for v in [pr, foot] + cards { v.widthAnchor.constraint(equalToConstant: W - 48).isActive = true }
        views = []
        w.contentView = s
        w.setContentSize(s.fittingSize)
        w.center(); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        win = w
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard cards.count == 4 else { return }
        let perm = CGPreflightScreenCaptureAccess()
        let names = app.found.values.map { $0.name }.sorted()
        let paired = app.keys.peers.first
        let unpaired = app.found.values.first { app.keys.peer(id: $0.id) == nil }
        let live = app.session?.stream != nil
        let ok = [!names.isEmpty || paired != nil, perm, paired != nil, live]
        let cur = ok.firstIndex(of: false) ?? 4
        func st(_ i: Int) -> StepState { ok[i] ? .done : (i == cur ? .current : .pending) }

        cards[0].set(names.isEmpty ? "This Mac ready. Waiting for the other Mac to open OpenAirDisplay as the extra screen…" : "Both Macs ready. Found \(names.joined(separator: ", "))",
                     button: names.isEmpty && receiverApp() != nil ? "Show app to copy" : nil, state: st(0))
        cards[1].set(perm ? "Allowed" : "Click Allow, then switch on “OpenAirDisplay” in the list that opens.", button: "Allow…", state: st(1))
        if let p = paired { cards[2].set("Paired with \(p.name)", state: st(2)) }
        else if let f = unpaired { cards[2].set("\(f.name) is ready. Click Pair, then check both Macs show the same number.", button: "Pair…", state: st(2)) }
        else { cards[2].set("Waiting for the other Mac to appear.", state: st(2)) }
        if live { cards[3].set("Connected to \(app.session?.receiverName ?? "receiver") over \(app.session?.linkType ?? "network")", state: st(3)) }
        else { cards[3].set(app.status, button: "Connect Now", state: st(3)) }

        bar.doubleValue = Double(min(cur, 4)); progress.stringValue = cur >= 4 ? "All set" : "Step \(cur + 1) of 4"
        done.title = cur >= 4 ? "Done" : "Close"
    }

    func receiverApp() -> URL? { Bundle.main.bundleURL }

    @objc func revealReceiver() { if let u = receiverApp() { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func grantPermission() { _ = CGRequestScreenCaptureAccess(); app.openPrivacy() }
    @objc func pair() {
        if let f = app.found.values.first(where: { app.keys.peer(id: $0.id) == nil }) { app.offerPair(f, userAsked: true) }
    }
    @objc func connectNow() { app.enabled = true; app.tick() }
    @objc func finish() { win?.close() }
    func windowWillClose(_ n: Notification) {
        timer?.invalidate(); timer = nil; win = nil; cards = []
        defaults.set(true, forKey: "onboarded")
    }
}
