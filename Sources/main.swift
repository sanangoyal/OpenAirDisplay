import Cocoa

setvbuf(stdout, nil, _IOLBF, 0)

// Headless modes for agents/scripts: no UI, no single-instance guard (they only talk to the running app).
if CommandLine.arguments.contains("--mcp") { runMCP(); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--ctl") { runCtl(Array(CommandLine.arguments.dropFirst(i + 1))); exit(0) }

// One copy only: two copies would both grab the same receiver and keep kicking each other off (the lower PID wins; a
// relaunch after a role switch waits a moment for the old copy to quit).
if let bid = Bundle.main.bundleIdentifier {
    let me = ProcessInfo.processInfo.processIdentifier
    func others() -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { $0.processIdentifier != me && !$0.isTerminated } }
    var tries = 0
    while !others().isEmpty && tries < 15 { if others().allSatisfy({ $0.processIdentifier > me }) { break }; usleep(200_000); tries += 1 }
    if others().contains(where: { $0.processIdentifier < me }) { exit(0) }
}

let nsApplication = NSApplication.shared
var rootDelegate: NSApplicationDelegate

switch currentRole {
case .receiver?:
    if FileManager.default.fileExists(atPath: agentPath) { let pl: [String: Any] = ["Label": agentLabel, "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath], "RunAtLoad": true]; (pl as NSDictionary).write(toFile: agentPath, atomically: true) }
    rootDelegate = ReceiverApp()
case .sender?:
    if #available(macOS 13.0, *) {
        rootDelegate = SenderApp()
    } else {
        // Sending needs ScreenCaptureKit audio and other APIs from macOS 13.
        let a = NSAlert()
        a.messageText = "This Mac can only be the extra screen"
        a.informativeText = "Using this Mac as the main Mac needs macOS 13 or later. It will be set up as the extra screen instead."
        a.runModal()
        UserDefaults.standard.set(Role.receiver.rawValue, forKey: "role")
        rootDelegate = ReceiverApp()
    }
case nil:
    rootDelegate = RolePickerApp()
}

nsApplication.delegate = rootDelegate
nsApplication.setActivationPolicy(.accessory)
nsApplication.run()
