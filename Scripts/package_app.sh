#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
VERSION="${PASSSYNC_VERSION:-$(sed -n 's/.*current = "\(.*\)"/\1/p' Sources/PassSyncCore/PassSyncVersion.swift)}"
BUILD_NUMBER="${PASSSYNC_BUILD_NUMBER:-1}"

swift build --product PassSyncApp -c "$CONFIGURATION" >&2
BIN_DIR="$(swift build --show-bin-path -c "$CONFIGURATION")"
APP_DIR="$BIN_DIR/PassSync.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/PassSyncApp" "$MACOS_DIR/PassSync"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>PassSync</string>
  <key>CFBundleIdentifier</key>
  <string>com.leonardwongly.PassSync</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PassSync</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/PassSync"
echo "$APP_DIR"
