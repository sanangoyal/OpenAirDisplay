# AirDisplay

**Turn an old Mac into a real second screen for your new one.** Free, open source, no account, no dongle, no subscription.

Got a 5K iMac gathering dust, or a Mac mini on a spare monitor? Install the same app on both Macs. The old one becomes a true extended display (not a mirror), full native resolution, wired or wireless.

> Status: early release, built and tested on a late-2015 iMac 4K (receiver) and an Apple silicon MacBook Pro (sender). Expect rough edges. Issues and PRs welcome.

## Why

- Apple's Target Display Mode is gone from every Mac made in the last decade. Sidecar is iPad-only.
- Paid options want a subscription, a hardware dongle, or an account.
- Old Macs have great panels and little else to do.

## Features

- **Extended, not mirrored.** The main Mac gets a new virtual display. Drag windows onto it like any monitor.
- **Native resolution.** The virtual display matches the other Mac's panel, HiDPI included (4096×2304 on a 4K iMac).
- **Low latency.** Hardware H.264 on both ends, tuned for speed. Ethernet or Thunderbolt cable is best; Wi-Fi works and quality adapts automatically.
- **Automatic link choice.** Prefers wired when both are available, with a notification to switch if a cable appears mid-session. Or force Wired or Wi-Fi only.
- **HEVC when available.** If the extra screen can decode HEVC in hardware (newer Macs), AirDisplay uses it automatically: sharper at the same bit rate and no 4K 60 fps cap. Older Macs stay on H.264.
- **Several extra screens at once.** Pair more than one Mac and tick each one under Receivers; every one gets its own virtual display. Arrange them in System Settings › Displays. Sound goes to the first one.
- **Quality presets.** Auto, Ultra, Best, Balanced, Light, plus a "Smooth 4K 60" mode for 60 Hz panels.
- **Keyboard and mouse from the extra screen (opt-in).** Use the extra Mac's own keyboard and mouse to control the main Mac. Tap Esc is passed through; hold Esc for 1.5 s to leave. Pause from the main Mac any time with ⌃⌥⌘D.
- **Sound.** Optionally plays the main Mac's audio on the extra screen's speakers.
- **Wake-on-LAN.** Wake a sleeping extra screen from the menu or automatically.
- **One app, two roles.** Pick "Use another Mac as my display" or "Be the extra screen" at first launch. Change it any time in Settings.
- **Private.** Direct connection between your two Macs. No servers, no telemetry, no accounts. Pairing is a one-time step: both Macs show the same 6-digit number and you click Pair on each (so a stranger on your Wi-Fi can't pair); after that each Mac only talks to the Mac it paired with, and everything on the wire is encrypted.
- **Live stats.** Frame rate, bit rate, ping and drops in the menu and in Settings.

## Requirements

| Role | macOS | Notes |
|---|---|---|
| Main Mac (sender) | **13 Ventura or later**, Apple silicon or Intel | Needs Screen Recording permission |
| Extra screen (receiver) | **12 Monterey or later**, Apple silicon or Intel | Hardware H.264 decode |

Both Macs on the same network, or joined by Ethernet or a Thunderbolt/USB bridge cable.

A Mac on macOS 12 can only be the extra screen; the app locks the sender role there.

## Install

Build from source (needs only Xcode Command Line Tools):

```sh
xcode-select --install          # once
git clone https://github.com/<you>/AirDisplay && cd AirDisplay
scripts/build.sh --install      # builds a universal app into ~/Applications
```

Copy `~/Applications/AirDisplay.app` to the other Mac too (AirDrop, USB stick, anything). Because it is not notarized, macOS may block the first launch of the copy. On recent macOS, right-click › Open no longer works for this: open System Settings › Privacy & Security, scroll down and click **Open Anyway**, or run `xattr -cr AirDisplay.app`.

Tip: sign with a stable certificate so macOS keeps the Screen Recording permission across rebuilds:

```sh
SIGN_ID="My Local Signing" scripts/build.sh --install
```

## Set up

1. Open AirDisplay on the **extra screen** Mac and choose **Be the extra screen**. It says it is ready to pair.
2. Open AirDisplay on your **main Mac** and choose **Use another Mac as my display**. It asks “Pair with …?”. Click Pair, check that both Macs show the same 6-digit number, and click Pair on each. Allow Screen Recording when asked.
3. Done. After the first pairing, they reconnect by themselves.

Press **Esc** on the extra screen to pause and use that Mac normally.

## FAQ

**How does it work?**
The main Mac creates a virtual display (via the private `CGVirtualDisplay` API), captures it with ScreenCaptureKit, encodes it with VideoToolbox (low-latency H.264), and sends it over one TCP connection. The extra screen decodes with `AVSampleBufferDisplayLayer` and shows it full-screen. Discovery uses Bonjour (`_odisplay._tcp`, port 7777).

**Why isn't it on the Mac App Store?**
It relies on a private API, which the App Store does not allow. It may break with a future macOS update.

**Why the purple recording indicator on my main Mac?**
macOS shows it whenever an app captures the screen. AirDisplay only captures its own virtual display, and nothing is stored.

**Wi-Fi is stuttery.**
Use a cable if you can. Also, with AirDrop set to "Everyone", macOS periodically scans and can cause hitches; set it to Contacts Only. If macOS asked for Local Network access and you missed it, enable it in System Settings › Privacy & Security.

**Why is 4K capped around 56 fps?**
(H.264 receivers only.) 4096×2304 at 60 fps exceeds H.264 Level 5.2, and level 6 streams black-screen the hardware decoder on Intel iMacs. "Native" mode caps at 56 fps to stay within the limit. "Smooth 4K 60" trades a little sharpness for a steady 60.

**Can I use an Intel MacBook as the main Mac?**
It should work on macOS 13+, but it is untested. Reports welcome.

**Is the connection encrypted?**
Yes. Ed25519 identity keys are pinned at pairing, session keys come from X25519, and frames are sealed with AES-GCM. The pairing number is a short authentication string with a commit-reveal step, so someone in the middle can't pick keys that make the numbers match (about a 1 in a million chance per attempt). This is a hobby project and has not had an independent security audit.

## Limitations

- Private API; may break on new macOS releases.
- Protected video (Netflix, Hotstar, Disney+ and similar) shows black on the extra screen. macOS hides DRM video from screen capture, exactly as with Sidecar and DisplayLink. Play it on the extra Mac itself instead.
- Input forwarding is basic: system shortcuts on the extra Mac (Cmd+Tab, Mission Control) stay local, and it needs Accessibility permission on the main Mac.
- Sender needs macOS 13+.
- Several extra screens work, but only the first one gets sound, and multi-screen has so far been tested only in code, not with three real Macs.
- Not notarized.

## AI agents & scripts (MCP)

AirDisplay can be driven by AI assistants and scripts. It is **off by default**: turn on *Settings › General › Allow AI agents & scripts*, then use the two copy buttons there.

```
claude mcp add airdisplay -- /Applications/AirDisplay.app/Contents/MacOS/AirDisplay --mcp
```

or in any MCP client's config:

```json
{ "mcpServers": { "airdisplay": { "command": "/Applications/AirDisplay.app/Contents/MacOS/AirDisplay", "args": ["--mcp"] } } }
```

Tools: `get_status`, `list_receivers`, `use_receiver`, `stop_using_receiver`, `pause_streaming`, `resume_streaming`, `set_quality`, `set_link`, `restart_stream`, and `diagnose` (health report with findings and suggested fixes). Scripts can use `AirDisplay --ctl <tool> '{"json":"args"}'`.

Security: the app listens on a Unix socket in `~/Library/Application Support/AirDisplay/` (mode 0600, peer UID checked), never on the network. Pairing a new Mac, keyboard/mouse forwarding, the role and reset are not exposed; they always need the person.

## Privacy

No accounts, no analytics, no telemetry, no servers. Video, sound and input go directly between your two Macs, encrypted, and only to Macs you paired. The app stores your settings and the public keys of paired Macs on each Mac, nothing else. It makes no internet connections.

Permissions it asks for: **Screen Recording** (capture the virtual display it creates), **Local Network** (find your other Mac), **Accessibility** (only if you turn on keyboard and mouse from the extra screen), and **Notifications** (optional banners).

## Security

See [SECURITY.md](SECURITY.md) for how pairing and encryption work, known limits, and how to report a vulnerability.

## Roadmap

Signed and notarized releases, Homebrew cask.

## Contributing

Issues and pull requests welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License and disclaimer

MIT. See [LICENSE](LICENSE). The software is provided "as is", without warranty of any kind, and you use it at your own risk; the author is not liable for any damage, data loss or hardware problems arising from its use.

AirDisplay is not affiliated with or endorsed by Apple Inc. Mac, macOS, iMac, MacBook, Thunderbolt and AirDrop are trademarks of Apple Inc. It is also unrelated to other products called "Air Display".

## Credits

Made by [Sanan Goyal](https://sanangoyal.com).
