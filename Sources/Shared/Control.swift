import Foundation

/// Agent / script control. The running app listens on a private Unix socket (off by default, Settings › General);
/// `AirDisplay --mcp` is a stdio MCP server that forwards tool calls to it, `AirDisplay --ctl <command> [json]` is a plain CLI.
enum Ctl {
    static var dir: String { NSHomeDirectory() + "/Library/Application Support/AirDisplay" }
    static var sockPath: String { dir + "/control.sock" }

    static func unixAddr(_ path: String) -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &a.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, path, 103) } }
        return a
    }

    static func writeAll(_ fd: Int32, _ d: Data) {
        var off = 0
        d.withUnsafeBytes { p in
            while off < d.count { let n = write(fd, p.baseAddress! + off, d.count - off); if n <= 0 { break }; off += n }
        }
    }

    static func readLine(_ fd: Int32) -> Data? {
        var buf = Data(), tmp = [UInt8](repeating: 0, count: 8192)
        while buf.count < 4_000_000 {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.last == 10 { break }
        }
        return buf.isEmpty ? nil : buf
    }

    /// One request/response round trip to the running app.
    static func call(_ cmd: String, _ args: [String: Any] = [:]) -> [String: Any] {
        let off = "AirDisplay is not running here, or “Allow AI agents & scripts” is off (AirDisplay › Settings › General). Only the main-Mac role can be controlled."
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return ["ok": false, "error": "socket failed"] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = unixAddr(sockPath)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { return ["ok": false, "error": off] }
        var req = args; req["cmd"] = cmd
        guard var data = try? JSONSerialization.data(withJSONObject: req) else { return ["ok": false, "error": "bad arguments"] }
        data.append(10)
        writeAll(fd, data)
        guard let resp = readLine(fd), let j = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else { return ["ok": false, "error": "no answer from AirDisplay"] }
        return j
    }
}

// MARK: MCP (stdio, newline-delimited JSON-RPC 2.0)

private struct Tool {
    let name: String, text: String, props: [String: Any], required: [String], readOnly: Bool
}

private let tools: [Tool] = [
    Tool(name: "get_status", text: "Current state of the display stream: paused or not, quality mode, and for each connected receiver its link (Wi-Fi/Ethernet/Thunderbolt), resolution, fps, bitrate, latency, dropped frames and codec.", props: [:], required: [], readOnly: true),
    Tool(name: "list_receivers", text: "Receivers (Macs used as an extra screen) that are paired or visible on the network: id, name, online, paired, in use.", props: [:], required: [], readOnly: true),
    Tool(name: "use_receiver", text: "Start using a paired receiver as an extra screen. role \"primary\" (default) makes it the main receiver (audio, quality ladder); \"extra\" adds it alongside the current ones. Pairing a new Mac is not possible here: the person must confirm the 6-digit number on both Macs.", props: ["receiver": ["type": "string", "description": "Receiver name (partial, case-insensitive) or id"], "role": ["type": "string", "enum": ["primary", "extra"]]], required: ["receiver"], readOnly: false),
    Tool(name: "stop_using_receiver", text: "Stop sending to a receiver (its virtual display is removed).", props: ["receiver": ["type": "string", "description": "Receiver name (partial) or id"]], required: ["receiver"], readOnly: false),
    Tool(name: "pause_streaming", text: "Pause all streaming. Nothing is captured or sent; virtual displays are removed.", props: [:], required: [], readOnly: false),
    Tool(name: "resume_streaming", text: "Resume streaming to the chosen receivers.", props: [:], required: [], readOnly: false),
    Tool(name: "set_quality", text: "Set stream quality. auto adapts to the link; the rest are fixed. ultra and 4k60 need a wired link.", props: ["mode": ["type": "string", "enum": ["auto", "ultra", "best", "balanced", "light", "4k60"]]], required: ["mode"], readOnly: false),
    Tool(name: "set_link", text: "Which network link to prefer. auto picks the best, wired uses Thunderbolt/Ethernet only, wifi uses Wi-Fi only. The stream restarts.", props: ["mode": ["type": "string", "enum": ["auto", "wired", "wifi"]]], required: ["mode"], readOnly: false),
    Tool(name: "restart_stream", text: "End and re-establish all sessions. Use after changing cables or when the picture looks stuck.", props: [:], required: [], readOnly: false),
    Tool(name: "diagnose", text: "Structured health report: versions, permissions, duplicate app copies, receivers, sessions, network route and internet reachability, recent events, and a list of findings with severity and a suggested fix. Call this first when the user reports lag, glitches or no connection.", props: [:], required: [], readOnly: true),
]

private func reply(_ id: Any?, result: Any? = nil, error: (Int, String)? = nil) {
    var m: [String: Any] = ["jsonrpc": "2.0"]
    if let id = id { m["id"] = id }
    if let e = error { m["error"] = ["code": e.0, "message": e.1] } else { m["result"] = result ?? [String: Any]() }
    guard var d = try? JSONSerialization.data(withJSONObject: m) else { return }
    d.append(10); FileHandle.standardOutput.write(d)
}

func runMCP() {
    let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    while let line = Swift.readLine(strippingNewline: true) {
        guard !line.isEmpty, let m = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        let id = m["id"], method = m["method"] as? String ?? ""
        if id == nil { continue }   // notifications need no answer
        switch method {
        case "initialize":
            let want = (m["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, result: ["protocolVersion": want, "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "airdisplay", "version": ver],
                               "instructions": "Controls the AirDisplay app on this Mac (the main Mac that sends its desktop to a receiver Mac). Start with diagnose when something is wrong."] as [String: Any])
        case "ping": reply(id, result: [String: Any]())
        case "tools/list":
            let list: [[String: Any]] = tools.map { t in
                ["name": t.name, "description": t.text,
                 "inputSchema": ["type": "object", "properties": t.props, "required": t.required] as [String: Any],
                 "annotations": ["readOnlyHint": t.readOnly, "destructiveHint": false, "openWorldHint": false] as [String: Any]]
            }
            reply(id, result: ["tools": list])
        case "tools/call":
            let p = m["params"] as? [String: Any] ?? [:]
            let name = p["name"] as? String ?? ""
            guard tools.contains(where: { $0.name == name }) else { reply(id, error: (-32602, "unknown tool \(name)")); continue }
            let r = Ctl.call(name, p["arguments"] as? [String: Any] ?? [:])
            let ok = r["ok"] as? Bool ?? false
            var body = r; body["ok"] = nil
            let obj: Any = ok ? body : (body["error"] ?? "error")
            let text = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "error"
            reply(id, result: ["content": [["type": "text", "text": text]], "isError": !ok] as [String: Any])
        default: reply(id, error: (-32601, "method not found"))
        }
    }
}

/// `AirDisplay --ctl status` etc. for scripts and testing.
func runCtl(_ args: [String]) {
    guard let cmd = args.first else { print("usage: --ctl <command> [json-arguments]"); return }
    var a: [String: Any] = [:]
    if args.count > 1, let d = args[1].data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { a = j }
    let r = Ctl.call(cmd, a)
    if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { print(String(data: d, encoding: .utf8) ?? "") }
}
