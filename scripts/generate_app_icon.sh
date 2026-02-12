#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

INPUT_ICON="${1:-$ROOT_DIR/Resources/AppIconSource.png}"
OUTPUT_ICNS="$ROOT_DIR/Resources/AppIcon.icns"

if [[ ! -f "$INPUT_ICON" ]]; then
  echo "Icon source file not found: $INPUT_ICON" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

make_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$INPUT_ICON" --out "$ICONSET_DIR/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
rm -rf "$TMP_DIR"

echo "Generated $OUTPUT_ICNS"
