import Cocoa
import Network
import SwiftUI
import Darwin

/// What agents and scripts did, newest first. In memory only (gone when the app quits) and shown in Settings › General.
struct AgentEvent: Identifiable { let id = UUID(); let time: Date; let client: String; let action: String; let ok: Bool; let note: String }
@available(macOS 13.0, *) final class AgentLog: ObservableObject {
    static let shared = AgentLog()
    @Published var events: [AgentEvent] = []
    func add(_ e: AgentEvent) { events.insert(e, at: 0); if events.count > 100 { events.removeLast(events.count - 100) } }
    func clear() { events = [] }
}

/// Name of the program on the other end of the socket. The `--mcp` bridge is a copy of this app, so for it report the program that launched it.
func peerName(_ fd: Int32) -> String {
    var pid: pid_t = 0; var len = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return "unknown" }
    func name(_ p: pid_t) -> String { var b = [CChar](repeating: 0, count: 256); proc_name(p, &b, 255); return String(cString: b) }
    func parent(_ p: pid_t) -> pid_t { var i = proc_bsdinfo(); return proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &i, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 ? pid_t(i.pbi_ppid) : 0 }
    let n = name(pid)
    if pid == getpid() { return n }
    if n == (Bundle.main.executableURL?.lastPathComponent ?? "") { let pp = parent(pid); if pp > 1 { let pn = name(pp); return pn.isEmpty ? n : pn } }
    return n.isEmpty ? "pid \(pid)" : n
}

/// Local control socket for AI agents and scripts. Off unless the person turns it on (Settings › General).
/// Unix socket in the user's Application Support folder, mode 0600, peer UID checked: only this user's processes can talk to it.
/// Deliberately NOT exposed: pairing (needs the human to compare the 6-digit number), input forwarding, role switching, reset.
@available(macOS 13.0, *) final class ControlServer {
    unowned let app: SenderApp
    var fd: Int32 = -1
    var src: DispatchSourceRead?
    let q = DispatchQueue(label: "control", qos: .utility)
    static var allowed: Bool { UserDefaults.standard.bool(forKey: "agentControl") }

    init(_ a: SenderApp) {
        app = a
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.sync() }
        sync()
    }

    func sync() { if Self.allowed { start() } else { stop() } }

    func start() {
        guard fd < 0 else { return }
        try? FileManager.default.createDirectory(atPath: Ctl.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(Ctl.sockPath)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = Ctl.unixAddr(Ctl.sockPath)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(s); dlog("control: bind failed \(errno)"); return }
        chmod(Ctl.sockPath, 0o600)
        listen(s, 4)
        fd = s
        let d = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        d.setEventHandler { [weak self] in
            let c = accept(s, nil, nil)
            if c >= 0 { self?.handle(c) }
        }
        d.resume(); src = d
        dlog("control: listening")
    }

    func stop() {
        guard fd >= 0 else { return }
        src?.cancel(); src = nil
        close(fd); fd = -1
        unlink(Ctl.sockPath)
        dlog("control: stopped")
    }

    func handle(_ c: Int32) {
        defer { close(c) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == geteuid() else { return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard let line = Ctl.readLine(c), let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let cmd = req["cmd"] as? String else {
            Ctl.writeAll(c, Data("{\"ok\":false,\"error\":\"bad request\"}\n".utf8)); return
        }
        let client = peerName(c)
        let net: [String: Any] = cmd == "diagnose" ? ControlServer.networkSnapshot() : [:]   // slow shell calls stay off the main thread
        var out: [String: Any] = [:]
        DispatchQueue.main.sync { out = self.app.control(cmd, req, net) }
        let okv = out["ok"] as? Bool ?? false
        dlog("control: \(cmd) → \(okv)")
        let args = req.filter { $0.key != "cmd" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let note = String(((out["error"] ?? out["result"]) as? String ?? "").prefix(80))
        let ev = AgentEvent(time: Date(), client: client, action: cmd + (args.isEmpty ? "" : " " + args), ok: okv, note: note)
        DispatchQueue.main.async { AgentLog.shared.add(ev) }
        var d = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{\"ok\":false}".utf8)
        d.append(10)
        Ctl.writeAll(c, d)
    }

    // MARK: network facts for diagnose
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let t = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: t)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); t.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func networkSnapshot() -> [String: Any] {
        var r: [String: Any] = [:]
        let route = run("/sbin/route", ["-n", "get", "default"]).1
        for l in route.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") { r["defaultInterface"] = t.dropFirst(10).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("gateway:") { r["defaultGateway"] = t.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        }
        let order = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).1
        var svc: [String] = []
        for l in order.split(separator: "\n") {
            let t = String(l)
            if t.hasPrefix("(Hardware Port:") { svc.append(t.replacingOccurrences(of: "(Hardware Port: ", with: "").replacingOccurrences(of: ", Device: ", with: " ").replacingOccurrences(of: ")", with: "")) }
        }
        r["serviceOrder"] = svc
        r["internetReachable"] = run("/sbin/ping", ["-c", "1", "-t", "2", "1.1.1.1"]).0 == 0
        return r
    }
}

@available(macOS 13.0, *) extension SenderApp {
    func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    func sessionDict(_ s: Session, id: String?) -> [String: Any] {
        ["receiver": s.receiverName, "id": id ?? "", "link": s.linkType, "interface": s.iface, "resolution": "\(s.capW)x\(s.capH)",
         "fps": r1(s.fps), "mbps": r1(s.mbps), "latencyMs": r1(s.rttMs), "captureEncodeMs": r1(s.pipeMs), "captureWaitMs": r1(s.ageMs), "encodeMs": r1(s.encMs), "dropped": s.dropped, "codec": s.encInfo,
         "uptimeSec": Int(Date().timeIntervalSince(s.startedAt)), "idle": s.fps < 3.5]
    }

    var qualityName: String { autoQ ? "auto (now \(presets[effIdx].short))" : presets[qualityMode].short }

    func statusDict() -> [String: Any] {
        var d: [String: Any] = ["streamingEnabled": enabled, "status": status, "quality": qualityName,
                                "linkMode": ["auto", "wired", "wifi"][min(max(linkMode, 0), 2)]]
        if permissionProblem { d["problem"] = "Screen Recording permission missing" }
        var live: [[String: Any]] = []
        if let s = session, s.stream != nil { live.append(sessionDict(s, id: targetID)) }
        for (id, e) in extras where e.stream != nil { live.append(sessionDict(e, id: id)) }
        d["sessions"] = live
        return d
    }

    func receiverRows() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var seen = Set<String>()
        for f in found.values.sorted(by: { $0.name < $1.name }) {
            seen.insert(f.id)
            rows.append(["id": f.id, "name": f.name, "online": true, "paired": keys.peer(id: f.id) != nil, "inUse": usedIDs.contains(f.id), "primary": f.id == targetID, "pairingOpen": f.pairing])
        }
        for p in keys.peers where !seen.contains(p.id) {
            rows.append(["id": p.id, "name": p.name, "online": false, "paired": true, "inUse": usedIDs.contains(p.id), "primary": p.id == targetID])
        }
        return rows
    }

    /// Name (partial, case-insensitive) or id → receiver id, or an error string.
    func resolve(_ q: String?) -> (String?, String?) {
        guard let q = q?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return (nil, "receiver is required") }
        let rows = receiverRows()
        if let r = rows.first(where: { ($0["id"] as? String) == q }) { return (r["id"] as? String, nil) }
        let m = rows.filter { ($0["name"] as? String ?? "").lowercased().contains(q.lowercased()) }
        if m.count == 1 { return (m[0]["id"] as? String, nil) }
        let names = rows.compactMap { $0["name"] as? String }.joined(separator: ", ")
        return (nil, m.isEmpty ? "no receiver matches “\(q)”. Known: \(names.isEmpty ? "none" : names)" : "“\(q)” is ambiguous. Use the id.")
    }

    func control(_ cmd: String, _ a: [String: Any], _ net: [String: Any]) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        switch cmd {
        case "get_status":
            var d = statusDict(); d["ok"] = true; return d
        case "list_receivers":
            return ["ok": true, "receivers": receiverRows()]
        case "use_receiver":
            let (id, err) = resolve(a["receiver"] as? String)
            guard let id = id else { return fail(err ?? "unknown receiver") }
            guard keys.peer(id: id) != nil else { return fail("\(name(of: id)) is not paired yet. Pairing needs the person: choose it in the OpenAirDisplay menu and confirm the 6-digit number on both Macs.") }
            let extra = (a["role"] as? String) == "extra"
            var note = ""
            if extra {
                if usedIDs.contains(id) { note = "already in use" } else { toggleUse(id); note = "added as extra screen" }
            } else {
                extraIDs = extraIDs.filter { $0 != id }
                if targetID == id && session != nil { note = "already the main receiver" } else { selectReceiver(id); note = "now the main receiver" }
            }
            if !enabled { note += "; streaming is paused (call resume_streaming)" }
            return ["ok": true, "result": "\(name(of: id)): \(note)"]
        case "stop_using_receiver":
            let (id, err) = resolve(a["receiver"] as? String)
            guard let id = id else { return fail(err ?? "unknown receiver") }
            guard usedIDs.contains(id) else { return fail("\(name(of: id)) is not in use") }
            toggleUse(id)
            return ["ok": true, "result": "stopped using \(name(of: id))"]
        case "pause_streaming": setEnabled(false); return ["ok": true, "result": "paused"]
        case "resume_streaming": setEnabled(true); return ["ok": true, "result": "resuming"]
        case "set_quality":
            let modes = ["auto": -1, "ultra": 0, "best": 1, "balanced": 2, "light": 3, "4k60": 4]
            guard let m = a["mode"] as? String, let v = modes[m] else { return fail("mode must be one of: auto, ultra, best, balanced, light, 4k60") }
            setQuality(v)
            return ["ok": true, "result": "quality: \(qualityName)"]
        case "set_link":
            let modes = ["auto": 0, "wired": 1, "wifi": 2]
            guard let m = a["mode"] as? String, let v = modes[m] else { return fail("mode must be one of: auto, wired, wifi") }
            setLinkMode(v)
            return ["ok": true, "result": "link mode: \(m); restarting the stream"]
        case "restart_stream": restartSession(); return ["ok": true, "result": "restarting"]
        case "diagnose": return diagnoseReport(net)
        default: return fail("unknown command \(cmd)")
        }
    }

    // MARK: diagnose
    func diagnoseReport(_ net: [String: Any]) -> [String: Any] {
        var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
        var m = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.model", &m, &size, nil, 0)
        let info = Bundle.main.infoDictionary
        let ver = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let copies = Bundle.main.bundleIdentifier.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).filter { !$0.isTerminated }.count } ?? 1
        let rows = receiverRows()
        var findings: [[String: String]] = []
        func add(_ sev: String, _ issue: String, _ fix: String) { findings.append(["severity": sev, "issue": issue, "suggestedFix": fix]) }

        if permissionProblem { add("error", "Screen Recording permission is missing, so nothing can be captured.", "System Settings › Privacy & Security › Screen Recording: turn OpenAirDisplay on, then restart the app.") }
        if copies > 1 { add("error", "\(copies) copies of OpenAirDisplay are running. They fight over the same receiver (connect, kick off, repeat).", "Quit all copies, then open one.") }
        if !enabled { add("info", "Streaming is paused.", "resume_streaming") }
        if keys.peers.isEmpty { add("warn", "No receiver is paired.", "On the other Mac choose “Extra screen” and pair it from this Mac's menu (the person must confirm the 6-digit number).") }
        if enabled, let t = targetID, found[t] == nil, session?.stream == nil {
            add("warn", "\(name(of: t)) is not visible on the network.", "Check that it is awake, its OpenAirDisplay app is open in extra-screen role, and both Macs share the network or a cable. Wake-on-LAN is tried automatically for wired receivers.")
        }
        if enabled { for id in extraIDs where found[id] == nil && extras[id]?.stream == nil { add("warn", "\(name(of: id)) (extra screen) is not visible on the network.", "Check it is awake with its OpenAirDisplay app in extra-screen role, and that the cable or Wi-Fi is connected.") } }
        var sessions: [[String: Any]] = []
        if let s = session, s.stream != nil { sessions.append(sessionDict(s, id: targetID)) }
        for (id, e) in extras where e.stream != nil { sessions.append(sessionDict(e, id: id)) }
        for s in sessions {
            let n = s["receiver"] as? String ?? "receiver", link = s["link"] as? String ?? "", fps = s["fps"] as? Double ?? 0, rtt = s["latencyMs"] as? Double ?? 0
            let dropped = s["dropped"] as? Int ?? 0, idle = s["idle"] as? Bool ?? false
            if link == "Wi-Fi" { add("warn", "\(n) streams over Wi-Fi, which adds lag and stutter at high resolution.", "Connect a Thunderbolt or Ethernet cable; the app switches automatically, or use set_link wired.") }
            if rtt > 25 { add("warn", "\(n): latency \(rtt) ms is high.", "Move closer to the router or use a cable; lower quality with set_quality light.") }
            if dropped > 0 { add("warn", "\(n): \(dropped) frames dropped.", "Link cannot keep up; use auto quality or a cable.") }
            if !idle && fps > 0 && fps < 20 { add("warn", "\(n): only \(fps) fps while the screen is changing.", "Lower the quality or switch to a wired link.") }
        }
        if let up = upgradeAvailable { add("info", "A better link is available: \(up).", "restart_stream moves to it.") }
        if defaults.object(forKey: "acceptInput") as? Bool ?? true, !Injector.trusted { add("info", "Accessibility permission is off, so keyboard and mouse from the extra screen cannot be used.", "System Settings › Privacy & Security › Accessibility: turn OpenAirDisplay on.") }
        if net["internetReachable"] as? Bool == false { add("warn", "This Mac cannot reach the internet. If it is also an Ethernet-linked pair, a link-only adapter may have become the default route.", "Check the Mac's network service order and that the direct cable network has no router set.") }
        let log = recentLog(80)
        let failures = log.filter { $0.contains("failed") || $0.contains("closed the connection") }.count
        if failures >= 4 { add("warn", "\(failures) recent connection failures in the event log.", "Look at recentEvents; common causes are the receiver asleep, duplicate app copies, or a cable/network change.") }
        if findings.isEmpty { add("ok", "No problems found.", "") }

        var d: [String: Any] = ["ok": true, "app": ver, "bundle": Bundle.main.bundleIdentifier ?? "", "mac": String(cString: m),
                                "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "role": "sender", "copiesRunning": copies,
                                "accessibilityTrusted": Injector.trusted, "screenRecordingProblem": permissionProblem]
        d["state"] = statusDict()
        d["receivers"] = rows
        d["sessions"] = sessions
        d["network"] = net
        d["findings"] = findings
        d["recentEvents"] = Array(log.suffix(40))
        return d
    }
}
