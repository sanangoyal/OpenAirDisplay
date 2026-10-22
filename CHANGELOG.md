# Changelog

## 3.2 (unreleased)

- Agent control: local MCP server (`AirDisplay --mcp`), `--ctl` command line, and a `diagnose` health report. Off by default; activity log in Settings.
- Per-receiver quality ladders (a slow extra screen no longer drags the others down).
- Only one copy of the app can run per Mac (two copies used to fight over the receiver).
- About: credits, privacy and legal notes. Added SECURITY.md, CONTRIBUTING.md, tests and CI.
- Code split into smaller files; compiler warnings fixed.

## 3.1

- New pairing: both Macs show a 6-digit number to compare (commit-and-reveal). The receiver offers itself; no code typing.
- HEVC when the receiver can decode it. Several extra screens at once.
- Keyboard and mouse from the extra screen (opt-in), hold Esc to leave.
- Reconnect after pause fixed (5 s connect timeout, watchdogs).
- One app with both roles; receiver settings window; menu bar icons per role.

## Earlier

Prototype releases built on a late-2015 iMac 4K and an Apple silicon MacBook.
