#!/bin/zsh
# Builds build/AirDisplay.app (if needed) and packs it into dist/AirDisplay-<version>.dmg
# with an Applications shortcut and a short "Read me first" note.
set -e
cd "$(dirname $0)/.."
[ -d build/AirDisplay.app ] || scripts/build.sh
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/AirDisplay.app/Contents/Info.plist)
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE" dist
cp -R build/AirDisplay.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'EOF'
AirDisplay: use a second Mac as an extra screen.

1. Drag AirDisplay into Applications.
2. First launch: macOS may say the app can't be checked for malware (it isn't notarized yet).
   Right-click AirDisplay > Open > Open.   (or in Terminal: xattr -cr /Applications/AirDisplay.app)
3. Choose what this Mac does:
   - "Be the extra screen" on the Mac you want to use as a monitor.
   - "Use another Mac as my display" on your main Mac (macOS 13 or later).
4. On the extra screen a pairing code appears. On the main Mac pick the extra screen's name and type the code.

Both Macs need the same version of the app and the same network (or a cable between them).
EOF
OUT="dist/AirDisplay-$V.dmg"; rm -f "$OUT"
hdiutil create -volname "AirDisplay $V" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Created $OUT"
shasum -a 256 "$OUT"
