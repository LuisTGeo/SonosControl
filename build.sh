#!/bin/bash
# Builds SonosControl.app — a menu-bar Sonos controller — by compiling the Swift
# sources directly and assembling a signed .app bundle (no SwiftPM).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SonosControl"
BUNDLE_ID="com.luist.sonoscontrol"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
TARGET="arm64-apple-macosx14.0"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

echo "==> Cleaning"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

echo "==> Compiling Swift sources"
swiftc \
  -O \
  -target "$TARGET" \
  -sdk "$SDK" \
  -o "$MACOS_DIR/$APP_NAME" \
  Sources/$APP_NAME/*.swift

echo "==> Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Agent app: lives in the menu bar only, no Dock icon. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Needed to discover and control speakers on the LAN. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>SonosControl finds and controls your Sonos speakers on your local network.</string>
</dict>
</plist>
PLIST

echo "==> Codesigning"
# Stable self-signed identity so the Local Network grant persists across
# rebuilds; falls back to ad-hoc if the identity can't be created.
SIGN_IDENTITY="SonosControl Self-Signed"
./scripts/setup-signing.sh || true
if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
    echo "    signed with '$SIGN_IDENTITY' (grant persists across rebuilds)"
else
    echo "    identity unavailable; falling back to ad-hoc (grant resets each rebuild)"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Done: $APP_DIR"
