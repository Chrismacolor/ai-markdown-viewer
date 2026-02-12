#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

APP_NAME="AIMarkdownViewer"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SOURCE_FILE="$ROOT_DIR/Sources/AIMarkdownViewer/main.swift"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"

mkdir -p "$BIN_DIR" "$RESOURCES_DIR"

xcrun swiftc \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "$SOURCE_FILE" \
  -o "$BIN_DIR/$APP_NAME"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi
chmod +x "$BIN_DIR/$APP_NAME"

echo "Built $APP_DIR"
