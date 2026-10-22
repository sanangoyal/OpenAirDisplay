import Cocoa
import Network

@available(macOS 13.0, *) extension SenderApp {
    // MARK: pairing (first time): receiver says "ready to pair" -> we offer -> both Macs show the same number

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
            a.informativeText = userAsked ? "Make sure OpenAirDisplay is open on \(f.name) and set to “Be the extra screen”." : "\(f.name) is waiting to be paired. Click Pair, then check that both Macs show the same number."
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
}
