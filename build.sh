#!/bin/bash
# Builds build/HideBar.app. `./build.sh install` also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/HideBar.app"

swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HideBar" "$APP/Contents/MacOS/HideBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with a Developer ID if the keychain has one: macOS then keeps the Accessibility permission across
# rebuilds. SIGN_IDENTITY overrides; "-" means ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP"
echo "Built $APP (signed: $SIGN_IDENTITY)"

if [ "${1:-}" = "install" ]; then
    osascript -e 'tell application id "dev.qweb.HideBar" to quit' >/dev/null 2>&1 || true
    rm -rf /Applications/HideBar.app
    cp -R "$APP" /Applications/HideBar.app
    echo "Installed /Applications/HideBar.app"
fi
