#!/bin/zsh
# Builds build/OpenAirDisplay.app (if needed) and packs it into dist/OpenAirDisplay-<version>.dmg
# with an Applications shortcut and a short "Read me first" note.
set -e
cd "$(dirname $0)/.."
[ -d build/OpenAirDisplay.app ] || scripts/build.sh
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/OpenAirDisplay.app/Contents/Info.plist)
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE" dist
cp -R build/OpenAirDisplay.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'EOF'
OpenAirDisplay: use a second Mac as an extra screen.

1. Drag OpenAirDisplay into Applications.
2. First launch: macOS may say the app can't be checked for malware (it isn't notarized yet).
   Open System Settings > Privacy & Security, scroll down and click "Open Anyway".
   (or in Terminal: xattr -cr /Applications/OpenAirDisplay.app)
3. Choose what this Mac does:
   - "Be the extra screen" on the Mac you want to use as a monitor.
   - "Use another Mac as my display" on your main Mac (macOS 13 or later).
4. The main Mac offers to pair with the extra screen. Both Macs show the same 6-digit number: if they match, click Pair on each.

Both Macs need the same version of the app and the same network (or a cable between them).
EOF
OUT="dist/OpenAirDisplay-$V.dmg"; rm -f "$OUT"
hdiutil create -volname "OpenAirDisplay $V" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Created $OUT"
shasum -a 256 "$OUT"
