import Carbon.HIToolbox
import Cocoa
import Network
import ServiceManagement
import UserNotifications
import SwiftUI

final class Ladder {
    var idx = 1, bad = 0, good = 0, lastDropped = 0
    var lastChange = Date.distantPast
    var blocked = [Date](repeating: .distantPast, count: presets.count)
}

@available(macOS 13.0, *) struct Found { let id: String; let name: String; let endpoint: NWEndpoint; let ifaces: [NWInterface]; var pairing = false }

@available(macOS 13.0, *) final class SenderApp: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let keys = Keys(appDir: "AirDisplay")
    let myName = Host.current().localizedName ?? "MacBook"
    var session: Session?                 // primary receiver (targetID)
    var extras: [String: Session] = [:]   // additional receivers used at the same time
    var browser: NWBrowser?
    var found: [String: Found] = [:]
    var status = "Looking for receiver…"
    var permissionProblem = false
    var timer: Timer?, autoTimer: Timer?, liveTimer: Timer?
    var statItems: [NSMenuItem] = []
    // Auto-quality state lives in a Ladder: one for the primary receiver, one per extra receiver, so a slow Wi-Fi Mac never drags down a wired one.
    let L0 = Ladder()
    var extraLadders: [String: Ladder] = [:]
    var effIdx: Int { get { L0.idx } set { L0.idx = newValue } }
    var badSecs: Int { get { L0.bad } set { L0.bad = newValue } }
    var goodSecs: Int { get { L0.good } set { L0.good = newValue } }
    var lastDropped: Int { get { L0.lastDropped } set { L0.lastDropped = newValue } }
    var lastChange: Date { get { L0.lastChange } set { L0.lastChange = newValue } }
    var blockedUntil: [Date] { get { L0.blocked } set { L0.blocked = newValue } }
    var guide: Guide?
    var ctlServer: ControlServer?
    let live = Live()
    var settings: SettingsWindow?
    var uiTimer: Timer?
    var wasLive = false, lastLink = ""
    var offeredSwitch = false
    var offlineSince: Date?, lastWake = Date.distantPast, wakeTries = 0
    var autoWake: Bool { get { defaults.object(forKey: "autoWake") as? Bool ?? true } set { defaults.set(newValue, forKey: "autoWake") } }
    var badIface: [String: Date] = [:]
    var linkMode: Int { get { defaults.integer(forKey: "linkMode") } set { defaults.set(newValue, forKey: "linkMode") } }   // 0 auto, 1 wired only, 2 Wi-Fi only

    var enabled: Bool { get { defaults.object(forKey: "enabled") as? Bool ?? true } set { defaults.set(newValue, forKey: "enabled") } }
    var targetID: String? { get { defaults.string(forKey: "targetID") } set { defaults.set(newValue, forKey: "targetID") } }
    var fallbackHost: String? { get { defaults.string(forKey: "fallbackHost") } set { defaults.set(newValue, forKey: "fallbackHost") } }
    var qualityMode: Int { get { defaults.object(forKey: "preset") as? Int ?? -1 } set { defaults.set(newValue, forKey: "preset") } }   // -1 = Auto
    var autoQ: Bool { qualityMode < 0 }
    var mirrorOn: Bool { get { defaults.bool(forKey: "mirror") } set { defaults.set(newValue, forKey: "mirror") } }
    var audioOn: Bool { get { defaults.object(forKey: "audio") as? Bool ?? true } set { defaults.set(newValue, forKey: "audio") } }
    var notifOn: Bool { get { defaults.object(forKey: "notif") as? Bool ?? true } set { defaults.set(newValue, forKey: "notif") } }

    func applicationDidFinishLaunching(_ n: Notification) {
        registerHotkey()
        item.button?.image = menuGlyph(filled: false)
        let m = NSMenu(); m.delegate = self; m.autoenablesItems = false; item.menu = m
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.endAll("Sleeping") }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "SWITCH", actions: [UNNotificationAction(identifier: "switch", title: "Switch now", options: [.foreground])], intentIdentifiers: [], options: [])])
        if notifOn { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        effIdx = autoQ ? 2 : qualityMode
        guide = Guide(app: self)
        ctlServer = ControlServer(self)
        settings = SettingsWindow(app: self)
        if CommandLine.arguments.contains("--settings") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settings?.show(Pane.allCases.first { p in CommandLine.arguments.contains("--pane=" + p.rawValue) }) } }
        if !defaults.bool(forKey: "onboarded") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.guide?.show() } }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.autoTick() }
        startBrowser()
        refreshIcon()
        tick()
    }

    // MARK: discovery
    func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_odisplay._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var f: [String: Found] = [:]
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                var id = name
                var pairing = false
                if case let .bonjour(txt) = r.metadata { if let v = txt.dictionary["id"] { id = v }; pairing = txt.dictionary["pair"] == "1" }
                f[id] = Found(id: id, name: name, endpoint: r.endpoint, ifaces: Array(r.interfaces), pairing: pairing)
            }
            DispatchQueue.main.async { dlog("tx browse: \(f.count) found"); if let s = self, Set(f.keys) != Set(s.found.keys) { s.badIface.removeAll() }; self?.found = f; self?.tick() }
        }
        b.stateUpdateHandler = { st in if case .failed = st { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startBrowser() } } }
        b.start(queue: .main)
        browser = b
    }

    // MARK: notifications
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([.banner]) }
    /// Global ⌃⌥⌘D: pause / resume streaming from the main Mac (works even if the extra screen's input misbehaves).
    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            let a = Unmanaged<SenderApp>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { a.toggleEnabled() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: OSType(0x41444850), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
    var versionWarned = Set<String>()
    func checkVersion(_ v: String) {
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        func mm(_ x: String) -> String { x.split(separator: ".").prefix(2).joined(separator: ".") }
        if v == "older" || mm(v) != mm(mine), versionWarned.insert(v).inserted {
            notify("Update the other Mac", "It runs AirDisplay \(v == "older" ? "(older version)" : v); this Mac runs \(mine). Copy the same app to both Macs.")
        }
    }
    func notify(_ title: String, _ body: String = "") {
        guard notifOn else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: quality
    /// `all`: a manual level chosen by the user applies to every receiver; auto steps only the receiver that struggled.
    func applyQuality(_ idx: Int, why: String?, all: Bool = false) {
        effIdx = idx; lastChange = Date(); badSecs = 0; goodSecs = 0
        session?.setPreset(presets[idx])
        if all { for (id, e) in extras { if let L = extraLadders[id] { L.idx = idx; L.lastChange = Date(); L.bad = 0; L.good = 0 }; e.setPreset(presets[idx]) } }
        if let w = why { notify("Display quality: \(presets[idx].short)", w) }
    }

    /// One second of the auto-quality loop for one receiver. `apply` changes its level.
    func stepLadder(_ s: Session, _ L: Ladder, apply: (Int, String) -> Void) {
        guard s.stream != nil else { L.bad = 0; L.good = 0; L.lastDropped = 0; return }
        guard autoQ else { return }
        let newDrops = s.dropped - L.lastDropped; L.lastDropped = s.dropped
        let slowDecode = s.fps > 20 && s.rxFps > 0 && s.rxFps < s.fps * 0.75
        let bad = newDrops >= 3 || s.rttMs > 30 || slowDecode
        let since = Date().timeIntervalSince(L.lastChange)
        let wired = s.linkType == "Ethernet" || s.linkType == "Thunderbolt"
        let minIdx = wired ? 0 : 1     // Ultra only on a wired link
        if L.idx < minIdx { apply(minIdx, "Left the wired link, lowered automatically."); return }
        if bad {
            L.bad += 1; L.good = 0
            if L.bad >= 3, L.idx < autoLadder - 1, since > 8 {
                L.blocked[L.idx] = Date().addingTimeInterval(300)
                apply(L.idx + 1, "Link or receiver struggling, lowered automatically.")
            }
        } else {
            L.good += 1; L.bad = 0
            if L.good >= 40, L.idx > minIdx, L.blocked[L.idx - 1] < Date(), since > 40 {
                apply(L.idx - 1, "Link stable, raised automatically.")
            }
        }
    }

    func autoTick() {
        for (id, e) in extras { if let L = extraLadders[id] { stepLadder(e, L) { idx, _ in L.idx = idx; L.lastChange = Date(); L.bad = 0; L.good = 0; e.setPreset(presets[idx]) } } }
        for (id, e) in extras { dlog("tx stat \(name(of: id)): \(e.linkType) \(e.preset.short) \(Int(e.fps)) fps drops=\(e.dropped) rtt=\(Int(e.rttMs))ms rx=\(Int(e.rxFps))") }
        if let p = session { dlog("tx stat primary \(p.receiverName): \(p.linkType) \(p.preset.short) \(Int(p.fps)) fps drops=\(p.dropped) rtt=\(Int(p.rttMs))ms rx=\(Int(p.rxFps))") }
        guard let s = session, s.stream != nil else { badSecs = 0; goodSecs = 0; lastDropped = 0; return }
        if lastLink == "Ethernet" && s.linkType == "Wi-Fi" { notify("Display fell back to Wi-Fi", "Expect more lag. Check the cable.") }
        if s.linkType != "…" && !s.linkType.isEmpty { lastLink = s.linkType }
        if let w = upgradeAvailable {
            if Date().timeIntervalSince(s.startedAt) < 20 { switchNow(); return }   // just connected, nothing to disrupt
            if !offeredSwitch { offeredSwitch = true; notifySwitch(w) }
        }
        stepLadder(s, L0) { idx, why in applyQuality(idx, why: why) }
    }

    // MARK: link selection
    func rank(_ i: NWInterface) -> Int {
        if i.name.hasPrefix("bridge") { return 0 }
        if i.type == .wiredEthernet { return 1 }
        if i.type == .wifi { return 2 }
        return 3
    }
    func rankOf(link: String) -> Int { link == "Thunderbolt" ? 0 : link == "Ethernet" ? 1 : link == "Wi-Fi" ? 2 : 3 }
    func candidates(_ f: Found) -> [NWInterface] {
        let now = Date()
        return f.ifaces.filter { i in
            if let u = badIface[i.name], u > now { return false }
            switch linkMode { case 1: return rank(i) <= 1; case 2: return rank(i) == 2; default: return true }
        }.sorted { rank($0) < rank($1) }
    }
    func bestRank(_ f: Found) -> Int? { candidates(f).first.map { rank($0) } }
    var upgradeAvailable: String? {
        guard linkMode == 0, let s = session, s.stream != nil, let t = targetID, let f = found[t],
              let b = bestRank(f), b < rankOf(link: s.linkType) else { return nil }
        return b == 0 ? "Thunderbolt" : "Ethernet"
    }
    func switchNow() { endAll("Restarting"); tick() }
    func notifySwitch(_ what: String) {
        guard notifOn else { return }
        let c = UNMutableNotificationContent(); c.title = "\(what) available"
        c.body = "You're on Wi-Fi. Click to switch for lower lag (reconnects in ~2 s)."; c.categoryIdentifier = "SWITCH"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler h: @escaping () -> Void) {
        if r.notification.request.content.categoryIdentifier == "SWITCH", r.actionIdentifier != UNNotificationDismissActionIdentifier {
            DispatchQueue.main.async { [weak self] in self?.switchNow() }
        }
        h()
    }
    @objc func pickLink(_ s: NSMenuItem) { linkMode = s.tag; endAll("Restarting"); status = "Looking for receiver…"; tick() }
    @objc func switchFromMenu() { switchNow() }

    // MARK: several receivers at once
    /// Extra screens used together with the primary one. Each gets its own virtual display and its own stream.
    var extraIDs: [String] { get { defaults.stringArray(forKey: "extraIDs") ?? [] } set { defaults.set(newValue, forKey: "extraIDs") } }
    var usedIDs: [String] { (targetID.map { [$0] } ?? []) + extraIDs.filter { $0 != targetID } }
    func name(of id: String) -> String { found[id]?.name ?? keys.peer(id: id)?.name ?? "receiver" }

    func endAll(_ reason: String?) { session?.end(reason); for s in Array(extras.values) { s.end(reason) } }

    func toggleUse(_ id: String) {
        if usedIDs.contains(id) {
            if id == targetID { targetID = extraIDs.first; extraIDs = Array(extraIDs.dropFirst()); session?.end("Restarting") }
            else { extraIDs = extraIDs.filter { $0 != id }; extras[id]?.end("Restarting") }
        } else if targetID == nil { targetID = id }
        else { extraIDs = extraIDs + [id] }
        status = "Looking for receiver…"; tick()
    }

    func tickExtras() {
        guard enabled else { return }
        for id in extraIDs where id != targetID && extras[id] == nil {
            guard keys.peer(id: id) != nil, let f = found[id] else { continue }
            let c = candidates(f)
            if c.isEmpty && !f.ifaces.isEmpty { continue }
            startExtra(id, f, iface: c.first)
        }
    }

    func startExtra(_ id: String, _ f: Found, iface: NWInterface?) {
        dlog("tx startExtra \(f.name) iface=\(iface?.name ?? "-")")
        let L = Ladder(); L.lastChange = Date()
        L.idx = (iface.map { rank($0) } ?? 2) <= 1 ? 0 : 2      // best level this receiver's own link allows
        extraLadders[id] = L
        let s = Session(endpoint: f.endpoint, keys: keys, name: myName, code: nil, preset: presets[autoQ ? L.idx : qualityMode], mirror: mirrorOn)
        s.onVersion = { [weak self] v in self?.checkVersion(v) }
        s.audioOn = false; s.forceIface = iface          // sound goes to the primary receiver only
        s.onLive = { [weak self, weak s] in
            self?.notify("Connected to \(s?.receiverName ?? f.name)", "Extra display · \(s?.preset.short ?? "")")
            self?.refreshIcon()
        }
        var wasLive = false
        s.onEnd = { [weak self, weak s] reason in
            guard let self = self, let s = s else { return }
            dlog("tx extra end \(f.name): \(reason ?? "nil") live=\(s.live)")
            if self.extras[id] === s { self.extras[id] = nil }
            if s.live { wasLive = true }
            if wasLive, reason != "Restarting", reason != "Sleeping" { self.notify("\(f.name) disconnected", reason ?? "Receiver went away") }
            if reason == "PERMISSION" { self.permissionProblem = true }
            self.refreshIcon()
        }
        extras[id] = s
        s.start()
    }

    // MARK: sessions
    func tick() { tickPrimary(); tickExtras(); considerPairing() }

    func tickPrimary() {
        guard enabled, session == nil else { return }
        var ep: NWEndpoint?
        var iface: NWInterface?
        if let t = targetID, let f = found[t] {
            let c = candidates(f)
            if c.isEmpty && !f.ifaces.isEmpty { status = linkMode == 1 ? "Waiting for wired link…" : linkMode == 2 ? "Waiting for Wi-Fi…" : "Looking for receiver…"; return }
            iface = c.first; ep = f.endpoint
        }
        else if targetID != nil, let h = fallbackHost, !h.isEmpty { ep = .hostPort(host: NWEndpoint.Host(h), port: 7777) }
        if ep == nil, let t = targetID { considerWake(t) } else { offlineSince = nil; wakeTries = 0 }
        guard let endpoint = ep else {
            if let t = targetID, let p = keys.peer(id: t), Date().timeIntervalSince(lastWake) < 30 { status = "Waking \(p.name)…" }
            else { status = keys.peers.isEmpty ? "No receiver paired yet" : "Looking for receiver…" }
            return
        }
        startSession(endpoint, code: nil, iface: iface)
    }

    func startSession(_ endpoint: NWEndpoint, code: String?, iface: NWInterface? = nil) {
        dlog("tx startSession \(endpoint) iface=\(iface?.name ?? "-")")
        var iface = iface
        if iface == nil, let f = found.values.first(where: { $0.endpoint == endpoint }) { iface = candidates(f).first }
        if autoQ {   // start at the best level the link allows; auto drops if it struggles
            effIdx = (iface.map { rank($0) } ?? 2) <= 1 ? 0 : 2
            blockedUntil = [Date](repeating: .distantPast, count: presets.count); badSecs = 0; goodSecs = 0; lastChange = Date()
        }
        let s = Session(endpoint: endpoint, keys: keys, name: myName, code: code, preset: presets[autoQ ? effIdx : qualityMode], mirror: mirrorOn)
        s.onVersion = { [weak self] v in self?.checkVersion(v) }
        s.onNumber = { [weak self, weak s] n, answer in self?.askNumber(s?.hs.peerName ?? "the other Mac", n, answer) }
        s.audioOn = audioOn; s.forceIface = iface
        s.onPaired = { [weak self] peer in
            if let me = self { if let t = me.targetID, t != peer.id, !me.extraIDs.contains(t) { me.extraIDs += [t] }; me.extraIDs.removeAll { $0 == peer.id }; me.targetID = peer.id }   // a newly paired Mac joins the ones already in use
            self?.notify("Paired with \(peer.name)", "Connecting…")
        }
        s.onLive = { [weak self, weak s] in
            guard let self = self else { return }
            self.status = "Streaming"; self.permissionProblem = false; self.wasLive = true; self.lastLink = ""; self.lastDropped = 0; self.offeredSwitch = false
            self.refreshIcon()
            self.notify("Connected to \(s?.receiverName ?? "receiver")", (self.mirrorOn ? "Mirroring · " : "Extended display · ") + (s?.preset.short ?? ""))
        }
        s.onEnd = { [weak self, weak s] reason in
            guard let self = self, let s = s else { return }
            dlog("tx session end: \(reason ?? "nil") live=\(s.live)")
            if self.session === s { self.session = nil }
            if !s.live, let i = s.forceIface, reason != "Restarting", reason != "Sleeping", reason != "PERMISSION", s.pairCode == nil, Date().timeIntervalSince(s.startedAt) >= 3 { self.badIface[i.name] = Date().addingTimeInterval(20) }
            if self.wasLive { self.wasLive = false; if reason != "Restarting" && reason != "Sleeping" { self.notify("Display disconnected", reason ?? "Receiver went away") } }
            if s.pairCode != nil && !s.hs.pairedNow, let r = reason, r != "Restarting", r != "Pairing cancelled" {
                self.alert("Pairing failed", r)
            }
            if reason == "PERMISSION" { self.permissionProblem = true; self.status = "Needs Screen Recording permission"; self.notify("Needs permission", "Allow Screen Recording in System Settings.") }
            else { self.status = self.enabled ? (reason ?? "Looking for receiver…") : "Paused" }
            self.refreshIcon()
        }
        session = s
        s.start()
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    func refreshIcon() {
        let on = session?.stream != nil
        if permissionProblem { item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Needs permission") }
        else { item.button?.image = menuGlyph(filled: on, slashed: !enabled) }
        item.button?.appearsDisabled = !enabled
    }

    // MARK: menu
    func styled(_ t: String, header: Bool) -> NSAttributedString {
        let f = header ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let r = NSMutableAttributedString(string: t, attributes: [.font: f, .foregroundColor: header ? NSColor.labelColor : NSColor.secondaryLabelColor])
        if header, t.hasPrefix("●") { r.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: NSRange(location: 0, length: 1)) }
        if header, t.hasPrefix("⚠︎") { r.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: 0, length: 2)) }
        return r
    }

    func statLines() -> [String] {
        guard let s = session, s.stream != nil else {
            if !enabled { return ["⏸  Paused"] }
            if permissionProblem { return ["⚠︎  Needs Screen Recording permission"] }
            return ["○  \(status)"]
        }
        let wifi = s.linkType == "Wi-Fi"
        let head = "●  \(s.receiverName) · \(s.linkType)" + (wifi ? "  ⚠︎ expect lag" : "")
        let idle = s.fps < 3.5
        let l2 = "\(s.capW)×\(s.capH) · " + (idle ? "idle, screen unchanged" : String(format: "%.0f fps · %.0f Mbps", s.fps, s.mbps))
        let l3 = String(format: "Latency %.1f ms", s.rttMs) + (s.dropped > 0 ? " · \(s.dropped) dropped" : "")
        return [head, l2, l3]
    }

    @discardableResult
    func act(_ menu: NSMenu, _ title: String, _ sel: Selector?, tag: Int = 0, on: Bool = false, rep: String? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; i.tag = tag
        i.state = on ? .on : .off; i.isEnabled = enabled; i.representedObject = rep; menu.addItem(i); return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        statItems = statLines().enumerated().map { (n, l) in
            let it = NSMenuItem(); it.attributedTitle = styled(l, header: n == 0); it.indentationLevel = n == 0 ? 0 : 1
            it.isEnabled = true; menu.addItem(it); return it
        }
        if permissionProblem { act(menu, "Open Screen Recording Settings…", #selector(openPrivacy)) }
        menu.addItem(.separator())
        let pm = act(menu, enabled ? "Pause Streaming" : "Resume Streaming", #selector(toggleEnabled)); pm.keyEquivalent = "d"; pm.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(.separator())

        // Receivers
        let r = NSMenu(); r.autoenablesItems = false
        let list = found.values.sorted { $0.name < $1.name }
        for f in list {
            let paired = keys.peer(id: f.id) != nil
            act(r, f.name + (paired ? "" : "  — pair…"), #selector(pickReceiver(_:)), on: usedIDs.contains(f.id), rep: f.id)
        }
        for p in keys.peers where found[p.id] == nil {
            act(r, "\(p.name) (offline)", #selector(pickReceiver(_:)), on: usedIDs.contains(p.id), rep: p.id)
        }
        if list.isEmpty && keys.peers.isEmpty { act(r, "No receivers found", nil, enabled: false) }
        r.addItem(.separator())
        act(r, "Pair by address…", #selector(pairByAddress))
        let tname = usedIDs.isEmpty ? "none" : usedIDs.map { name(of: $0) }.joined(separator: ", ")
        let ri = NSMenuItem(title: usedIDs.count > 1 ? "Receivers: \(tname)" : "Receiver: \(tname)", action: nil, keyEquivalent: ""); ri.submenu = r; ri.isEnabled = true; menu.addItem(ri)

        if let t = targetID, found[t] == nil, canWake(t), session == nil, let p = keys.peer(id: t) { act(menu, "Wake \(p.name)", #selector(wakeFromMenu)) }
        let live = session?.stream != nil
        let q = NSMenu(); q.autoenablesItems = false
        act(q, "Auto" + (autoQ && live ? " · now \(presets[effIdx].short)" : "") + "  (recommended)", #selector(pickQuality(_:)), tag: -1, on: autoQ)
        q.addItem(.separator())
        for (i, p) in presets.enumerated() { if i == autoLadder { q.addItem(.separator()) }; act(q, p.name, #selector(pickQuality(_:)), tag: i, on: qualityMode == i) }
        let qi = NSMenuItem(title: "Quality: " + (autoQ ? (live ? "Auto · \(presets[effIdx].short)" : "Auto") : presets[qualityMode].short), action: nil, keyEquivalent: ""); qi.submenu = q; qi.isEnabled = true; menu.addItem(qi)

        if let up = upgradeAvailable { act(menu, "⚡ Switch to \(up) now", #selector(switchFromMenu)) }
        let lk = NSMenu(); lk.autoenablesItems = false
        act(lk, "Auto: best available  (recommended)", #selector(pickLink(_:)), tag: 0, on: linkMode == 0)
        act(lk, "Wired only (Ethernet / Thunderbolt)", #selector(pickLink(_:)), tag: 1, on: linkMode == 1)
        act(lk, "Wi-Fi only", #selector(pickLink(_:)), tag: 2, on: linkMode == 2)
        let lnk = NSMenuItem(title: "Connection: " + ["Auto", "Wired only", "Wi-Fi only"][min(max(linkMode, 0), 2)], action: nil, keyEquivalent: ""); lnk.submenu = lk; lnk.isEnabled = true; menu.addItem(lnk)

        let d = NSMenu(); d.autoenablesItems = false
        act(d, "Extended display (extra screen)", #selector(pickDisplay(_:)), tag: 0, on: !mirrorOn)
        act(d, "Mirror this Mac's screen", #selector(pickDisplay(_:)), tag: 1, on: mirrorOn)
        let di = NSMenuItem(title: "Display: " + (mirrorOn ? "Mirror" : "Extended"), action: nil, keyEquivalent: ""); di.submenu = d; di.isEnabled = true; menu.addItem(di)

        menu.addItem(.separator())
        let rm = NSMenuItem(title: "Change role…", action: #selector(changeRole), keyEquivalent: ""); rm.target = self; rm.isEnabled = true; menu.addItem(rm)
        let sm = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); sm.target = self; sm.isEnabled = true; menu.addItem(sm)
        menu.addItem(.separator())
        let qt = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); qt.isEnabled = true; menu.addItem(qt)
    }

    func menuWillOpen(_ menu: NSMenu) {
        liveTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let l = self.statLines()
            if l.count == self.statItems.count { for (i, x) in l.enumerated() { self.statItems[i].attributedTitle = self.styled(x, header: i == 0) } }
        }
        RunLoop.main.add(t, forMode: .common); liveTimer = t
    }
    func menuDidClose(_ menu: NSMenu) { liveTimer?.invalidate(); liveTimer = nil }

    // MARK: wake on LAN
    func canWake(_ id: String) -> Bool { !(keys.peer(id: id)?.macs ?? []).isEmpty }
    func considerWake(_ id: String) {
        guard autoWake, canWake(id), let p = keys.peer(id: id) else { return }
        if offlineSince == nil { offlineSince = Date() }
        guard let since = offlineSince, Date().timeIntervalSince(since) > 5, wakeTries < 4, Date().timeIntervalSince(lastWake) > 12 else { return }
        wake(p, auto: true)
    }
    func wake(_ p: Peer, auto: Bool) {
        let n = sendMagicPackets(p.macs ?? [])
        lastWake = Date(); if auto { wakeTries += 1 }
        if n > 0 { status = "Waking \(p.name)…"; if !auto || wakeTries == 1 { notify("Waking \(p.name)", "Wake signal sent. The display connects as soon as it is up.") } }
        else if !auto { alert("Can't wake \(p.name)", "No wake address is known yet, or no network link is up. Connect once so the address can be learned.") }
    }
    func wakeReceiver(_ id: String) { if let p = keys.peer(id: id) { wakeTries = 0; wake(p, auto: false) } }
    @objc func wakeFromMenu() { if let t = targetID { wakeReceiver(t) } }

    // MARK: settings window support
    @objc func changeRole() { switchRole(to: .receiver) }
    @objc func showSettings() { settings?.show() }
    func startUITimer() {
        uiTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshLive() }
        RunLoop.main.add(t, forMode: .common); uiTimer = t
        refreshLive()
    }
    func stopUITimer() { uiTimer?.invalidate(); uiTimer = nil }
    func refreshLive() {
        let s = session; let on = s?.stream != nil
        live.connected = on; live.status = status
        var rows: [RecvRow] = []
        for f in found.values.sorted(by: { $0.name < $1.name }) { rows.append(RecvRow(id: f.id, name: f.name, paired: keys.peer(id: f.id) != nil, online: true, selected: usedIDs.contains(f.id), canWake: false)) }
        for p in keys.peers where found[p.id] == nil { rows.append(RecvRow(id: p.id, name: p.name, paired: true, online: false, selected: usedIDs.contains(p.id), canWake: !(p.macs ?? []).isEmpty)) }
        live.rows = rows
        guard let s = s, on else { if !live.fpsH.isEmpty { live.clearHistory() }; return }
        live.receiver = s.receiverName; live.link = s.linkType; live.iface = s.iface
        live.size = "\(s.capW)×\(s.capH)"
        live.looksLike = s.pointW > 0 ? "\(s.pointW)×\(s.pointH)" + (s.pointW < s.backW ? " @2x" : "") : "—"
        live.encoder = s.encInfo
        live.quality = autoQ ? "Auto · \(presets[effIdx].short)" : presets[qualityMode].short
        live.fps = s.fps; live.target = effFps(s.capW, s.capH, s.preset.fps, hevc: s.hevc); live.mbps = s.mbps; live.rtt = s.rttMs; live.rxFps = s.rxFps
        live.gb = Double(s.bytes) / 1e9; live.dropped = s.dropped
        let secs = Int(Date().timeIntervalSince(s.startedAt))
        live.uptime = String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        live.push(fps: s.fps, mbps: s.mbps, rtt: s.rttMs)
    }
    func setLinkMode(_ v: Int) { linkMode = v; endAll("Restarting"); status = "Looking for receiver…"; tick() }
    func reencode() { if let s = session { s.setPreset(s.preset, force: true) }; for e in extras.values { e.setPreset(e.preset, force: true) } }
    func restartSession() { endAll("Restarting"); status = "Looking for receiver…"; tick() }
    func selectReceiver(_ id: String) { targetID = id; endAll("Restarting"); tick() }
    func pairReceiver(_ id: String) { if let f = found[id] { offerPair(f, userAsked: true) } }
    func forgetReceiver(_ id: String) {
        keys.forget(id: id); extraIDs = extraIDs.filter { $0 != id }; extras[id]?.end("Restarting")
        if targetID == id { targetID = extraIDs.first; extraIDs = Array(extraIDs.dropFirst()); session?.end("Restarting") }
    }
    func diagnostics() -> String {
        var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
        var m = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.model", &m, &size, nil, 0)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var l = ["AirDisplay \(v)", "Mac: \(String(cString: m))", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                 "Status: \(status)", "Quality: \(autoQ ? "Auto" : presets[qualityMode].name)", "Link mode: \(["Auto", "Wired only", "Wi-Fi only"][min(max(linkMode, 0), 2)])",
                 "Resolution mode: \(defaults.string(forKey: "resMode") ?? "match")", "Retina: \(defaults.string(forKey: "hidpi") ?? "auto")",
                 "FPS cap: \(defaults.integer(forKey: "fpsCap"))", "Color: \(defaults.string(forKey: "colorProfile") ?? "auto")", "Paired receivers: \(keys.peers.count)"]
        if let s = session, s.stream != nil {
            l.append("Receiver: \(s.receiverName) via \(s.linkType) \(s.iface)")
            l.append(String(format: "Stream: %dx%d %@ · %.0f fps · %.1f Mbps · %.1f ms · %d dropped", s.capW, s.capH, s.encInfo, s.fps, s.mbps, s.rttMs, s.dropped))
        }
        return l.joined(separator: "\n")
    }
    func resetSettings() {
        let a = NSAlert(); a.messageText = "Reset all settings?"
        a.informativeText = "Quality, display, connection and color options go back to defaults. Paired receivers are kept."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            let keep = targetID
            if let b = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: b) }
            defaults.set(true, forKey: "onboarded"); targetID = keep
            effIdx = 2; endAll("Restarting"); settings?.win?.close(); settings = SettingsWindow(app: self)
        }
    }

    // MARK: actions
    @objc func toggleEnabled() { setEnabled(!enabled) }
    func setEnabled(_ on: Bool) {
        enabled = on
        if on { status = "Looking for receiver…"; tick() } else { endAll(nil); status = "Paused" }
        refreshIcon()
    }
    @objc func pickQuality(_ s: NSMenuItem) { setQuality(s.tag) }
    func setQuality(_ v: Int) {
        qualityMode = v
        if v >= 0 { applyQuality(v, why: nil, all: true) }
        else { applyQuality(effIdx, why: nil); for (id, e) in extras { e.setPreset(presets[extraLadders[id]?.idx ?? 1]) } }
    }
    @objc func pickDisplay(_ s: NSMenuItem) {
        let m = s.tag == 1
        if m != mirrorOn { mirrorOn = m; endAll("Restarting") }
    }
    @objc func toggleAudio() { audioOn.toggle(); session?.audioOn = audioOn }
    @objc func toggleNotif() {
        notifOn.toggle()
        if notifOn { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }
    @objc func pickReceiver(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        if keys.peer(id: id) != nil {
            toggleUse(id)
        } else if let f = found[id] {
            offerPair(f, userAsked: true)
        }
    }
    // MARK: pairing (first time): receiver says "ready to pair" -> we offer -> both Macs show the same number
    var pairPromptOpen = false
    var pairDismissed: [String: Date] = [:]

    /// A receiver that is waiting to be paired shows up on its own: offer to pair, no menu digging.
    func considerPairing() {
        guard !pairPromptOpen, session?.pairCode == nil else { return }
        for f in found.values.sorted(by: { $0.name < $1.name }) where f.pairing && keys.peer(id: f.id) == nil {
            if let d = pairDismissed[f.id], Date().timeIntervalSince(d) < 120 { continue }
            offerPair(f, userAsked: false); return
        }
    }

    func offerPair(_ f: Found, userAsked: Bool) {
        pairPromptOpen = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let a = NSAlert(); a.messageText = "Pair with \(f.name)?"
            a.informativeText = userAsked ? "Make sure AirDisplay is open on \(f.name) and set to “Be the extra screen”." : "\(f.name) is waiting to be paired. Click Pair, then check that both Macs show the same number."
            a.addButton(withTitle: "Pair"); a.addButton(withTitle: "Not now")
            NSApp.activate(ignoringOtherApps: true)
            let go = a.runModal() == .alertFirstButtonReturn
            self.pairPromptOpen = false
            if go { self.session?.end("Restarting"); self.startSession(f.endpoint, code: "pair") }
            else { self.pairDismissed[f.id] = Date() }
        }
    }

    func askNumber(_ name: String, _ number: String, _ answer: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = "Check the number on \(name)"
        a.informativeText = "\(name) should show exactly this number. If it matches, click Pair on both Macs."
        let n = NSTextField(labelWithString: number); n.font = .monospacedSystemFont(ofSize: 44, weight: .semibold); n.alignment = .center
        n.frame = NSRect(x: 0, y: 0, width: 260, height: 56); a.accessoryView = n
        a.addButton(withTitle: "Pair"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        answer(a.runModal() == .alertFirstButtonReturn)
    }

    @objc func pairByAddress() {
        let a = NSAlert(); a.messageText = "Pair by address"
        a.informativeText = "Use if the other Mac isn't listed. Enter its IP address. It must be open in “Be the extra screen” mode and ready to pair."
        let h = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); h.placeholderString = "IP address, e.g. 10.0.0.2"
        a.accessoryView = h
        a.addButton(withTitle: "Pair"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, !h.stringValue.isEmpty {
            fallbackHost = h.stringValue.trimmingCharacters(in: .whitespaces)
            session?.end("Restarting")
            startSession(.hostPort(host: NWEndpoint.Host(fallbackHost!), port: 7777), code: "pair")
        }
    }
    @objc func forgetAll() {
        let a = NSAlert(); a.messageText = "Forget all paired receivers?"
        a.informativeText = "You'll need to pair them again."
        a.addButton(withTitle: "Forget"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { keys.forgetAll(); targetID = nil; extraIDs = []; endAll("Restarting") }
    }
    @objc func showGuide() { guide?.show() }
    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } } catch { print(error) }
    }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
