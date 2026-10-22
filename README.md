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
- **Quality presets.** Auto, Ultra, Best, Balanced, Light, plus a "Smooth 4K 60" mode for 60 Hz panels.
- **Sound.** Optionally plays the main Mac's audio on the extra screen's speakers.
- **Wake-on-LAN.** Wake a sleeping extra screen from the menu or automatically.
- **One app, two roles.** Pick "Use another Mac as my display" or "Be the extra screen" at first launch. Change it any time in Settings.
- **Private.** Direct connection between your two Macs. No servers, no telemetry, no accounts. Pairing uses a one-time 10-character code; after that each Mac only talks to the Mac it paired with, and everything on the wire is encrypted.
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

Copy `~/Applications/AirDisplay.app` to the other Mac too (AirDrop, USB stick, anything). Because it is not notarized, macOS may block the first launch of the copy: right-click › Open, or run `xattr -cr AirDisplay.app`.

Tip: sign with a stable certificate so macOS keeps the Screen Recording permission across rebuilds:

```sh
SIGN_ID="My Local Signing" scripts/build.sh --install
```

## Set up

1. Open AirDisplay on the **extra screen** Mac and choose **Be the extra screen**. A pairing code appears.
2. Open AirDisplay on your **main Mac** and choose **Use another Mac as my display**. Follow the setup guide: allow Screen Recording, pick the other Mac, type the code.
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
4096×2304 at 60 fps exceeds H.264 Level 5.2, and level 6 streams black-screen the hardware decoder on Intel iMacs. "Native" mode caps at 56 fps to stay within the limit. "Smooth 4K 60" trades a little sharpness for a steady 60.

**Can I use an Intel MacBook as the main Mac?**
It should work on macOS 13+, but it is untested. Reports welcome.

**Is the connection encrypted?**
Yes. Ed25519 identity keys are pinned at pairing, session keys come from X25519, and frames are sealed with AES-GCM. This is a hobby project and has not had an independent security audit.

## Limitations

- Private API; may break on new macOS releases.
- The extra screen only shows pixels. You drive it with the main Mac's keyboard and mouse; input on the extra Mac itself is not forwarded.
- Sender needs macOS 13+.
- One extra screen at a time.
- Not notarized.

## Roadmap

HEVC option, hotkeys, keyboard and mouse forwarding, multiple screens, signed and notarized releases, Homebrew cask.

## Contributing

Issues and pull requests welcome. Source layout: `Sources/Sender` (main Mac), `Sources/Receiver` (extra screen), `Sources/Shared` (protocol, crypto, Wake-on-LAN).

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Apple.
