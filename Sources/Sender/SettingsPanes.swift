import SwiftUI
import Charts
import ServiceManagement
import UserNotifications

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
    @AppStorage("codec") var codec = "auto"
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
            Section("Video codec") {
                Row(title: "Codec", info: "HEVC gives a sharper picture at the same bit rate and has no 4K 60 fps limit, but the extra screen must decode it in hardware (newer Macs). Automatic uses HEVC when the extra screen supports it, otherwise H.264. Changes apply at the next connection.") {
                    Picker("", selection: $codec) {
                        Text("Automatic (recommended)").tag("auto")
                        Text("H.264 only").tag("h264")
                    }.labelsHidden().frame(width: 300)
                }
                Row(title: "Right now") { Text(live.connected ? live.encoder : "—").foregroundStyle(.secondary) }
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
            Section("Receivers · use several at once") {
                if live.rows.isEmpty { Text("No receivers found. Open “OpenAirDisplay” on the other Mac.").foregroundStyle(.secondary) }
                ForEach(live.rows) { r in
                    HStack(spacing: 8) {
                        Circle().fill(r.online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                        Text(r.name)
                        if r.selected { Text("in use").font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                        Text(r.online ? "" : "offline").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if r.paired {
                            if !r.online && r.canWake { Button("Wake") { app.wakeReceiver(r.id) } }
                            Button(r.selected ? "Stop using" : "Use") { app.toggleUse(r.id) }
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
                Text("Every session is encrypted end to end. A receiver must be paired once: both Macs show the same 6-digit number and you click Pair on each, and the Macs verify each other's key on every connection.")
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
                    Tile(title: "Capture + encode", value: live.connected ? String(format: "%.1f ms", live.pipe) : "—", sub: live.connected ? String(format: "≈ %.0f ms to the other Mac's screen", live.pipe + live.rtt / 2) : "")
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
                        Text("OpenAirDisplay").font(.title2.bold())
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                        Text("Use another Mac as a wired, low-latency display.").font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 4) { Text("Made by Sanan Goyal ·").foregroundStyle(.secondary); Link("sanangoyal.com", destination: URL(string: "https://sanangoyal.com")!) }.font(.callout)
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
            Section("Privacy & legal") {
                Text("No accounts, no analytics, no servers. Video, sound and input go directly between your Macs, encrypted, and only to Macs you paired. Nothing is stored except your settings and the keys of paired Macs. Screen Recording is used to capture the virtual display, Accessibility only for keyboard and mouse from the extra screen, and Local Network to find your other Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Free software under the MIT License, provided “as is” without warranty of any kind. Use at your own risk. Not affiliated with or endorsed by Apple. Mac, macOS and iMac are trademarks of Apple Inc. Protected video (Netflix and similar) cannot be shown, as with Sidecar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

