#!/usr/bin/env bash
set -euo pipefail

VERSION="${PASSSYNC_VERSION:-$(sed -n 's/.*current = "\(.*\)"/\1/p' Sources/PassSyncCore/PassSyncVersion.swift)}"
OUTPUT_ROOT="${1:-.build/release-artifacts}"
WORK_DIR="$OUTPUT_ROOT/passsync-$VERSION"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/docs"

swift build --configuration release --product passsync
swift build --configuration release --product PassSyncApp

APP_PATH="$(Scripts/package_app.sh release)"
BIN_DIR="$(swift build --show-bin-path --configuration release)"

cp "$BIN_DIR/passsync" "$WORK_DIR/bin/passsync"
cp -R "$APP_PATH" "$WORK_DIR/PassSync.app"
cp README.md LICENSE SECURITY.md "$WORK_DIR/"
cp -R docs "$WORK_DIR/docs/project-docs"

(
  cd "$OUTPUT_ROOT"
  tar -czf "passsync-$VERSION-macos-unsigned.tar.gz" "passsync-$VERSION"
  shasum -a 256 "passsync-$VERSION-macos-unsigned.tar.gz" > "passsync-$VERSION-macos-unsigned.tar.gz.sha256"
)

echo "$OUTPUT_ROOT/passsync-$VERSION-macos-unsigned.tar.gz"
echo "$OUTPUT_ROOT/passsync-$VERSION-macos-unsigned.tar.gz.sha256"
