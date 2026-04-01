#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/version.env"

OUTPUT_PATH="${1:-$REPO_ROOT/dist/generated/AppIcon.icns}"
ICON_SOURCE="${APP_ICON_MASTER_SVG:-$REPO_ROOT/Packaging/AppIcon.master.svg}"

if [[ ! -f "$REPO_ROOT/$ICON_SOURCE" && -f "$ICON_SOURCE" ]]; then
  ICON_SOURCE="$ICON_SOURCE"
elif [[ -f "$REPO_ROOT/$ICON_SOURCE" ]]; then
  ICON_SOURCE="$REPO_ROOT/$ICON_SOURCE"
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing icon source: $ICON_SOURCE" >&2
  exit 1
fi

render_svg() {
  local size="$1"
  local output_png="$2"

  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert --width "$size" --height "$size" "$ICON_SOURCE" --output "$output_png"
    return 0
  fi

  if command -v magick >/dev/null 2>&1; then
    magick -background none "$ICON_SOURCE" -resize "${size}x${size}" "$output_png"
    return 0
  fi

  echo "Need either rsvg-convert or magick to render $ICON_SOURCE" >&2
  exit 1
}

mkdir -p "$(dirname "$OUTPUT_PATH")"
TMP_DIR="$(mktemp -d)"
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

pairs=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for pair in "${pairs[@]}"; do
  filename="${pair%%:*}"
  size="${pair##*:}"
  render_svg "$size" "$ICONSET_DIR/$filename"
done

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_PATH"
echo "Created $OUTPUT_PATH"
