<div align="center">

<img src="docs/hero.svg" alt="OpenAirDisplay: use an old iMac or any old Mac as a 4K external display for your MacBook" width="100%">

# OpenAirDisplay

**Use an old iMac (2015 and newer) or any old Mac as a real 4K external display for your MacBook.**
Wired or wireless. Native resolution. Free, open source, no account, no dongle, no subscription.

[![Download](https://img.shields.io/badge/Download-latest%20release-2dd4a0?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/sanangoyal/OpenAirDisplay/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)
[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black?style=for-the-badge&logo=apple)](#requirements)
[![Apple silicon + Intel](https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-555?style=for-the-badge)](#requirements)

![macOS: available](https://img.shields.io/badge/macOS-available-2dd4a0)
![iPhone: coming soon](https://img.shields.io/badge/iPhone-coming%20soon-lightgrey)
![iPad: coming soon](https://img.shields.io/badge/iPad-coming%20soon-lightgrey)
![Android: coming soon](https://img.shields.io/badge/Android-coming%20soon-lightgrey)
![TV: coming soon](https://img.shields.io/badge/TV-coming%20soon-lightgrey)
![Windows: coming soon](https://img.shields.io/badge/Windows-coming%20soon-lightgrey)

</div>

---

## Your old iMac makes a great second monitor

A 2015 iMac with a 4K Retina panel is still a gorgeous screen, but Apple's **Target Display Mode** never covered the Retina iMacs, **Sidecar** only works with an iPad, and the paid alternatives want a hardware dongle or a subscription.

OpenAirDisplay turns that iMac (or a Mac mini on a spare monitor, or an old MacBook) into a true **extended display** for your newer Mac: not a mirror, a second desktop you can drag windows onto. Install the same app on both Macs, pair them once, done.

- **Native resolution.** The virtual display matches the other Mac's panel, HiDPI included: **4096 × 2304** on a 2015 21.5" iMac 4K.
- **Low latency.** Hardware H.264 (and HEVC where the receiver supports it), tuned for speed. About 1 ms round trip over a cable, 50 fps at 4K in our tests.
- **Wired or wireless.** Thunderbolt/Ethernet is best, Wi-Fi works, and it switches to the cable by itself when you plug one in.
- **Private.** Direct connection between your two Macs. No servers, no accounts, no telemetry. Everything on the wire is encrypted.
- **Controllable by AI.** A built-in [MCP server](#control-it-with-ai-mcp) lets assistants and scripts check status, run diagnostics and change quality. Off by default.

> Status: early release. Built and tested on a late-2015 iMac 4K (extra screen) and Apple silicon MacBooks (main Mac, and as extra screen too). Expect rough edges; issues and pull requests are welcome.

## Install

**Download:** grab `OpenAirDisplay-<version>.dmg` from the [latest release](https://github.com/sanangoyal/OpenAirDisplay/releases/latest), drag the app to Applications on **both** Macs.

The app is not notarized yet, so macOS blocks the first launch. On recent macOS, right-click › Open no longer works for this: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. Or in Terminal: `xattr -cr /Applications/OpenAirDisplay.app`.

**Or build from source** (needs only the Xcode Command Line Tools):

```sh
xcode-select --install          # once
git clone https://github.com/sanangoyal/OpenAirDisplay && cd OpenAirDisplay
scripts/build.sh --install      # universal app (Intel + Apple silicon) in ~/Applications
```

Tip: sign with a stable certificate so macOS keeps the Screen Recording permission across rebuilds: `SIGN_ID="My Local Signing" scripts/build.sh --install`.

## Set up in two minutes

1. On the **old Mac** (the new screen): open OpenAirDisplay and choose **Be the extra screen**. It shows "ready to pair".
2. On your **main Mac**: open OpenAirDisplay and choose **Use another Mac as my display**. It offers to pair with the old Mac.
3. Both Macs show the **same 6-digit number**. If they match, click Pair on each. Allow Screen Recording when macOS asks.
4. Done. A new display appears in System Settings › Displays; arrange it and drag windows over. After the first time, the Macs reconnect by themselves.

Press **Esc** on the extra screen to pause and use that Mac normally.

## Requirements

| Role | macOS | Notes |
|---|---|---|
| **Main Mac** (sends) | **13 Ventura or later**, Apple silicon or Intel | Needs Screen Recording permission |
| **Extra screen** (receives) | **12 Monterey or later**, Apple silicon or Intel | Hardware H.264 decode |

Both Macs must be on the same network, or joined by Ethernet or a Thunderbolt/USB bridge cable. macOS 12 Monterey runs on iMacs from late 2015, MacBook Air/Pro from early 2015, and Mac minis from late 2014, which is what sets the oldest usable extra screen. A Mac stuck on macOS 12 can only be the extra screen; the app locks the sender role there.

**Tested:** iMac 21.5" 4K (late 2015, macOS 12.7) as extra screen; Apple silicon MacBooks as main Mac and as extra screen. Other Macs should work; [reports welcome](https://github.com/sanangoyal/OpenAirDisplay/issues). 5K iMacs are untested.

## How it works

<img src="docs/how-it-works.svg" alt="Diagram: the main Mac creates a virtual display, captures it, encodes it with hardware H.264 or HEVC, and sends it over an encrypted Thunderbolt, Ethernet or Wi-Fi link to the extra-screen Mac, which decodes and shows it full screen" width="100%">

The main Mac creates a virtual display (through the private `CGVirtualDisplay` API), captures it with ScreenCaptureKit, encodes it with VideoToolbox and sends it over one encrypted TCP connection. The extra screen decodes in hardware and shows it full-screen with `AVSampleBufferDisplayLayer`. Discovery uses Bonjour (`_odisplay._tcp`, port 7777).

## Features

- **Extended, not mirrored.** A new virtual display, arranged like any monitor.
- **Native resolution, 4K and beyond.** Matches the receiver's panel, including Retina HiDPI. H.264 receivers are capped near 56 fps at 4096 × 2304 (hardware decoder limit); HEVC-capable receivers have no such cap.
- **HEVC when available.** Used automatically when the extra screen can decode it in hardware: sharper at the same bit rate.
- **Several extra screens at once.** Pair more than one Mac and tick each under Receivers. Each gets its own virtual display.
- **Quality presets.** Auto (adapts to the link), Ultra, Best, Balanced, Light, and "Smooth 4K 60".
- **Automatic link choice.** Prefers wired, notifies you when a cable appears, or force Wired / Wi-Fi only.
- **Keyboard and mouse from the extra screen (opt-in).** Use the old Mac's own keyboard and mouse on your main Mac. Hold Esc for 1.5 s to leave; ⌃⌥⌘D on the main Mac pauses any time.
- **Sound.** Optionally plays the main Mac's audio on the extra screen's speakers.
- **Wake-on-LAN.** Wake a sleeping extra screen from the menu, or automatically.
- **One app, two roles.** Pick the role at first launch; change it any time in Settings.
- **Live stats.** Frame rate, bit rate, ping, drops, and capture + encode time in the menu and Settings.
- **Optional power saving.** Cap at 30 fps while on battery.

## How it compares

|  | **OpenAirDisplay** | Apple Sidecar | Luna Display | Duet Display |
|---|---|---|---|---|
| Use a **Mac** as the second display | Yes | No, iPad only | Yes | Yes ("Target Display Mode") |
| Extra hardware | None | None | USB-C or HDMI dongle (about $89.99) | None |
| Cost | Free, MIT licensed | Built in | One-time purchase | See [vendor site](https://www.duetdisplay.com) |
| Open source | **Yes** | No | No | No |
| Works with a late-2015 Retina iMac as the display | **Yes**, tested at 4096 × 2304 | No (the iPad is the display) | Secondary needs macOS 10.13+ | Intel desktop app listed for macOS 10.13 to 10.15 |
| Account / servers | None, direct link | Same Apple Account | Vendor apps | Vendor apps |
| AI / MCP control | **Built in** (opt-in) | - | - | - |

*Facts checked in October 2026 from Apple's [Sidecar page](https://support.apple.com/en-us/102597), the [Luna Display store page](https://shop.astropad.com/products/luna-display) and [duetdisplay.com](https://www.duetdisplay.com). Products change; [open an issue](https://github.com/sanangoyal/OpenAirDisplay/issues) if something is out of date. Each has strengths OpenAirDisplay does not: Duet and Luna reach iPads and (Duet) Windows and Android today, Sidecar is seamless with iPad. OpenAirDisplay is not affiliated with any of them.*

## Control it with AI (MCP)

OpenAirDisplay speaks [MCP](https://modelcontextprotocol.io) (Model Context Protocol), so AI assistants and scripts can control it without clicking through menus. It is **off by default**: turn on *Settings › General › Allow AI agents & scripts*, then use the copy buttons there.

```sh
claude mcp add openairdisplay -- /Applications/OpenAirDisplay.app/Contents/MacOS/OpenAirDisplay --mcp
```

or in any MCP client's config (Claude Desktop, Cursor, and others):

```json
{ "mcpServers": { "openairdisplay": { "command": "/Applications/OpenAirDisplay.app/Contents/MacOS/OpenAirDisplay", "args": ["--mcp"] } } }
```

Ask things like "why is my second screen laggy?", "switch to the wired link", or "drop quality to light".

| Tool | What it does |
|---|---|
| `diagnose` | Health report: permissions, duplicate copies, receivers, link, network route, recent events, findings with suggested fixes |
| `get_status`, `list_receivers` | Live stats and paired Macs |
| `use_receiver`, `stop_using_receiver` | Start or stop a paired Mac as a screen |
| `pause_streaming`, `resume_streaming`, `restart_stream` | Control the stream |
| `set_quality`, `set_link` | Quality preset; auto, wired or Wi-Fi |

Scripts can call the same commands: `OpenAirDisplay --ctl get_status`.

**Security:** the app listens on a Unix socket in `~/Library/Application Support/OpenAirDisplay/` (mode 0600, caller's user checked), never on the network. Pairing a new Mac, keyboard/mouse forwarding, the role and reset are not exposed; they always need you. Settings lists every request with the program that made it.

## FAQ

**Can I use a 2015 iMac as an external display for my MacBook?**
Yes. That is what this was built for. Install OpenAirDisplay on both Macs, pair them, and the iMac becomes a second display at its full native resolution (4096 × 2304 on the 4K model).

**Is this a Target Display Mode alternative?**
Yes, for Macs that do not have it. Apple's Target Display Mode does not cover the Retina 4K and 5K iMacs, and newer Macs do not have it at all. OpenAirDisplay works over the network or a cable, in software.

**Does it work over Wi-Fi?**
Yes, with quality that adapts automatically, but a cable (Thunderbolt or Ethernet) is far smoother at 4K. With AirDrop set to "Everyone", macOS periodically scans and can cause hitches; set it to Contacts Only.

**Why is 4K capped around 56 fps?**
Only on H.264 receivers: 4096 × 2304 at 60 fps exceeds H.264 Level 5.2, and level 6 streams black-screen the hardware decoder on Intel iMacs. "Smooth 4K 60" trades a little sharpness for a steady 60. HEVC receivers are not capped.

**Can I use an iPad, iPhone, Android phone, TV or Windows PC?**
Not yet; they are on the [roadmap](#roadmap).

**Can I play Netflix or other protected video on the extra screen?**
Play it on the extra Mac itself. macOS hides DRM-protected video from screen capture, exactly as with Sidecar and other display apps, so it shows black when mirrored.

**Why the purple recording indicator on my main Mac?**
macOS shows it whenever an app captures the screen. OpenAirDisplay captures only its own virtual display, and nothing is stored.

**Why isn't it on the Mac App Store?**
It relies on a private API (`CGVirtualDisplay`), which the App Store does not allow. It may break with a future macOS update.

**Can I use an Intel MacBook as the main Mac?**
It should work on macOS 13+, but it is untested. Reports welcome.

**Is the connection encrypted?**
Yes. Ed25519 identity keys are pinned at pairing, session keys come from X25519, and frames are sealed with AES-GCM. The pairing number is a short authentication string with a commit-reveal step, so someone in the middle can't pick keys that make the numbers match. This is a hobby project and has not had an independent security audit; see [SECURITY.md](SECURITY.md).

**Is it related to "Air Display" by Avatron?**
No. It is an independent project with a similar-sounding generic name.

## Limitations

- Private API; may break on new macOS releases.
- Protected (DRM) video shows black when captured.
- Input forwarding is basic: system shortcuts on the extra Mac (Cmd+Tab, Mission Control) stay local, and it needs Accessibility permission on the main Mac.
- The main Mac needs macOS 13+.
- Several extra screens work, but only the first one gets sound, and multi-screen has been tested in code, not yet with three real Macs.
- Not notarized.

## Privacy

No accounts, no analytics, no telemetry, no servers. Video, sound and input go directly between your two Macs, encrypted, and only to Macs you paired. The app stores your settings and the public keys of paired Macs on each Mac, nothing else. It makes no internet connections.

Permissions it asks for: **Screen Recording** (capture the virtual display it creates), **Local Network** (find your other Mac), **Accessibility** (only if you turn on keyboard and mouse from the extra screen), and **Notifications** (optional banners).

## Roadmap

| Platform | Status |
|---|---|
| macOS to macOS | **Available** |
| iPhone and iPad as the display | Coming soon |
| Android phones and tablets | Coming soon |
| TV | Coming soon |
| Windows | Coming soon |
| Notarized releases, Homebrew cask | Planned |

Want to help build one of these? Open an issue to coordinate first.

## Contributing

Issues and pull requests welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License and disclaimer

MIT. See [LICENSE](LICENSE). The software is provided "as is", without warranty of any kind, and you use it at your own risk; the author is not liable for any damage, data loss or hardware problems arising from its use.

OpenAirDisplay is not affiliated with or endorsed by Apple Inc., Astropad or Duet. Mac, macOS, iMac, MacBook, Thunderbolt, AirDrop, iPhone, iPad and Sidecar are trademarks of Apple Inc.; Luna Display is a trademark of Astropad; Duet Display is a trademark of its owner; other names belong to their owners.

## Credits

Made by [Sanan Goyal](https://sanangoyal.com).

<sub>Keywords: use old iMac as external display, iMac 2015 second monitor, Mac as second screen for MacBook, Target Display Mode alternative, extended display Mac to Mac, 4K external display from old Mac, wired and wireless second display macOS, MCP server for display control.</sub>
