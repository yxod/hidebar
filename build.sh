#!/bin/bash
# Builds build/HideBar.app. `./build.sh install` also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/HideBar.app"

# Universal by default; ARCHS="arm64" builds one architecture (CI does, its Xcode chokes on universal builds).
read -r -a ARCH_LIST <<< "${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in "${ARCH_LIST[@]}"; do ARCH_FLAGS+=(--arch "$arch"); done

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HideBar" "$APP/Contents/MacOS/HideBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sparkle (updates) loads from Contents/Frameworks. Its XPC services are only for sandboxed apps.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"

# Sign with a Developer ID if the keychain has one: macOS then keeps the Accessibility permission across
# rebuilds. SIGN_IDENTITY overrides; "-" means ad-hoc. SIGN_TIMESTAMP=1 adds Apple's secure timestamp,
# which notarization requires (it needs the network, so day-to-day builds skip it).
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [ "${SIGN_TIMESTAMP:-0}" = "1" ]; then
    TIMESTAMP_FLAG="--timestamp"
else
    TIMESTAMP_FLAG="--timestamp=none"
fi
# Inside out: Sparkle's helpers, the framework, then the app.
sign() { codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP_FLAG" "$@"; }
sign "$FRAMEWORK/Versions/B/Autoupdate"
sign "$FRAMEWORK/Versions/B/Updater.app"
sign "$FRAMEWORK"
sign "$APP"
echo "Built $APP (signed: $SIGN_IDENTITY)"

if [ "${1:-}" = "install" ]; then
    osascript -e 'tell application id "dev.qweb.HideBar" to quit' >/dev/null 2>&1 || true
    rm -rf /Applications/HideBar.app
    cp -R "$APP" /Applications/HideBar.app
    echo "Installed /Applications/HideBar.app"
fi
