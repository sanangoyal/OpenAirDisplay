import Cocoa
import ScreenCaptureKit
import VideoToolbox
import Network
import AudioToolbox
import CoreMedia

struct Preset { let name: String; let short: String; let scale: Double; let fps: Int; let bpp: Double }
let presets = [
    Preset(name: "Ultra · native resolution · wired only", short: "Ultra", scale: 1.0, fps: 60, bpp: 0.30),
    Preset(name: "Best · full resolution · 60 fps", short: "Full 60", scale: 1.0, fps: 60, bpp: 0.12),
    Preset(name: "Balanced · ⅔ resolution · 60 fps", short: "⅔ 60", scale: 2.0 / 3.0, fps: 60, bpp: 0.16),
    Preset(name: "Light · ½ resolution · 30 fps", short: "½ 30", scale: 0.5, fps: 30, bpp: 0.24),
    Preset(name: "Smooth · 4K · true 60 fps · wired only", short: "4K 60", scale: 0.9375, fps: 60, bpp: 0.20),   // fixed pick, not part of the Auto ladder
]
let autoLadder = 4
let defaults = UserDefaults.standard
func even(_ v: Double) -> Int { max(2, Int(v) & ~1) }
/// H.264 Level 5.2 allows 2,073,600 macroblocks/s: cap fps so big frames stay at Level <= 5.2 (older hardware decoders reject Level 6)
func effFps(_ w: Int, _ h: Int, _ f: Int, hevc: Bool = false) -> Int {
    let cap = defaults.integer(forKey: "fpsCap")
    let want = cap > 0 ? min(f, cap) : f
    return hevc ? want : min(want, 2_073_600 / (((w + 15) / 16) * ((h + 15) / 16)))   // HEVC has no such limit at these sizes
}
@available(macOS 13.0, *) func applyColor(_ cfg: SCStreamConfiguration) {
    switch defaults.string(forKey: "colorProfile") ?? "auto" {
    case "srgb": cfg.colorSpaceName = CGColorSpace.sRGB
    case "p3": cfg.colorSpaceName = CGColorSpace.displayP3
    default: break
    }
}

@available(macOS 13.0, *) final class Out: NSObject, SCStreamOutput {
    weak var s: Session?
    func stream(_ st: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { s?.handleAudio(sb); return }
        guard type == .screen, sb.isValid,
              let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = a.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        s?.handle(pb, CMSampleBufferGetPresentationTimeStamp(sb))
    }
}

@available(macOS 13.0, *) final class Session {
    let endpoint: NWEndpoint
    let keys: Keys
    let pairCode: String?
    var preset: Preset
    let mirror: Bool
    var hs: Handshake
    var chan: Channel?
    var deframer = Deframer()
    var receiverName = "iMac"
    var lastPongAt = Date()
    var onNumber: ((String, @escaping (Bool) -> Void) -> Void)?   // pairing: show the 6-digit number, user answers yes/no
    var onVersion: ((String) -> Void)?
    var capW = 0, capH = 0, backW = 0, backH = 0

    let q = DispatchQueue(label: "net", qos: .userInitiated)
    let sendQ = DispatchQueue(label: "send", qos: .userInitiated)
    let capQ = DispatchQueue(label: "cap", qos: .userInitiated)
    var conn: NWConnection!
    var vd: CGVirtualDisplay?
    var enc: VTCompressionSession?
    var stream: SCStream?
    let out = Out()
    let lock = NSLock()
    var pending = 0, frames = 0, bytes = 0, firstFrame = true
    var live = false, ended = false
    var onEnd: ((String?) -> Void)?
    var onLive: (() -> Void)?
    var onPaired: ((Peer) -> Void)?
    var fps = 0.0, mbps = 0.0
    var dropped = 0, startedAt = Date(), linkType = "…", iface = "", rttMs = 0.0
    var rxFrames = 0, lastRx = 0, rxFps = 0.0
    var statTimer: Timer?, idleTimer: Timer?
    var encInfo = "—"
    var rxHEVC = false, hevc = false   // receiver can hardware-decode HEVC / this session uses it
    var pointW = 0, pointH = 0
    var lastPB: CVPixelBuffer?, lastEnc = Date.distantPast
    var audioOn = true
    var forceIface: NWInterface?
    var rxW = 0, rxH = 0
    let audioQ = DispatchQueue(label: "audio", qos: .userInitiated)

    init(endpoint: NWEndpoint, keys: Keys, name: String, code: String?, preset: Preset, mirror: Bool) {
        self.endpoint = endpoint; self.keys = keys; self.pairCode = code; self.preset = preset; self.mirror = mirror
        hs = Handshake(role: .client, keys: keys, name: name)
        hs.clientCode = code
        hs.onNumber = { [weak self] n in DispatchQueue.main.async { guard let self = self, !self.ended else { return }; self.onNumber?(n) { ok in self.pairDecision(ok) } } }
        out.s = self
    }

    // MARK: sizing
    func dims(_ p: Preset) -> (Int, Int) {
        let bw = Double(backW) * p.scale, bh = Double(backH) * p.scale
        if !mirror { return (even(bw), even(bh)) }
        let id = CGMainDisplayID()
        let m = CGDisplayCopyDisplayMode(id)
        let sw = Double(m?.pixelWidth ?? CGDisplayPixelsWide(id)), sh = Double(m?.pixelHeight ?? CGDisplayPixelsHigh(id))
        let sc = min(bw / sw, bh / sh, 1.0)
        return (even(sw * sc), even(sh * sc))
    }

    // MARK: connection
    func start() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true; tcp.connectionTimeout = 4
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 3; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        if let i = forceIface { params.requiredInterface = i }
        conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                let (t, p) = self.hs.clientHello()
                self.sendPlain(t, p)
                self.recvLoop()
            case .waiting, .failed, .cancelled:
                self.fail(self.live ? "Connection lost" : nil)
            default: break
            }
        }
        conn.start(queue: q)
        // A Bonjour endpoint that vanished (receiver paused / gone) can sit in 'preparing' forever: give up, then retry cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !self.ended, !self.live else { return }
            if case .ready = self.conn.state { return }
            dlog("tx connect timeout state=\(self.conn.state)")
            self.end(nil)
        }
    }

    func pairDecision(_ ok: Bool) {
        guard !ended else { return }
        do { for m in try hs.clientDecision(ok) { sendPlain(m.0, m.1) } } catch { fail("Pairing cancelled") }
    }

    func fail(_ reason: String?) { DispatchQueue.main.async { self.end(reason) } }

    func recvLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
            guard let self = self, !self.ended else { return }
            if let d = d { self.onData(d) }
            if done || err != nil { self.fail(self.live ? "iMac closed connection" : nil) } else { self.recvLoop() }
        }
    }

    func onData(_ d: Data) {
        deframer.push(d)
        do {
            while let body = try deframer.next() {
                if let ch = chan {
                    guard let (t, p) = ch.open(body) else { fail("Decryption failed"); return }
                    secure(t, p)
                } else {
                    guard let t = body.first else { fail("Bad frame"); return }
                    let replies = try hs.receive(t, Data(body.dropFirst()))
                    for r in replies { sendPlain(r.0, r.1) }
                    if hs.completed {
                        chan = hs.channel
                        if hs.pairedNow, let peer = keys.peer(pub: hs.peerPub) { DispatchQueue.main.async { self.onPaired?(peer) } }
                    }
                }
            }
        } catch let e as WireError { fail(e.msg) } catch { fail("Protocol error") }
    }

    func secure(_ t: UInt8, _ p: Data) {
        switch t {
        case MT.info:
            guard let o = try? JSONSerialization.jsonObject(with: p) as? [String: Any],
                  let w = o["w"] as? Int, let h = o["h"] as? Int else { fail("Bad receiver info"); return }
            let name = o["name"] as? String ?? hs.peerName
            let macs = o["macs"] as? [String] ?? []
            let rver = o["ver"] as? String
            let rhevc = o["hevc"] as? Bool ?? false
            DispatchQueue.main.async {
                self.onVersion?(rver ?? "older")
                self.rxHEVC = rhevc
                if !macs.isEmpty, let pr = self.keys.peer(pub: self.hs.peerPub), pr.macs ?? [] != macs { self.keys.setMacs(id: pr.id, macs: macs) }
                if self.live, w != self.rxW || h != self.rxH { self.end("Restarting"); return }   // receiver display changed: resize
                self.goLive(name: name, w: w, h: h)
            }
        case MT.input:
            if let ev = InputEvent(p) { DispatchQueue.main.async { if !self.ended { Injector.shared.handle(ev, display: self.vd?.displayID ?? CGMainDisplayID()) } } }
        case MT.bye: fail("Receiver paused")
        case MT.pong:
            lastPongAt = Date()
            guard p.count >= 12 else { return }
            let ts = p.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
            let cnt = p.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
            rttMs = Double(DispatchTime.now().uptimeNanoseconds &- ts) / 1e6
            rxFrames = Int(cnt)
        default: break
        }
    }

    func sendPlain(_ t: UInt8, _ p: Data) {
        conn.send(content: wireFrame(Data([t]) + p), completion: .idempotent)
    }

    func send(_ t: UInt8, _ p: Data, counted: Bool = false) {
        if counted { lock.lock(); pending += 1; lock.unlock() }
        sendQ.async { [weak self] in
            guard let self = self, let ch = self.chan else { return }
            self.conn.send(content: wireFrame(ch.seal(t, p)), completion: .contentProcessed { [weak self] _ in
                guard let self = self, counted else { return }
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
            })
        }
    }

    // MARK: go live (after authenticated handshake + receiver info)
    func goLive(name: String, w: Int, h: Int) {
        if live || ended { return }
        live = true
        receiverName = name; rxW = w; rxH = h
        // resolution: match receiver (auto-fit) or a manual target; never above the hardware H.264 size limit
        var tw = 4096.0, th = 2304.0
        switch defaults.string(forKey: "resMode") ?? "match" {
        case "4k": tw = 3840; th = 2160
        case "1440": tw = 2560; th = 1440
        case "1080": tw = 1920; th = 1080
        case "custom":
            let cw = Double(max(640, min(4096, defaults.integer(forKey: "resW")))), ch = Double(max(360, min(2304, defaults.integer(forKey: "resH"))))
            backW = even(cw); backH = even(ch)
        default: break
        }
        if (defaults.string(forKey: "resMode") ?? "match") != "custom" {
            let sc = min(1.0, tw / Double(w), th / Double(h))
            backW = even(Double(w) * sc); backH = even(Double(h) * sc)
        }

        var id = CGMainDisplayID()
        if !mirror {
            let hm = defaults.string(forKey: "hidpi") ?? "auto"
            let hi = hm == "on" ? true : hm == "off" ? false : backW >= 2560
            let pw = hi ? backW / 2 : backW, ph = hi ? backH / 2 : backH
            pointW = pw; pointH = ph
            let d = CGVirtualDisplayDescriptor()
            d.name = receiverName.isEmpty ? "\(name) (Remote)" : receiverName
            d.vendorID = 0x1234; d.productID = 0x4321
            d.serialNum = UInt32(Keys.fp(hs.peerPub).prefix(8), radix: 16) ?? 1
            d.maxPixelsWide = UInt32(backW); d.maxPixelsHigh = UInt32(backH)
            d.sizeInMillimeters = CGSize(width: Double(backW) / 8, height: Double(backH) / 8)
            d.redPrimary = CGPoint(x: 0.64, y: 0.33); d.greenPrimary = CGPoint(x: 0.30, y: 0.60)
            d.bluePrimary = CGPoint(x: 0.15, y: 0.06); d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
            d.queue = DispatchQueue.main
            guard let v = CGVirtualDisplay(descriptor: d) else { end("Virtual display failed"); return }
            let st = CGVirtualDisplaySettings(); st.hiDPI = hi ? 1 : 0
            st.modes = hi ? [CGVirtualDisplayMode(width: UInt(pw), height: UInt(ph), refreshRate: 60),
                             CGVirtualDisplayMode(width: UInt(backW), height: UInt(backH), refreshRate: 60)]
                          : [CGVirtualDisplayMode(width: UInt(backW), height: UInt(backH), refreshRate: 60)]
            guard v.apply(st) else { end("Display settings failed"); return }
            vd = v; id = v.displayID
        }
        hevc = rxHEVC && (defaults.string(forKey: "codec") ?? "auto") != "h264"
        let (cw, ch) = dims(preset); capW = cw; capH = ch
        guard makeEncoder(cw, ch) else { end("Encoder failed"); return }
        let fpsT = effFps(cw, ch, preset.fps, hevc: hevc)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                var disp: SCDisplay?
                for _ in 0..<20 {
                    let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    disp = c.displays.first { $0.displayID == id }
                    if disp != nil { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                guard let dd = disp else { await MainActor.run { self.end("Display not found") }; return }
                let cfg = SCStreamConfiguration()
                cfg.width = cw; cfg.height = ch
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fpsT))
                cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                cfg.queueDepth = 3; cfg.showsCursor = true; applyColor(cfg)
                cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2; cfg.excludesCurrentProcessAudio = true
                let s = SCStream(filter: SCContentFilter(display: dd, excludingWindows: []), configuration: cfg, delegate: nil)
                try s.addStreamOutput(self.out, type: .screen, sampleHandlerQueue: self.capQ)
                try s.addStreamOutput(self.out, type: .audio, sampleHandlerQueue: self.audioQ)
                try await s.startCapture()
                await MainActor.run {
                    if self.ended { Task { try? await s.stopCapture() } } else { self.stream = s; self.startStats(); self.onLive?() }
                }
            } catch {
                let msg = "\(error)".contains("-3801") || "\(error)".lowercased().contains("declined") ? "PERMISSION" : "Capture error"
                await MainActor.run { self.end(msg) }
            }
        }
    }

    func setPreset(_ p: Preset, force: Bool = false) {
        guard live, !ended, force || p.name != preset.name else { return }
        preset = p
        let (w, h) = dims(p)
        capQ.async { [weak self] in
            guard let self = self, !self.ended else { return }
            if let e = self.enc { VTCompressionSessionCompleteFrames(e, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(e) }
            self.enc = nil
            self.capW = w; self.capH = h
            if !self.makeEncoder(w, h) { DispatchQueue.main.async { self.end("Encoder failed") } }
        }
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(effFps(w, h, p.fps, hevc: hevc)))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 3; cfg.showsCursor = true; applyColor(cfg)
        cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2; cfg.excludesCurrentProcessAudio = true
        if let st = stream { Task { try? await st.updateConfiguration(cfg) } }
    }

    // MARK: stats
    func startStats() {
        var lf = 0, lb = 0
        startedAt = Date(); refreshLink()
        // static screen => ScreenCaptureKit sends nothing; resend the last frame so the receiver never stays blank
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.live, !self.ended, self.enc != nil, Date().timeIntervalSince(self.lastEnc) > 0.5 else { return }
            self.lock.lock(); let pb = self.lastPB; self.lock.unlock()
            if let pb = pb { self.handle(pb, CMClockGetTime(CMClockGetHostTimeClock())) }
        }
        var lt = Date(); lastPongAt = Date()
        statTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date(); let dt = max(0.05, now.timeIntervalSince(lt)); lt = now
            if now.timeIntervalSince(self.lastPongAt) > 5 { self.end("Receiver not responding"); return }   // dead link: drop and reconnect
            let f = Double(self.frames - lf) / dt, m = Double(self.bytes - lb) * 8 / 1e6 / dt
            let r = Double(self.rxFrames - self.lastRx) / dt
            self.fps = self.fps * 0.4 + f * 0.6; self.mbps = self.mbps * 0.4 + m * 0.6; self.rxFps = self.rxFps * 0.4 + r * 0.6
            lf = self.frames; lb = self.bytes; self.lastRx = self.rxFrames
            self.refreshLink()
            var ts = DispatchTime.now().uptimeNanoseconds.bigEndian
            self.send(MT.ping, Data(bytes: &ts, count: 8))
        }
    }

    func refreshLink() {
        if let path = conn.currentPath {
            iface = path.availableInterfaces.first?.name ?? ""
            if iface.hasPrefix("bridge") { linkType = "Thunderbolt" }
            else { linkType = path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : (path.usesInterfaceType(.wifi) ? "Wi-Fi" : "Other") }
        }
    }

    // MARK: encoder
    func makeEncoder(_ w: Int, _ h: Int) -> Bool {
        var s: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let sess = s else { return false }
        func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(sess, key: k, value: v as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        let fp = effFps(w, h, preset.fps, hevc: hevc)
        if hevc { set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel) } else {
        set(kVTCompressionPropertyKey_ProfileLevel, ((w + 15) / 16) * ((h + 15) / 16) * fp > 983_040 ? kVTProfileLevel_H264_High_5_2 : kVTProfileLevel_H264_High_AutoLevel) }
        let brOverride = defaults.bool(forKey: "bitrateOn") ? (defaults.object(forKey: "bitrateTarget") as? Int ?? 80) : 0
        set(kVTCompressionPropertyKey_AverageBitRate, brOverride > 0 ? brOverride * 1_000_000 : Int(Double(w * h * fp) * preset.bpp * (hevc ? 0.65 : 1.0)))
        switch defaults.string(forKey: "colorProfile") ?? "auto" {
        case "srgb":
            set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
            set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
            set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        case "p3":
            set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_P3_D65)
            set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
            set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        default: break
        }
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fp)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30)
        VTCompressionSessionPrepareToEncodeFrames(sess)
        enc = sess; firstFrame = true
        return true
    }

    func handle(_ pb: CVPixelBuffer, _ pts: CMTime) {
        lock.lock(); let p = pending; lastPB = pb; lock.unlock()
        if p > 2 { dropped += 1 }
        guard !ended, let e = enc, p <= 2, CVPixelBufferGetWidth(pb) == capW else { return }
        var props: CFDictionary? = nil
        if firstFrame { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary; firstFrame = false }
        lastEnc = Date()
        VTCompressionSessionEncodeFrame(e, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self = self, status == noErr, let sb = sb else { return }
            var key = true
            if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
               let f = a.first, (f[kCMSampleAttachmentKey_NotSync] as? Bool) == true { key = false }
            if key, let fd = CMSampleBufferGetFormatDescription(sb) {
                let w0 = self.capW, h0 = self.capH
                var cfg = Data(); var count = 0
                let isH = self.hevc
                func ps(_ i: Int, _ ptr: inout UnsafePointer<UInt8>?, _ sz: inout Int, _ cnt: UnsafeMutablePointer<Int>?) {
                    if isH { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz, parameterSetCountOut: cnt, nalUnitHeaderLengthOut: nil) }
                    else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz, parameterSetCountOut: cnt, nalUnitHeaderLengthOut: nil) }
                }
                var p0: UnsafePointer<UInt8>? = nil; var s0 = 0
                ps(0, &p0, &s0, &count)
                cfg.append(UInt8(count) | (isH ? 0x80 : 0))   // high bit = HEVC
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>? = nil; var sz = 0
                    ps(i, &ptr, &sz, nil)
                    var l = UInt16(sz).bigEndian
                    withUnsafeBytes(of: &l) { cfg.append(contentsOf: $0) }
                    if i == 0, sz > 3 {
                        if isH { self.encInfo = "HEVC Main" }
                        else { self.encInfo = "\(ptr![1] == 100 ? "High" : ptr![1] == 77 ? "Main" : "Baseline") L\(Double(ptr![3]) / 10)" }
                    }
                    cfg.append(ptr!, count: sz)
                }
                self.send(MT.config, cfg)
            }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
            let n = CMBlockBufferGetDataLength(bb)
            var d = Data(count: n + 1); d[0] = key ? 1 : 0
            d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress! + 1) }
            self.send(MT.frame, d, counted: true)
            self.frames += 1; self.bytes += n
        }
    }

    /// System audio -> 16-bit stereo PCM @48k (about 1.5 Mbps, no codec latency)
    func handleAudio(_ sb: CMSampleBuffer) {
        guard audioOn, !ended, chan != nil, sb.isValid, CMSampleBufferGetNumSamples(sb) > 0,
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16); defer { raw.deallocate() }
        let ablp = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var bb: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablp, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &bb) == noErr else { return }
        let abl = UnsafeMutableAudioBufferListPointer(ablp)
        let nonInter = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let chans = Int(asbd.mChannelsPerFrame)
        var n = CMSampleBufferGetNumSamples(sb)
        var samples = [Int16](repeating: 0, count: n * 2)
        @inline(__always) func cv(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32767) }
        if nonInter, abl.count >= 1 {
            n = min(n, Int(abl[0].mDataByteSize) / 4)
            guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = abl.count >= 2 ? (abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            for i in 0..<n { samples[2 * i] = cv(l[i]); samples[2 * i + 1] = cv(r[i]) }
        } else if abl.count >= 1, let p = abl[0].mData?.assumingMemoryBound(to: Float.self), chans >= 1 {
            n = min(n, Int(abl[0].mDataByteSize) / (4 * chans))
            for i in 0..<n { samples[2 * i] = cv(p[i * chans]); samples[2 * i + 1] = cv(p[i * chans + (chans > 1 ? 1 : 0)]) }
        } else { return }
        var d = Data([2])
        samples.withUnsafeBytes { d.append(contentsOf: UnsafeRawBufferPointer(rebasing: $0[0..<(n * 4)])) }
        send(MT.audio, d)
    }

    func end(_ reason: String?) {
        if ended { return }
        ended = true
        DispatchQueue.main.async { Injector.shared.releaseAll() }
        statTimer?.invalidate(); idleTimer?.invalidate(); lastPB = nil
        conn.cancel()
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        if let e = enc { VTCompressionSessionInvalidate(e) }
        enc = nil
        vd = nil
        onEnd?(reason)
    }
}
