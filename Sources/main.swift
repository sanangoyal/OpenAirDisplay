import Cocoa

setvbuf(stdout, nil, _IOLBF, 0)

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
