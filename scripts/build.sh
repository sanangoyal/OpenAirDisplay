#!/bin/zsh
# Builds a universal (Intel + Apple silicon) AirDisplay.app for macOS 12+.
# Needs only the Xcode Command Line Tools (xcode-select --install).
#
# Usage:  scripts/build.sh [--install]
# Env:    SIGN_ID   codesign identity. Default "-" (ad-hoc). Use a stable certificate
#                   (e.g. a self-made "AirDisplay Local Signing") so macOS keeps the
#                   Screen Recording permission between rebuilds.
set -e
cd "$(dirname $0)/.."
APP="AirDisplay.app"; OUT="build"; SIGN_ID="${SIGN_ID:--}"
rm -rf "$OUT"; mkdir -p "$OUT/$APP/Contents/MacOS" "$OUT/$APP/Contents/Resources" "$OUT/tmp"

SRC=(Sources/main.swift Sources/Role.swift Sources/Receiver/*.swift Sources/Sender/*.swift Sources/Shared/*.swift)
FW=(-framework Cocoa -framework AVFoundation -framework VideoToolbox -framework Network
    -framework UserNotifications -framework SwiftUI -framework ServiceManagement
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit -Xlinker -weak_framework -Xlinker Charts)

# The Command Line Tools ship no x86_64 Swift back-deployment shims; provide empty ones.
echo 'char _swift_FORCE_LOAD_$_swiftCompatibility56 = 0; char _swift_FORCE_LOAD_$_swiftCompatibilityPacks = 0; char _swift_FORCE_LOAD_$_swiftCompatibility51 = 0; char _swift_FORCE_LOAD_$_swiftCompatibilityDynamicReplacements = 0, _swift_FORCE_LOAD_$_swiftCompatibilityConcurrency = 0;' > "$OUT/tmp/stub.c"
clang -target x86_64-apple-macos12.0 -c "$OUT/tmp/stub.c" -o "$OUT/tmp/stub-x86.o"

swiftc -O -target x86_64-apple-macos12.0 -import-objc-header Sources/bridge.h $SRC "$OUT/tmp/stub-x86.o" -o "$OUT/tmp/x86" $FW
swiftc -O -target arm64-apple-macos12.0  -import-objc-header Sources/bridge.h $SRC -o "$OUT/tmp/arm" $FW
lipo -create "$OUT/tmp/x86" "$OUT/tmp/arm" -output "$OUT/$APP/Contents/MacOS/AirDisplay"
cp Sources/Info.plist "$OUT/$APP/Contents/Info.plist"
cp branding/AppIcon.icns "$OUT/$APP/Contents/Resources/"
codesign --force -s "$SIGN_ID" --identifier com.sanan.airdisplay "$OUT/$APP"
rm -rf "$OUT/tmp"
echo "Built $OUT/$APP"

if [ "$1" = "--install" ]; then
  mkdir -p ~/Applications; rm -rf ~/Applications/"$APP"; cp -R "$OUT/$APP" ~/Applications/
  echo "Installed to ~/Applications/$APP"
fi
