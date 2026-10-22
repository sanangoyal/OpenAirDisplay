# Contributing

Thanks for helping. AirDisplay is a small, dependency-free Swift project: just the Xcode Command Line Tools.

## Build and test

```sh
scripts/build.sh            # universal app in build/AirDisplay.app
scripts/build.sh --install  # also copies it to ~/Applications
scripts/test.sh             # handshake / pairing tests (no hardware needed)
```

Sign with a stable certificate (`SIGN_ID="My Local Signing" scripts/build.sh`) so macOS keeps the Screen Recording permission between rebuilds.

## Layout

- `Sources/Sender` main-Mac side: capture, encode, sessions, menu, settings, pairing, input injection, agent control.
- `Sources/Receiver` extra-screen side: decode, display, pairing window, input forwarding.
- `Sources/Shared` wire protocol and crypto (`Wire.swift`), input events, Wake-on-LAN, debug log, MCP bridge.
- `Tests/handshake` protocol tests (pairing, reconnect, stranger refused, tampering).

## Rules of thumb

- Sender code needs macOS 13+, receiver code must still build for macOS 12 (target `macos12.0`, guard new APIs with `#available`).
- Do not weaken pairing or add anything that lets a remote party control the Mac without the person confirming. Agent control must never expose pairing, input forwarding, role switching or reset.
- No analytics, no network calls other than to the paired Mac.
- Debugging: `touch ~/.airdisplay-debug` writes `~/airdisplay.log`. Remove it afterwards.
- Keep changes small and say how you tested them (which Macs, wired or Wi-Fi).

By contributing you agree your work is released under the MIT License.
