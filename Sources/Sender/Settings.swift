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
@available(macOS 13.0, *) struct GeneralPane: View {
    let app: SenderApp
    @AppStorage("enabled") var enabled = true
    @AppStorage("notif") var notif = true
    @AppStorage("audio") var audio = true
    @AppStorage("acceptInput") var acceptInput = true
    @StateObject var login = Flag(SMAppService.mainApp.status == .enabled)
    var body: some View {
        Form {
            Section("Streaming") {
                Row(title: "Stream to receiver", info: "Turn off to pause. The virtual display is removed and nothing is captured or sent.") { Toggle("", isOn: $enabled).labelsHidden() }
                Row(title: "Send sound to receiver", info: "Plays this Mac's audio on the receiver's speakers. Uses about 1.5 Mbps.") { Toggle("", isOn: $audio).labelsHidden() }
            }
            Section("Extra screen input") {
                Row(title: "Accept keyboard & mouse", info: "Lets the extra screen's keyboard and mouse control this Mac. The receiver must also turn it on (Settings › Display). Needs Accessibility permission. Pause anytime with ⌃⌥⌘D.") { Toggle("", isOn: $acceptInput).labelsHidden() }
                Row(title: "Accessibility", info: "macOS requires this permission before an app can send keyboard and mouse events.") {
                    HStack { Text(Injector.trusted ? "Allowed" : "Not allowed").foregroundStyle(.secondary)
                        Button("Open…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                }
            }
            Section("This Mac") {
                Row(title: "Role", info: "This Mac sends its desktop to another Mac. Switch to make it the extra screen instead. The app restarts.") { Button("Be the extra screen…") { switchRole(to: .receiver) } }
            }
            Section("App") {
                Row(title: "Launch at login", info: "Starts AirDisplay automatically so the receiver connects as soon as you log in.") { Toggle("", isOn: $login.on).labelsHidden() }
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

// MARK: Display
@available(macOS 13.0, *) struct DisplayPane: View {
    let app: SenderApp
    @ObservedObject var live: Live
    @AppStorage("mirror") var mirror = false
    @StateObject var pd = Pending()
    var body: some View {
        Form {
            Section("Mode") {
                Row(title: "Use the receiver as", info: "Extended: an extra screen you can drag windows onto.\nMirror: shows this Mac's main screen, fitted to the receiver.") {
                    Picker("", selection: $mirror) { Text("Extended display").tag(false); Text("Mirror this Mac").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
            }
            Section("Resolution") {
                Row(title: "Resolution", info: "Match receiver reads the other Mac's screen and fits the virtual display to it. Lower values are lighter on the link and the receiver. The Intel iMac decodes video up to 4096×2304 at Level 5.2.") {
                    Picker("", selection: $pd.resMode) {
                        Text("Match receiver (recommended)").tag("match")
                        Text("4K · 3840×2160").tag("4k")
                        Text("1440p · 2560×1440").tag("1440")
                        Text("1080p · 1920×1080").tag("1080")
                        Text("Custom…").tag("custom")
                    }.labelsHidden().frame(width: 250)
                }
                if pd.resMode == "custom" {
                    Row(title: "Custom size") {
                        HStack { TextField("W", value: $pd.resW, format: .number.grouping(.never)).frame(width: 64); Text("×"); TextField("H", value: $pd.resH, format: .number.grouping(.never)).frame(width: 64) }
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Row(title: "Retina scaling", info: "On: the virtual display is Retina, so text looks sharp and UI is half the pixel size (like a MacBook). Off: 1 point = 1 pixel, everything looks tiny on a 4K panel. Auto turns it on above 2560 px wide.") {
                    Picker("", selection: $pd.hidpi) { Text("Auto").tag("auto"); Text("On").tag("on"); Text("Off").tag("off") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                Row(title: "Frame rate limit", info: "Auto uses the quality level's rate (up to 60). Native 4096×2304 is capped at 56 fps by the H.264 Level 5.2 decode limit. A lower limit saves bandwidth and CPU.") {
                    Picker("", selection: $pd.fpsCap) { Text("Auto").tag(0); Text("30").tag(30); Text("45").tag(45); Text("60").tag(60) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            if pd.dirty {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Applying recreates the virtual display. Windows on it move to your main screen once.").font(.callout)
                        Spacer()
                        Button("Revert") { pd.revert() }
                        Button("Apply & Reconnect") { pd.commit(); app.restartSession() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            Section("Current") {
                Row(title: "Stream size") { Text(live.connected ? live.size : "—").foregroundStyle(.secondary) }
                Row(title: "Looks like") { Text(live.connected ? live.looksLike : "—").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: mirror) { _ in app.session?.end("Restarting") }
    }
}

// MARK: Quality
@available(macOS 13.0, *) struct QualityPane: View {
    let app: SenderApp
    @ObservedObject var live: Live
    @AppStorage("preset") var mode = -1
    @AppStorage("bitrateOn") var custom = false
    @AppStorage("bitrateTarget") var target = 80
    var body: some View {
        Form {
            Section("Quality level") {
                Row(title: "Level", info: "Auto starts at the best level the link allows (Ultra on a cable) and steps down if frames drop or latency rises, then back up when stable. Smooth keeps a true 60 fps at 4K.") {
                    Picker("", selection: $mode) {
                        Text("Auto (recommended)").tag(-1)
                        ForEach(0..<presets.count, id: \.self) { Text(presets[$0].name).tag($0) }
                    }.labelsHidden().frame(width: 300)
                }
                Row(title: "Right now") { Text(live.connected ? live.quality : "—").foregroundStyle(.secondary) }
            }
            Section("Bitrate") {
                Row(title: "Custom bitrate", info: "Overrides the level's automatic bitrate. Higher is sharper on fast motion; wired links handle 100+ Mbps. Leave off unless you are tuning.") { Toggle("", isOn: $custom).labelsHidden() }
                if custom {
                    Row(title: "Target") {
                        HStack {
                            Slider(value: Binding(get: { Double(target) }, set: { target = Int($0) }), in: 10...300, step: 5).frame(width: 220)
                            Text("\(target) Mbps").monospacedDigit().frame(width: 76, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Auto behaviour") {
                Text("Drops a level after 3 bad seconds (dropped frames, latency over 30 ms, or the receiver decoding under 75% of what is sent). Returns up after 40 stable seconds. Ultra only runs on a wired link.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: mode) { app.setQuality($0) }
        .onChange(of: custom) { _ in app.reencode() }
        .onChange(of: target) { _ in if custom { app.reencode() } }
    }
}

// MARK: Connection
@available(macOS 13.0, *) struct ConnectionPane: View {
    let app: SenderApp
    @ObservedObject var live: Live
    @AppStorage("linkMode") var link = 0
    @AppStorage("autoWake") var autoWake = true
    var body: some View {
        Form {
            Section("Link") {
                Row(title: "Connection", info: "Auto uses the best available link: Thunderbolt, then Ethernet, then Wi-Fi, and offers to switch when a cable appears. Wired only never uses Wi-Fi. Wi-Fi only ignores cables.") {
                    Picker("", selection: $link) { Text("Auto").tag(0); Text("Wired only").tag(1); Text("Wi-Fi only").tag(2) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                Row(title: "Current link") { Text(live.connected ? "\(live.link)" + (live.iface.isEmpty ? "" : " (\(live.iface))") : "—").foregroundStyle(.secondary) }
            }
            Section("Receivers") {
                if live.rows.isEmpty { Text("No receivers found. Open “AirDisplay” on the other Mac.").foregroundStyle(.secondary) }
                ForEach(live.rows) { r in
                    HStack(spacing: 8) {
                        Circle().fill(r.online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                        Text(r.name)
                        if r.selected { Text("in use").font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                        Text(r.online ? "" : "offline").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if r.paired {
                            if !r.online && r.canWake { Button("Wake") { app.wakeReceiver(r.id) } }
                            if !r.selected { Button("Use") { app.selectReceiver(r.id) } }
                            Button("Forget", role: .destructive) { app.forgetReceiver(r.id) }
                        } else if r.online {
                            Button("Pair…") { app.pairReceiver(r.id) }
                        }
                    }
                }
                Row(title: "Wake sleeping receiver", info: "If the receiver Mac is asleep, send it a Wake-on-LAN signal so it wakes and connects by itself. Works over Ethernet or Thunderbolt (a cable); over Wi-Fi it works only if a Bonjour sleep proxy such as an Apple TV or HomePod is on the network. The receiver must have “Wake for network access” on (the default). The wake address is learned the first time you connect.") { Toggle("", isOn: $autoWake).labelsHidden() }
                HStack {
                    Button("Pair by address…") { app.pairByAddress() }
                    Spacer()
                    Text("Use if the receiver isn't listed.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Security") {
                Text("Every session is encrypted end to end. A receiver must be paired once with a code shown on its screen, and the Macs verify each other's key on every connection.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: link) { app.setLinkMode($0) }
    }
}

// MARK: Color
@available(macOS 13.0, *) struct ColorPane: View {
    let app: SenderApp
    @AppStorage("colorProfile") var profile = "auto"
    var body: some View {
        Form {
            Section("Color profile") {
                Row(title: "Stream color space", info: "Tags the captured picture and the video stream with a color space so both Macs interpret it the same way. Both Macs here can show Display P3. Auto leaves the system default.") {
                    Picker("", selection: $profile) {
                        Text("Auto (system default)").tag("auto")
                        Text("sRGB").tag("srgb")
                        Text("Display P3 (wide gamut)").tag("p3")
                    }.labelsHidden().frame(width: 230)
                }
            }
            Section {
                Text("Takes effect immediately. The picture re-encodes in a moment, no reconnect needed. If colors look washed out or oversaturated on the receiver, try another profile.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile) { _ in app.reencode() }
    }
}

// MARK: Statistics
@available(macOS 13.0, *) struct Tile: View {
    let title: String
    let value: String
    var sub: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}

@available(macOS 13.0, *) struct Spark: View {
    let title: String
    let unit: String
    let data: [Double]
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f %@", data.last ?? 0, unit)).font(.caption).monospacedDigit() }
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("v", v)).interpolationMethod(.monotone).foregroundStyle(color)
                    AreaMark(x: .value("t", i), y: .value("v", v)).interpolationMethod(.monotone).foregroundStyle(color.opacity(0.15))
                }
            }
            .chartXAxis(.hidden).chartYScale(domain: 0...max(1, (data.max() ?? 1) * 1.2)).frame(height: 74)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}

@available(macOS 13.0, *) struct StatsPane: View {
    @ObservedObject var live: Live
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    Tile(title: "Frame rate", value: live.connected ? "\(Int(live.fps.rounded())) fps" : "—", sub: live.connected ? "target \(live.target) · receiver \(Int(live.rxFps.rounded()))" : "")
                    Tile(title: "Bitrate", value: live.connected ? String(format: "%.1f Mbps", live.mbps) : "—", sub: live.connected ? String(format: "%.2f GB sent", live.gb) : "")
                    Tile(title: "Latency", value: live.connected ? String(format: "%.1f ms", live.rtt) : "—", sub: live.connected ? "round trip" : "")
                    Tile(title: "Dropped frames", value: live.connected ? "\(live.dropped)" : "—", sub: "this session")
                    Tile(title: "Link", value: live.connected ? live.link : "—", sub: live.iface)
                    Tile(title: "Session", value: live.connected ? live.uptime : "—", sub: live.connected ? live.receiver : "")
                    Tile(title: "Resolution", value: live.connected ? live.size : "—", sub: live.connected ? live.looksLike : "")
                    Tile(title: "Encoder", value: live.connected ? live.encoder : "—", sub: "H.264 hardware")
                    Tile(title: "Quality", value: live.connected ? live.quality : "—", sub: "")
                }
                Spark(title: "Frame rate (last 60 s)", unit: "fps", data: live.fpsH, color: .blue)
                Spark(title: "Bitrate (last 60 s)", unit: "Mbps", data: live.mbpsH, color: .purple)
                Spark(title: "Latency (last 60 s)", unit: "ms", data: live.rttH, color: .green)
                Text("A static screen sends very little: the picture is only refreshed when something changes, plus a keep-alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

// MARK: About
@available(macOS 13.0, *) struct AboutPane: View {
    let app: SenderApp
    @StateObject var copied = Flag()
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AirDisplay").font(.title2.bold())
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                        Text("Use another Mac as a wired, low-latency display.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            Section("This Mac") {
                Row(title: "macOS") { Text(ProcessInfo.processInfo.operatingSystemVersionString).foregroundStyle(.secondary) }
                Row(title: "Device ID", info: "Identifies this Mac to receivers. Not secret.") { Text(app.keys.myID).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("Support") {
                HStack {
                    Button(copied.on ? "Copied" : "Copy diagnostics") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.diagnostics(), forType: .string)
                        copied.on = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied.on = false }
                    }
                    Button("Reset all settings…", role: .destructive) { app.resetSettings() }
                    Spacer()
                }
                Text("Uses a private macOS API to create the virtual display, so a macOS update can break it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

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
            w.title = "AirDisplay Settings"
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
