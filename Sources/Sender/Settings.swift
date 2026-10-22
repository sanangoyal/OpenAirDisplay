import SwiftUI
import Charts
import ServiceManagement
import UserNotifications

@available(macOS 13.0, *) struct RecvRow: Identifiable { let id: String; let name: String; let paired: Bool; let online: Bool; let selected: Bool; let canWake: Bool }

/// Live numbers shown in the Settings window (refreshed twice a second while it is open).
@available(macOS 13.0, *) final class Live: ObservableObject {
    @Published var connected = false
    @Published var status = ""
    @Published var receiver = "—"
    @Published var link = "—"
    @Published var iface = ""
    @Published var size = "—"
    @Published var encoder = "—"
    @Published var quality = "—"
    @Published var looksLike = "—"
    @Published var fps = 0.0
    @Published var target = 0
    @Published var mbps = 0.0
    @Published var rtt = 0.0
    @Published var pipe = 0.0
    @Published var pipeSub = ""
    @Published var rxFps = 0.0
    @Published var gb = 0.0
    @Published var dropped = 0
    @Published var uptime = "0:00:00"
    @Published var fpsH: [Double] = []
    @Published var mbpsH: [Double] = []
    @Published var rttH: [Double] = []
    @Published var rows: [RecvRow] = []
    func push(fps: Double, mbps: Double, rtt: Double) {
        fpsH.append(fps); mbpsH.append(mbps); rttH.append(rtt)
        if fpsH.count > 120 { fpsH.removeFirst(fpsH.count - 120); mbpsH.removeFirst(mbpsH.count - 120); rttH.removeFirst(rttH.count - 120) }
    }
    func clearHistory() { fpsH = []; mbpsH = []; rttH = [] }
}

/// Small observable boolean (the command-line toolchain has no @State macro plugin).
@available(macOS 13.0, *) final class Flag: ObservableObject {
    @Published var on: Bool
    init(_ v: Bool = false) { on = v }
}

/// Display options that need an explicit Apply (they recreate the virtual display).
@available(macOS 13.0, *) final class Pending: ObservableObject {
    @Published var resMode = defaults.string(forKey: "resMode") ?? "match"
    @Published var resW = defaults.integer(forKey: "resW") == 0 ? 3840 : defaults.integer(forKey: "resW")
    @Published var resH = defaults.integer(forKey: "resH") == 0 ? 2160 : defaults.integer(forKey: "resH")
    @Published var hidpi = defaults.string(forKey: "hidpi") ?? "auto"
    @Published var fpsCap = defaults.integer(forKey: "fpsCap")
    var dirty: Bool {
        resMode != (defaults.string(forKey: "resMode") ?? "match") || hidpi != (defaults.string(forKey: "hidpi") ?? "auto") || fpsCap != defaults.integer(forKey: "fpsCap")
            || (resMode == "custom" && (resW != defaults.integer(forKey: "resW") || resH != defaults.integer(forKey: "resH")))
    }
    func revert() {
        resMode = defaults.string(forKey: "resMode") ?? "match"; hidpi = defaults.string(forKey: "hidpi") ?? "auto"; fpsCap = defaults.integer(forKey: "fpsCap")
        resW = defaults.integer(forKey: "resW") == 0 ? 3840 : defaults.integer(forKey: "resW")
        resH = defaults.integer(forKey: "resH") == 0 ? 2160 : defaults.integer(forKey: "resH")
    }
    func commit() {
        defaults.set(resMode, forKey: "resMode"); defaults.set(hidpi, forKey: "hidpi"); defaults.set(fpsCap, forKey: "fpsCap")
        defaults.set(max(640, min(4096, resW)), forKey: "resW"); defaults.set(max(360, min(2304, resH)), forKey: "resH")
        objectWillChange.send()
    }
}

@available(macOS 13.0, *) struct InfoButton: View {
    let text: String
    @StateObject private var show = Flag()
    var body: some View {
        Button { show.on.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .popover(isPresented: $show.on, arrowEdge: .trailing) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 290, alignment: .leading)
            }
    }
}

@available(macOS 13.0, *) struct Row<C: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder var content: C
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let i = info { InfoButton(text: i) }
            Spacer(minLength: 12)
            content
        }
    }
}

@available(macOS 13.0, *) enum Pane: String, CaseIterable, Identifiable {
    case general = "General", display = "Display", quality = "Quality", connection = "Connection", color = "Color", stats = "Statistics", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "display"
        case .quality: return "dial.medium"
        case .connection: return "cable.connector"
        case .color: return "paintpalette"
        case .stats: return "chart.xyaxis.line"
        case .about: return "info.circle"
        }
    }
}

@available(macOS 13.0, *) final class Nav: ObservableObject { @Published var pane: Pane? = .general }

@available(macOS 13.0, *) struct StatusStrip: View {
    @ObservedObject var live: Live
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(live.connected ? Color.green : Color.secondary).frame(width: 9, height: 9)
            Text(live.connected ? "\(live.receiver) · \(live.link) · \(live.size) · \(Int(live.fps.rounded())) fps" : live.status)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }
}

@available(macOS 13.0, *) struct Root: View {
    @ObservedObject var live: Live
    @ObservedObject var nav: Nav
    let app: SenderApp
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { t in
                    Button { nav.pane = t } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t.icon).frame(width: 20)
                            Text(t.rawValue)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle((nav.pane ?? .general) == t ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 7).fill((nav.pane ?? .general) == t ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10).frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            VStack(spacing: 0) {
                StatusStrip(live: live)
                switch nav.pane ?? .general {
                case .general: GeneralPane(app: app)
                case .display: DisplayPane(app: app, live: live)
                case .quality: QualityPane(app: app, live: live)
                case .connection: ConnectionPane(app: app, live: live)
                case .color: ColorPane(app: app)
                case .stats: StatsPane(live: live)
                case .about: AboutPane(app: app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: General
@available(macOS 13.0, *) struct AgentActivity: View {
    @ObservedObject var log = AgentLog.shared
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Recent agent activity").font(.callout.weight(.medium)); Spacer(); if !log.events.isEmpty { Button("Clear") { log.clear() }.buttonStyle(.link) } }
            if log.events.isEmpty { Text("Nothing yet. Every request from an agent or script is listed here with the program that made it.").font(.caption).foregroundStyle(.secondary) }
            ForEach(log.events.prefix(8)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.fmt.string(from: e.time)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Image(systemName: e.ok ? "checkmark.circle" : "xmark.circle").foregroundStyle(e.ok ? Color.green : Color.red).font(.caption)
                    Text("\(e.client) · \(e.action)").font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

@available(macOS 13.0, *) struct GeneralPane: View {
    let app: SenderApp
    @AppStorage("enabled") var enabled = true
    @AppStorage("notif") var notif = true
    @AppStorage("audio") var audio = true
    @AppStorage("batteryCap") var batteryCap = false
    @AppStorage("acceptInput") var acceptInput = true
    @AppStorage("agentControl") var agentControl = false
    @StateObject var login = Flag(SMAppService.mainApp.status == .enabled)
    var body: some View {
        Form {
            Section("Streaming") {
                Row(title: "Stream to receiver", info: "Turn off to pause. The virtual display is removed and nothing is captured or sent.") { Toggle("", isOn: $enabled).labelsHidden() }
                Row(title: "Save power on battery", info: "Caps the frame rate at 30 fps while this Mac runs on battery, so the encoder and Wi-Fi work less. Back to normal on power. Off by default.") { Toggle("", isOn: $batteryCap).labelsHidden() }
                Row(title: "Send sound to receiver", info: "Plays this Mac's audio on the receiver's speakers. Uses about 1.5 Mbps.") { Toggle("", isOn: $audio).labelsHidden() }
            }
            Section("Extra screen input") {
                Row(title: "Accept keyboard & mouse", info: "Lets the extra screen's keyboard and mouse control this Mac. The receiver must also turn it on (Settings › Display). Needs Accessibility permission. Pause anytime with ⌃⌥⌘D.") { Toggle("", isOn: $acceptInput).labelsHidden() }
                Row(title: "Accessibility", info: "macOS requires this permission before an app can send keyboard and mouse events.") {
                    HStack { Text(Injector.trusted ? "Allowed" : "Not allowed").foregroundStyle(.secondary)
                        Button("Open…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                }
            }
            Section("AI agents & scripts") {
                Row(title: "Allow AI agents & scripts", info: "Lets AI assistants and scripts on this Mac check status, run diagnostics, and change quality, link and receivers. Local only, this user only. Pairing new Macs, keyboard/mouse forwarding and the role always stay manual.") { Toggle("", isOn: $agentControl).labelsHidden() }
                if agentControl {
                    AgentActivity()
                    Row(title: "Connect an agent", info: "Adds OpenAirDisplay as an MCP server. Claude Code: run the copied command in a terminal. Other apps (Claude desktop, Cursor…): paste the JSON into their MCP settings.") {
                        HStack {
                            Button("Copy Claude Code command") { copyText("claude mcp add openairdisplay -- \"" + (Bundle.main.executablePath ?? "OpenAirDisplay") + "\" --mcp") }
                            Button("Copy JSON config") { copyText("{\n  \"mcpServers\": {\n    \"openairdisplay\": { \"command\": \"" + (Bundle.main.executablePath ?? "OpenAirDisplay") + "\", \"args\": [\"--mcp\"] }\n  }\n}") }
                        }
                    }
                }
            }
            Section("This Mac") {
                Row(title: "Role", info: "This Mac sends its desktop to another Mac. Switch to make it the extra screen instead. The app restarts.") { Button("Be the extra screen…") { switchRole(to: .receiver) } }
            }
            Section("App") {
                Row(title: "Launch at login", info: "Starts OpenAirDisplay automatically so the receiver connects as soon as you log in.") { Toggle("", isOn: $login.on).labelsHidden() }
                Row(title: "Notifications", info: "Banners when the display connects, disconnects, falls back to Wi-Fi, or a cable becomes available.") { Toggle("", isOn: $notif).labelsHidden() }
            }
            Section("Help") {
                HStack {
                    Button("Setup guide…") { app.showGuide() }
                    Button("Screen Recording permission…") { app.openPrivacy() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { app.setEnabled($0) }
        .onChange(of: audio) { app.audioOn = $0; app.session?.audioOn = $0 }
        .onChange(of: notif) { if $0 { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } } }
        .onChange(of: login.on) { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { login.on = SMAppService.mainApp.status == .enabled }
        }
    }
}

// Display, Quality, Connection, Color, Statistics and About panes: SettingsPanes.swift

// MARK: window
@available(macOS 13.0, *) final class SettingsWindow: NSObject, NSWindowDelegate {
    unowned let app: SenderApp
    var win: NSWindow?
    let nav = Nav()
    init(app: SenderApp) { self.app = app }
    func show(_ pane: Pane? = nil) {
        if let t = pane { nav.pane = t }
        if win == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Root(live: app.live, nav: nav, app: app)))
            w.title = "OpenAirDisplay Settings"
            w.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable, .resizable])
            w.setContentSize(NSSize(width: 820, height: 580)); w.isReleasedWhenClosed = false; w.delegate = self
            win = w
        }
        if let w = win, !w.isVisible, let scr = NSScreen.screens.first {   // always the primary (MacBook) screen, never the virtual display
            let f = scr.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
        }
        app.startUITimer()
        NSApp.activate(ignoringOtherApps: true)
        win?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ n: Notification) { app.stopUITimer() }
}

func copyText(_ t: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
