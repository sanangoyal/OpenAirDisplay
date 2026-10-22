import Cocoa
import AVFoundation
import VideoToolbox
import Network

let agentLabel = "com.sanan.openairdisplay.receiver"
let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    var onEsc: (() -> Void)?
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onEsc?() } else { super.keyDown(with: e) } }
}

final class RxConn {
    let c: NWConnection
    let hs: Handshake
    var df = Deframer()
    var chan: Channel?
    var authed = false
    let sendQ = DispatchQueue(label: "rxsend", qos: .userInteractive)
    init(_ c: NWConnection, _ hs: Handshake) { self.c = c; self.hs = hs }
}

final class ReceiverApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let keys = Keys(appDir: "OpenAirDisplayReceiver")
    let myName = Host.current().localizedName ?? "Mac"
    var listener: NWListener?
    var active: RxConn?
    let q = DispatchQueue(label: "rx", qos: .userInteractive)
    var win: KeyWindow?
    var layer = AVSampleBufferDisplayLayer()
    var fd: CMVideoFormatDescription?
    var paused = false, streaming = false, cursorHidden = false
    var activity: NSObjectProtocol?
    var peerName = ""
    var rxBytes = 0
    // keyboard + mouse forwarding (opt-in) and connection watchdog
    var forwardInput: Bool { get { UserDefaults.standard.bool(forKey: "rxForward") } set { UserDefaults.standard.set(newValue, forKey: "rxForward"); if streaming { newValue ? setupInput() : teardownInput() } } }
    var inputMonitor: Any?
    var escTimer: Timer?, escFired = false, ringTimer: Timer?, ring: CALayer?
    var lastRx = Date()
    var watchdog: Timer?
    lazy var settings = ReceiverSettings(self)
    var fillMode: Bool { get { UserDefaults.standard.bool(forKey: "rxFill") } set { UserDefaults.standard.set(newValue, forKey: "rxFill") } }
    var hidePointer: Bool { get { UserDefaults.standard.object(forKey: "rxHidePointer") as? Bool ?? true } set { UserDefaults.standard.set(newValue, forKey: "rxHidePointer"); if !newValue, cursorHidden { NSCursor.unhide(); cursorHidden = false } } }
    var keepAwake: Bool { get { UserDefaults.standard.object(forKey: "rxKeepAwake") as? Bool ?? true } set { UserDefaults.standard.set(newValue, forKey: "rxKeepAwake") } }
    func forgetID(_ id: String) { let pub = keys.peer(id: id)?.pub; keys.forget(id: id); if active?.hs.peerPub == pub { hideWindow() } }

    // pairing window
    let codeLock = NSLock()
    var pairExpires = Date.distantPast
    var pairingOpen: Bool { codeLock.lock(); defer { codeLock.unlock() }; return Date() < pairExpires }
    var pairConn: RxConn?, pairBox: NSStackView?
    var pairPanel: NSPanel?, pairLabel: NSTextField?, pairTimer: Timer?

    func applicationWillTerminate(_ n: Notification) { CGAssociateMouseAndMouseCursorPosition(1) }

    var sigSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        // Test hooks: `kill -USR1 <pid>` pauses, `kill -USR2 <pid>` resumes.
        for (sig, act) in [(SIGUSR1, { [weak self] in self?.pause() }), (SIGUSR2, { [weak self] in self?.resume() })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN); let src = DispatchSource.makeSignalSource(signal: sig, queue: .main); src.setEventHandler(handler: act); src.resume(); sigSources.append(src)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        item.button?.image = menuGlyph(filled: false, back: true)
        let m = NSMenu(); m.delegate = self; m.autoenablesItems = false; item.menu = m
        startListener()
        if keys.peers.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openPairing() } }
    }

    // MARK: network
    func service() -> NWListener.Service {
        NWListener.Service(type: "_odisplay._tcp", txtRecord: NWTXTRecord(["id": keys.myID, "v": "1", "pair": pairingOpen ? "1" : "0"]))
    }
    func advertise() { listener?.service = service() }   // tells main Macs we're ready to pair (or not)
    func startListener() {
        dlog("rx startListener")
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 3; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
        guard let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 7777) else { print("listen fail"); retryListener(); return }
        l.service = service()
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            print("listener:", st); dlog("rx listener \(st)")
            if case .failed = st { l?.cancel(); self?.retryListener() }
        }
        l.start(queue: q); listener = l
    }
    func retryListener() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, !self.paused else { return }
            self.listener = nil; self.startListener()
        }
    }

    func accept(_ c: NWConnection) {
        dlog("rx accept \(c.endpoint)")
        let hs = Handshake(role: .server, keys: keys, name: myName)
        hs.serverPairOpen = { [weak self] in self?.pairingOpen ?? false }
        let rc = RxConn(c, hs)
        hs.onNumber = { [weak self, weak rc] n in DispatchQueue.main.async { if let rc = rc { self?.showPairRequest(rc, n) } } }
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: DispatchQueue.main.async { if self?.active === rc { self?.hideWindow() } }
            default: break
            }
        }
        c.start(queue: q)
        recv(rc)
        q.asyncAfter(deadline: .now() + 6) { if !rc.authed && !rc.hs.pairMode { rc.c.cancel() } }
        q.asyncAfter(deadline: .now() + 120) { if !rc.authed { rc.c.cancel() } }
    }

    func recv(_ rc: RxConn) {
        rc.c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
            guard let self = self else { return }
            if let d = d { self.process(rc, d) }
            if done || err != nil { rc.c.cancel() } else { self.recv(rc) }
        }
    }

    func sendPlain(_ rc: RxConn, _ t: UInt8, _ p: Data) { rc.c.send(content: wireFrame(Data([t]) + p), completion: .idempotent) }
    func sendSecure(_ rc: RxConn, _ t: UInt8, _ p: Data) {
        rc.sendQ.async { guard let ch = rc.chan else { return }; rc.c.send(content: wireFrame(ch.seal(t, p)), completion: .idempotent) }
    }

    func process(_ rc: RxConn, _ d: Data) {
        rc.df.push(d)
        do {
            while let body = try rc.df.next() {
                if let ch = rc.chan {
                    guard let (t, p) = ch.open(body) else { rc.c.cancel(); return }
                    secure(rc, t, p)
                } else {
                    guard let t = body.first else { rc.c.cancel(); return }
                    do {
                        let replies = try rc.hs.receive(t, Data(body.dropFirst()))
                        for r in replies { sendPlain(rc, r.0, r.1) }
                        if rc.hs.completed { finish(rc) }
                    } catch let e as WireError {
                        print("handshake rejected:", e.msg)
                        sendPlain(rc, MT.reject, Data(e.msg.utf8))
                        q.asyncAfter(deadline: .now() + 0.3) { rc.c.cancel() }
                        return
                    }
                }
            }
        } catch { rc.c.cancel() }
    }

    func finish(_ rc: RxConn) {
        rc.chan = rc.hs.channel; rc.authed = true
        DispatchQueue.main.async { if rc.hs.pairedNow { self.closePairing() }; self.activate(rc) }
    }

    func secure(_ rc: RxConn, _ t: UInt8, _ p: Data) {
        guard rc === active || !streaming else { return }
        lastRx = Date()
        switch t {
        case MT.config: config(p)
        case MT.frame: frame(p)
        case MT.audio: audio(p)
        case MT.ping:
            var out = Data(p.prefix(8)); var c = decoded.bigEndian
            withUnsafeBytes(of: &c) { out.append(contentsOf: $0) }
            sendSecure(rc, MT.pong, out)
        default: break
        }
    }

    func sendInfo(_ rc: RxConn) {
        let scr = NSScreen.screens.first
        var w = Int((scr?.frame.width ?? 1920) * (scr?.backingScaleFactor ?? 1)), h = Int((scr?.frame.height ?? 1080) * (scr?.backingScaleFactor ?? 1))
        if let num = scr?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, let m = CGDisplayCopyDisplayMode(num) {
            w = max(w, m.pixelWidth); h = max(h, m.pixelHeight)
        }
        let info: [String: Any] = ["name": myName, "w": w, "h": h, "macs": macAddresses(), "hevc": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "ver": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"]
        sendSecure(rc, MT.info, (try? JSONSerialization.data(withJSONObject: info)) ?? Data())
    }

    @objc func screenChanged() {
        guard let rc = active else { return }
        sendInfo(rc)
        if let screen = NSScreen.screens.first, let w = win { w.setFrame(screen.frame, display: true) }
    }

    func activate(_ rc: RxConn) {
        if let old = active, old !== rc { old.c.cancel() }
        active = rc; fd = nil
        peerName = rc.hs.peerName
        sendInfo(rc)
        if rc.hs.pairedNow { closePairing() }
        showWindow()
    }

    // MARK: audio
    var engine: AVAudioEngine?, player: AVAudioPlayerNode?, aformat: AVAudioFormat?
    var aqueued = 0
    let alock = NSLock()
    var soundOn: Bool { get { UserDefaults.standard.object(forKey: "sound") as? Bool ?? true } set { UserDefaults.standard.set(newValue, forKey: "sound") } }

    func startAudio() {
        let e = AVAudioEngine(), pl = AVAudioPlayerNode()
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false) else { return }
        e.attach(pl); e.connect(pl, to: e.mainMixerNode, format: f)
        do { try e.start() } catch { print("audio start failed", error); return }
        engine = e; player = pl; aformat = f
    }
    func stopAudio() {
        player?.stop(); engine?.stop(); engine = nil; player = nil
        alock.lock(); aqueued = 0; alock.unlock()
    }
    func audio(_ p: Data) {
        guard soundOn, p.count > 8, p[p.startIndex] == 2 else { return }
        let frames = (p.count - 1) / 4
        if engine == nil { startAudio() }
        guard let pl = player, let f = aformat else { return }
        alock.lock(); let queued = aqueued; alock.unlock()
        if queued > 10 { return }     // far behind: drop to keep latency low
        guard let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)), let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        p.withUnsafeBytes { raw in
            for i in 0..<frames {
                ch[0][i] = Float(raw.loadUnaligned(fromByteOffset: 1 + 4 * i, as: Int16.self)) / 32768
                ch[1][i] = Float(raw.loadUnaligned(fromByteOffset: 3 + 4 * i, as: Int16.self)) / 32768
            }
        }
        alock.lock(); aqueued += 1; alock.unlock()
        pl.scheduleBuffer(buf) { [weak self] in self?.alock.lock(); if let s = self, s.aqueued > 0 { s.aqueued -= 1 }; self?.alock.unlock() }
        if !pl.isPlaying { pl.play() }
    }

    // MARK: decode
    var decoded: UInt32 = 0
    func config(_ p: Data) {
        var o = 1; var sets: [Data] = []
        let isHEVC = p[0] & 0x80 != 0
        for _ in 0..<Int(p[0] & 0x7F) {
            let l = Int(p[o]) << 8 | Int(p[o + 1]); o += 2
            sets.append(p.subdata(in: o..<(o + l))); o += l
        }
        var ptrs: [UnsafePointer<UInt8>] = []; var sizes: [Int] = []
        for d in sets {
            let m = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: m, count: d.count); ptrs.append(UnsafePointer(m)); sizes.append(d.count)
        }
        var out: CMVideoFormatDescription?
        let r: OSStatus = isHEVC
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &out)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count,
                parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
        ptrs.forEach { $0.deallocate() }
        if r == noErr { fd = out }
    }

    func frame(_ p: Data) {
        guard let fd = fd, p.count > 1 else { return }
        let n = p.count - 1
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil,
              customBlockSource: nil, offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &bb) == noErr, let b = bb else { return }
        p.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress! + 1, blockBuffer: b, offsetIntoDestination: 0, dataLength: n) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var size = n; var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: b, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1,
              sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let s = sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed {
            let m = "\(Date()) layer failed: \(String(describing: layer.error))\n"
            if let h = FileHandle(forWritingAtPath: NSHomeDirectory() + "/rx-error.log") { h.seekToEndOfFile(); h.write(m.data(using: .utf8)!); h.closeFile() } else { try? m.write(toFile: NSHomeDirectory() + "/rx-error.log", atomically: true, encoding: .utf8) }
            layer.flush()
        }
        layer.enqueue(s)
        decoded &+= 1; rxBytes &+= n
    }

    // MARK: fullscreen window
    func showWindow() {
        if streaming { return }
        streaming = true
        item.button?.image = menuGlyph(filled: true, back: true)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-u", "-t", "5"])   // wake the display after a network (dark) wake
        guard let screen = NSScreen.screens.first else { return }
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .mainMenu + 1
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.onEsc = { [weak self] in if self?.forwardInput != true { self?.pause() } }
        let v = NSView(frame: screen.frame); v.wantsLayer = true
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = fillMode ? .resizeAspectFill : .resizeAspect; layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.backgroundColor = NSColor.black.cgColor
        v.layer!.addSublayer(layer)
        w.contentView = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        win = w
        lastRx = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in      // fail-safe: sender vanished without closing -> give the Mac back
            guard let self = self, self.streaming, Date().timeIntervalSince(self.lastRx) > 8 else { return }
            self.hideWindow()
        }
        if forwardInput { setupInput() }
        if hidePointer, !cursorHidden { NSCursor.hide(); cursorHidden = true }
        if keepAwake { activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated], reason: "Streaming display") }
    }

    func hideWindow() {
        guard streaming else { return }
        dlog("rx hideWindow")
        streaming = false
        teardownInput(); watchdog?.invalidate(); watchdog = nil
        item.button?.image = menuGlyph(filled: false, slashed: paused, back: true)
        if let rc = active { sendSecure(rc, MT.bye, Data()); q.asyncAfter(deadline: .now() + 0.25) { rc.c.cancel() } }   // tell the sender, then close
        active = nil
        win?.orderOut(nil); win = nil
        stopAudio()
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    // MARK: keyboard + mouse forwarding
    func sendInput(_ e: InputEvent) { if let rc = active, rc.authed { sendSecure(rc, MT.input, e.encode()) } }

    /// Where the picture sits inside the screen (depends on Fit / Fill).
    func videoRect() -> CGRect {
        let b = layer.bounds
        guard let fd = fd else { return b }
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        guard d.width > 0, d.height > 0 else { return b }
        let sx = b.width / CGFloat(d.width), sy = b.height / CGFloat(d.height)
        let k = fillMode ? max(sx, sy) : min(sx, sy)
        let w = CGFloat(d.width) * k, h = CGFloat(d.height) * k
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    func norm(_ e: NSEvent) -> (Float, Float) {
        let vr = videoRect(), p = e.locationInWindow
        guard vr.width > 1, vr.height > 1 else { return (0, 0) }
        let x = min(max((p.x - vr.minX) / vr.width, 0), 1), y = min(max((p.y - vr.minY) / vr.height, 0), 1)
        return (Float(x), Float(1 - y))
    }

    func setupInput() {
        teardownInput()
        win?.acceptsMouseMovedEvents = true
        CGAssociateMouseAndMouseCursorPosition(0)   // freeze the local pointer so movement is unlimited at the edges
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self = self, self.streaming, e.window === self.win else { return e }
            self.forward(e); return nil
        }
    }

    func teardownInput() {
        hideRing()
        if let m = inputMonitor { NSEvent.removeMonitor(m); inputMonitor = nil }
        escTimer?.invalidate(); escTimer = nil; escFired = false
        win?.acceptsMouseMovedEvents = false
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// "Hold Esc to leave" progress ring: fills over the 1.5 s hold.
    func showRing() {
        guard let v = win?.contentView, let root = v.layer else { return }
        hideRing()
        let size: CGFloat = 84, c = CGPoint(x: size / 2, y: size / 2), r: CGFloat = 30
        let box = CALayer(); box.frame = CGRect(x: v.bounds.midX - size / 2, y: v.bounds.midY - size / 2, width: size, height: size)
        box.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor; box.cornerRadius = size / 2
        let path = CGMutablePath(); path.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: -3 * .pi / 2, clockwise: true)
        func shape(_ color: NSColor) -> CAShapeLayer {
            let s = CAShapeLayer(); s.frame = box.bounds; s.path = path; s.fillColor = nil; s.strokeColor = color.cgColor; s.lineWidth = 5; s.lineCap = .round; return s
        }
        let track = shape(NSColor.white.withAlphaComponent(0.25)), arc = shape(.white)
        let a = CABasicAnimation(keyPath: "strokeEnd"); a.fromValue = 0; a.toValue = 1; a.duration = 1.25; a.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(a, forKey: "fill")
        let t = CATextLayer(); t.string = "esc"; t.fontSize = 15; t.alignmentMode = .center; t.foregroundColor = NSColor.white.cgColor
        t.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2; t.frame = CGRect(x: 0, y: c.y - 9, width: size, height: 20)
        box.addSublayer(track); box.addSublayer(arc); box.addSublayer(t)
        root.addSublayer(box); ring = box
    }
    func hideRing() { ringTimer?.invalidate(); ringTimer = nil; ring?.removeFromSuperlayer(); ring = nil }

    func forward(_ e: NSEvent) {
        let fl = UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        let vr = videoRect()
        var x: Float = 0, y: Float = 0   // pointer moves: movement as a fraction of the picture size
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if vr.width > 1 && vr.height > 1 { x = Float(e.deltaX / vr.width); y = Float(e.deltaY / vr.height) }
        default: break
        }
        func btn(_ k: InputEvent.Kind) { sendInput(InputEvent(kind: k, code: UInt16(min(e.buttonNumber, 2)) | UInt16(max(e.clickCount, 1)) << 8, flags: fl, x: x, y: y)) }
        switch e.type {
        case .mouseMoved: sendInput(InputEvent(kind: .move, flags: fl, x: x, y: y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: btn(.down)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: btn(.up)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: btn(.drag)
        case .scrollWheel:
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            sendInput(InputEvent(kind: .scroll, flags: fl, x: Float(e.scrollingDeltaX * k), y: Float(e.scrollingDeltaY * k)))
        case .flagsChanged: sendInput(InputEvent(kind: .flags, code: e.keyCode, flags: fl))
        case .keyDown:
            if e.keyCode == 53 {   // Esc: tap goes to the main Mac, hold 1.5 s pauses this screen
                if !e.isARepeat && escTimer == nil {
                    escFired = false
                    ringTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.showRing() }   // not for quick taps
                    escTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.escTimer = nil; self?.escFired = true; self?.hideRing(); self?.pause() }
                }
                return
            }
            sendInput(InputEvent(kind: .keyDown, code: e.keyCode, flags: fl))
        case .keyUp:
            if e.keyCode == 53 {
                hideRing()
                if escTimer != nil { escTimer?.invalidate(); escTimer = nil
                    sendInput(InputEvent(kind: .keyDown, code: 53, flags: fl)); sendInput(InputEvent(kind: .keyUp, code: 53, flags: fl)) }
                escFired = false
                return
            }
            sendInput(InputEvent(kind: .keyUp, code: e.keyCode, flags: fl))
        default: break
        }
    }

    func pause() {
        dlog("rx pause")
        paused = true
        item.button?.image = menuGlyph(filled: false, slashed: true, back: true)
        hideWindow()
        listener?.cancel(); listener = nil
    }
    func resume() { dlog("rx resume"); paused = false; item.button?.image = menuGlyph(filled: false, back: true); startListener() }

    // MARK: pairing UI
    func label(_ t: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, width: CGFloat = 380) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: t); f.font = .systemFont(ofSize: size, weight: weight); f.textColor = color
        f.alignment = .center; f.preferredMaxLayoutWidth = width; return f
    }

    func openPairing() {
        if paused { resume() }
        codeLock.lock(); pairExpires = Date().addingTimeInterval(300); codeLock.unlock()
        advertise()
        pairPanel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Pair with your main Mac"; p.level = .floating; p.isReleasedWhenClosed = false; p.delegate = self
        pairPanel = p
        showPairWaiting()
        p.center(); NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil)
        pairTimer?.invalidate()
        pairTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.pairingOpen { self.closePairing(); return }
            let left = Int(self.pairExpires.timeIntervalSinceNow)
            self.pairLabel?.stringValue = String(format: "Ready to pair · closes in %d:%02d", left / 60, left % 60)
        }
    }

    func setPanel(_ views: [NSView]) {
        guard let p = pairPanel else { return }
        let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = 14; s.alignment = .centerX
        s.edgeInsets = NSEdgeInsets(top: 26, left: 24, bottom: 24, right: 24)
        p.contentView = s; p.setContentSize(s.fittingSize); pairBox = s
    }

    func showPairWaiting() {
        let spin = NSProgressIndicator(); spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
        let l = label("Ready to pair · closes in 5:00", size: 12, color: .secondaryLabelColor); pairLabel = l
        setPanel([label("This Mac is ready", size: 18, weight: .bold),
                  label("On your main Mac, open OpenAirDisplay. It will ask “Pair with \(myName)?”. Click Pair there, then check the number here."),
                  spin, l,
                  label("Both Macs need to be on the same network, or cabled together. If macOS asks about Local Network access, click Allow.", size: 11, color: .secondaryLabelColor)])
    }

    /// A main Mac connected in pairing mode: show its name and the 6-digit number, ask for a click.
    func showPairRequest(_ rc: RxConn, _ number: String) {
        guard pairingOpen else { rc.c.cancel(); return }
        if let other = pairConn, other !== rc { sendPlain(rc, MT.reject, Data("busy".utf8)); q.asyncAfter(deadline: .now() + 0.3) { rc.c.cancel() }; return }
        pairConn = rc
        if pairPanel == nil { pairPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false); pairPanel?.title = "Pair with your main Mac"; pairPanel?.level = .floating; pairPanel?.isReleasedWhenClosed = false; pairPanel?.delegate = self; pairPanel?.center() }
        let num = NSTextField(labelWithString: number); num.font = .monospacedSystemFont(ofSize: 48, weight: .semibold); num.alignment = .center
        let ok = NSButton(title: "Pair", target: self, action: #selector(pairAccept)); ok.keyEquivalent = "\r"; ok.bezelStyle = .rounded
        let no = NSButton(title: "Cancel", target: self, action: #selector(pairDecline)); no.bezelStyle = .rounded
        let row = NSStackView(views: [no, ok]); row.spacing = 12
        setPanel([label("“\(rc.hs.peerName)” wants to pair", size: 18, weight: .bold),
                  label("Check that your main Mac shows this same number, then click Pair on both Macs."),
                  num, row,
                  label("If the numbers differ, or you didn't start this, click Cancel.", size: 11, color: .secondaryLabelColor)])
        NSApp.activate(ignoringOtherApps: true); pairPanel?.makeKeyAndOrderFront(nil)
    }

    @objc func pairAccept() { decidePair(true) }
    @objc func pairDecline() { decidePair(false) }
    func decidePair(_ ok: Bool) {
        guard let rc = pairConn else { return }
        pairConn = nil
        rc.sendQ.async { [weak self] in
            guard let self = self else { return }
            do {
                let replies = try rc.hs.serverDecision(ok)
                for r in replies { self.sendPlain(rc, r.0, r.1) }
                if rc.hs.completed { self.finish(rc) }
            } catch {
                self.sendPlain(rc, MT.reject, Data("declined".utf8))
                self.q.asyncAfter(deadline: .now() + 0.3) { rc.c.cancel() }
            }
        }
        if !ok { DispatchQueue.main.async { if self.pairingOpen { self.showPairWaiting() } } }
    }

    func closePairing() {
        codeLock.lock(); pairExpires = .distantPast; codeLock.unlock()
        advertise()
        pairTimer?.invalidate(); pairTimer = nil
        if let rc = pairConn { pairConn = nil; rc.c.cancel() }
        let p = pairPanel; pairPanel = nil; p?.close()
    }
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSPanel) === pairPanel { codeLock.lock(); pairExpires = .distantPast; codeLock.unlock(); advertise(); pairTimer?.invalidate(); pairTimer = nil; if let rc = pairConn { pairConn = nil; rc.c.cancel() } }
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let t = paused ? "Paused" : (streaming ? "Showing \(peerName)" : "Ready · waiting for a Mac")
        let s = NSMenuItem(title: t, action: nil, keyEquivalent: ""); s.isEnabled = true; menu.addItem(s)
        menu.addItem(.separator())
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, on: Bool = false, rep: String? = nil, en: Bool = true) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; i.state = on ? .on : .off
            i.isEnabled = en; i.representedObject = rep; m.addItem(i)
        }
        add(menu, "Pair new Mac…", #selector(pairNew))
        let pm = NSMenu(); pm.autoenablesItems = false
        if keys.peers.isEmpty { add(pm, "None yet", nil, en: false) }
        for p in keys.peers { add(pm, "Forget \(p.name)", #selector(forget(_:)), rep: p.id) }
        let pi = NSMenuItem(title: "Paired Macs (\(keys.peers.count))", action: nil, keyEquivalent: ""); pi.submenu = pm; pi.isEnabled = true; menu.addItem(pi)
        menu.addItem(.separator())
        add(menu, paused ? "Resume" : "Pause (use this Mac normally)", #selector(togglePause))
        add(menu, "Play sound from the other Mac", #selector(toggleSound), on: soundOn)
        add(menu, "Launch at Login", #selector(toggleLogin), on: FileManager.default.fileExists(atPath: agentPath))
        add(menu, "This Mac's ID: \(keys.myID)", nil, en: false)
        add(menu, "Settings…", #selector(openSettings))
        add(menu, "Change role…", #selector(changeRole))
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); q.isEnabled = true; menu.addItem(q)
    }
    @objc func openSettings() { settings.show() }
    @objc func changeRole() { switchRole(to: .sender) }
    @objc func pairNew() { openPairing() }
    @objc func forget(_ s: NSMenuItem) { if let id = s.representedObject as? String { keys.forget(id: id); if active?.hs.peerPub == keys.peer(id: id)?.pub { hideWindow() } } }
    @objc func toggleSound() { soundOn.toggle(); if !soundOn { stopAudio() } }
    @objc func togglePause() { paused ? resume() : pause() }
    @objc func toggleLogin() {
        if FileManager.default.fileExists(atPath: agentPath) { try? FileManager.default.removeItem(atPath: agentPath); return }
        let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath], "RunAtLoad": true]
        (plist as NSDictionary).write(toFile: agentPath, atomically: true)
    }
}
