# Security

AirDisplay sends your screen, sound and (optionally) keyboard and mouse events between two Macs. Please report problems privately.

## Reporting a vulnerability

Use a private GitHub security advisory on this repository, or contact the author through [sanangoyal.com](https://sanangoyal.com). Please do not open a public issue for a vulnerability. Include the macOS versions, what you did and what happened. You will get a reply within a few days. This is a free, spare-time project: there is no bug bounty, but reporters are credited in the changelog if they wish.

## What the app does, security-wise

- **No servers.** Direct TCP connection between your two Macs (port 7777, discovered with Bonjour). No accounts, analytics or telemetry.
- **Pairing.** One time, with a 6-digit number shown on both Macs that you compare (commit-and-reveal, so an attacker on the network cannot pick the number). The receiver accepts new pairings only while its pairing window is open (5 minutes).
- **Identity.** Each Mac has an Ed25519 key. After pairing each Mac accepts only the key it paired with. Unknown Macs are refused.
- **Encryption.** Ephemeral X25519 key agreement per connection, HKDF, AES-GCM for everything after the handshake.
- **Keyboard and mouse.** Off by default. Needs the receiver to turn it on and the sender to allow it, plus macOS Accessibility permission. Hold Esc on the receiver for 1.5 s, or press ⌃⌥⌘D on the main Mac, to stop. Keys held down are released when the session ends.
- **Agent control.** Off by default (Settings › General › Allow AI agents & scripts). Uses a Unix socket in `~/Library/Application Support/AirDisplay/` (mode 0600), accepts only the same user, and is never reachable from the network. It cannot pair Macs, forward input, switch role or reset settings. Every request is listed in Settings with the program that made it.
- **Permissions.** Screen Recording (capture the virtual display), Local Network (find the other Mac), Accessibility (only for forwarded input).

## Known limits

- The pairing and transport protocol is custom and has not had an independent audit. Treat it as hobby-grade security: good against casual snooping on your LAN, not a substitute for a reviewed protocol on a hostile network.
- The app uses a private Apple API (`CGVirtualDisplay`). It is not sandboxed.
- Builds are ad-hoc signed and not notarized unless a release says otherwise. Verify the SHA-256 listed with a release.
- A malicious program running as you on the main Mac can already do far more than control AirDisplay. The agent socket does not defend against that, only against other users and the network.

## Supported versions

Only the latest release gets fixes.
