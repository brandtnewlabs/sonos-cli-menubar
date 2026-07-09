#!/bin/zsh
# Builds SonosBar and wraps the bare SwiftPM binary into a proper SonosBar.app.
#
# SwiftPM produces an executable, not an .app. Without an Info.plist carrying
# LSUIElement the process claims a Dock icon, and MenuBarExtra(.window) has focus
# quirks when run unbundled — so the real app must live in a bundle.
#
# Usage:  ./Scripts/bundle.sh          # build + bundle into ./SonosBar.app
#         ./Scripts/bundle.sh --open   # also launch it
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SonosBar"
BUNDLE_ID="sh.sonoscli.sonosbar"
VERSION="1.0.0"
APP_DIR="${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesign"
codesign --force --sign - "${APP_DIR}" || echo "warning: codesign failed (continuing unsigned)"

echo "==> Done: ${APP_DIR}"
echo "    Move it to /Applications and launch, or run: open ${APP_DIR}"

if [[ "${1:-}" == "--open" ]]; then
    open "${APP_DIR}"
fi
