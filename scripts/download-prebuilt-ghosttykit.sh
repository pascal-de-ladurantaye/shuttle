#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pinned GhosttyKit build from manaflow-ai/ghostty fork
GHOSTTY_SHA="${GHOSTTY_SHA:-bc9be90a21997a4e5f06bf15ae2ec0f937c2dc42}"
EXPECTED_SHA256="${GHOSTTYKIT_SHA256:-6b83b66768e8bba871a3753ae8ffbaabd03370b306c429cd86c9cdcc8db82589}"

TAG="xcframework-$GHOSTTY_SHA"
ARCHIVE_NAME="GhosttyKit.xcframework.tar.gz"
DOWNLOAD_URL="${GHOSTTYKIT_URL:-https://github.com/manaflow-ai/ghostty/releases/download/$TAG/$ARCHIVE_NAME}"
OUTPUT_DIR="$REPO_ROOT/Vendor/GhosttyKit.xcframework"

patch_modulemap() {
    local modulemap_path="$1"

    cat > "$modulemap_path" <<'EOF'
module GhosttyKit {
    umbrella header "ghostty.h"
    exclude header "ghostty/vt.h"
    exclude header "ghostty/vt/allocator.h"
    exclude header "ghostty/vt/color.h"
    exclude header "ghostty/vt/key.h"
    exclude header "ghostty/vt/key/encoder.h"
    exclude header "ghostty/vt/key/event.h"
    exclude header "ghostty/vt/osc.h"
    exclude header "ghostty/vt/paste.h"
    exclude header "ghostty/vt/result.h"
    exclude header "ghostty/vt/sgr.h"
    exclude header "ghostty/vt/wasm.h"
    export *
}
EOF
}

postprocess_xcframework() {
    local xcframework_dir="$1"

    echo "==> Post-processing GhosttyKit.xcframework"
    echo "    - Patching module maps to suppress umbrella-header warnings"
    echo "    - Stripping vendored archive debug info to suppress dsymutil warnings"

    while IFS= read -r -d '' modulemap_path; do
        patch_modulemap "$modulemap_path"
    done < <(find "$xcframework_dir" -path '*/Headers/module.modulemap' -print0)

    while IFS= read -r -d '' archive_path; do
        strip -S "$archive_path"
    done < <(find "$xcframework_dir" -type f \( -name 'libghostty.a' -o -name 'libghostty-fat.a' \) -print0)
}

echo "==> Downloading GhosttyKit.xcframework for ghostty $GHOSTTY_SHA"
echo "    URL: $DOWNLOAD_URL"

cd "$REPO_ROOT"

if [ -d "$OUTPUT_DIR" ]; then
    echo "==> GhosttyKit.xcframework already exists at $OUTPUT_DIR"
    echo "    Skipping download and reapplying local post-processing."
    postprocess_xcframework "$OUTPUT_DIR"
    echo ""
    echo "==> GhosttyKit is ready. Build the app with:"
    echo "    swift build"
    exit 0
fi

curl --fail --show-error --location \
    --retry 3 \
    --retry-delay 5 \
    --retry-all-errors \
    -o "$ARCHIVE_NAME" \
    "$DOWNLOAD_URL"

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_NAME" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "✗ Checksum mismatch!" >&2
    echo "  Expected: $EXPECTED_SHA256" >&2
    echo "  Actual:   $ACTUAL_SHA256" >&2
    rm -f "$ARCHIVE_NAME"
    exit 1
fi

echo "✓ Checksum verified"

mkdir -p "$(dirname "$OUTPUT_DIR")"
rm -rf "$OUTPUT_DIR"
tar xzf "$ARCHIVE_NAME" -C Vendor/
rm "$ARCHIVE_NAME"

if [ -d "$OUTPUT_DIR" ]; then
    echo "✓ Extracted to $OUTPUT_DIR"
    postprocess_xcframework "$OUTPUT_DIR"
else
    echo "✗ Extraction failed — expected $OUTPUT_DIR" >&2
    exit 1
fi

echo ""
echo "==> GhosttyKit is ready. Build the app with:"
echo "    swift build"
