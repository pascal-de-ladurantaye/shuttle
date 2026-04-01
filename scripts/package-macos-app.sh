#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/version.env"

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$REPO_ROOT/$path"
  fi
}

CONFIGURATION="${CONFIGURATION:-release}"
CREATE_ZIP="${CREATE_ZIP:-1}"
BUILD_ICON="${BUILD_ICON:-1}"
ADHOC_SIGN="${ADHOC_SIGN:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
DIST_ROOT="$(resolve_path "${DIST_DIR:-dist/macos}")"
RESOURCE_BUNDLE_NAME="${SPM_PACKAGE_NAME}_${SPM_APP_PRODUCT}.bundle"
APP_BUNDLE="$DIST_ROOT/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ZIP_PATH="$DIST_ROOT/${APP_NAME}-${VERSION}-macOS.zip"
LEGACY_COMPANION_CLI_PATH="$DIST_ROOT/${CLI_PRODUCT}"
BUNDLED_CLI_PATH="$MACOS/${CLI_PRODUCT}"
ICON_PATH="$RESOURCES/AppIcon.icns"

embed_ghostty_resources() {
  local resources_root="$GHOSTTY_APP_RESOURCES_DIR"

  if [[ "$EMBED_GHOSTTY_RESOURCES" == "0" ]]; then
    echo "==> Skipping embedded Ghostty resources"
    return 0
  fi

  if [[ -d "$resources_root/ghostty" && -d "$resources_root/terminfo" ]]; then
    echo "==> Embedding Ghostty runtime resources from $resources_root"
    rsync -a "$resources_root/ghostty" "$RESOURCES/"
    rsync -a "$resources_root/terminfo" "$RESOURCES/"
    return 0
  fi

  if [[ "$EMBED_GHOSTTY_RESOURCES" == "1" ]]; then
    echo "Ghostty runtime resources requested but not found at $resources_root" >&2
    exit 1
  fi

  echo "==> Ghostty runtime resources not embedded (looked in $resources_root)"
  echo "    Packaged Shuttle will fall back to /Applications/Ghostty.app at runtime when available."
}

generate_info_plist() {
  local icon_block=""
  if [[ -f "$ICON_PATH" ]]; then
    icon_block=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n'
  fi

  cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${SPM_APP_PRODUCT}</string>
${icon_block}    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>ShuttleProfile</key>
    <string>${SHUTTLE_PROFILE}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>${APP_CATEGORY}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

  plutil -lint "$CONTENTS/Info.plist" >/dev/null
}

mkdir -p "$DIST_ROOT"
rm -rf "$APP_BUNDLE"
rm -f "$ZIP_PATH" "$LEGACY_COMPANION_CLI_PATH"
mkdir -p "$MACOS" "$RESOURCES"

echo "==> Building $APP_NAME ($CONFIGURATION, profile: $SHUTTLE_PROFILE)"
(
  cd "$REPO_ROOT"
  swift build -c "$CONFIGURATION"
)

BIN_DIR="$(cd "$REPO_ROOT" && swift build -c "$CONFIGURATION" --show-bin-path)"
APP_BINARY="$BIN_DIR/$SPM_APP_PRODUCT"
CLI_BINARY="$BIN_DIR/$CLI_PRODUCT"
RESOURCE_BUNDLE_PATH="$BIN_DIR/$RESOURCE_BUNDLE_NAME"

copy_shell_integration_resources() {
  local source_dir="$REPO_ROOT/Sources/$SPM_APP_PRODUCT/Resources/shell-integration"
  local resource_bundle_dir="$RESOURCE_BUNDLE_PATH/Resources/shell-integration"
  local destination_dir="$RESOURCES/shell-integration"

  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"

  # Prefer the checked-in resources so packaging preserves the directory layout
  # and zsh shim dotfiles. SwiftPM's processed resource bundle can flatten this
  # directory and omit dotfiles, which breaks install packaging.
  if [[ -d "$source_dir" ]]; then
    echo "==> Copying shell integration resources from $source_dir"
    rsync -a "$source_dir/" "$destination_dir/"
    return 0
  fi

  if [[ -d "$resource_bundle_dir" ]]; then
    echo "==> Copying shell integration resources from $resource_bundle_dir"
    rsync -a "$resource_bundle_dir/" "$destination_dir/"
    return 0
  fi

  if [[ -d "$RESOURCE_BUNDLE_PATH" ]] \
    && [[ -f "$RESOURCE_BUNDLE_PATH/shuttle-bash-integration.bash" ]] \
    && [[ -f "$RESOURCE_BUNDLE_PATH/shuttle-zsh-integration.zsh" ]]; then
    echo "==> Copying shell integration scripts from flattened SwiftPM resource bundle"
    rsync -a \
      "$RESOURCE_BUNDLE_PATH/shuttle-bash-integration.bash" \
      "$RESOURCE_BUNDLE_PATH/shuttle-zsh-integration.zsh" \
      "$destination_dir/"
    echo "warning: SwiftPM flattened shell integration resources; zsh shim dotfiles were not present in the build output." >&2
    return 0
  fi

  echo "Missing shell integration resources. Checked:" >&2
  echo "  $source_dir" >&2
  echo "  $resource_bundle_dir" >&2
  echo "  $RESOURCE_BUNDLE_PATH" >&2
  return 1
}

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Missing app binary: $APP_BINARY" >&2
  exit 1
fi

if [[ ! -x "$CLI_BINARY" ]]; then
  echo "Missing CLI binary: $CLI_BINARY" >&2
  exit 1
fi

echo "==> Assembling $APP_BUNDLE"
cp "$APP_BINARY" "$MACOS/$SPM_APP_PRODUCT"
cp "$CLI_BINARY" "$BUNDLED_CLI_PATH"
copy_shell_integration_resources

if [[ "$BUILD_ICON" == "1" ]]; then
  echo "==> Building app icon"
  "$SCRIPT_DIR/build-macos-app-icon.sh" "$ICON_PATH"
fi

generate_info_plist
embed_ghostty_resources

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing bundled CLI with $SIGN_IDENTITY"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$BUNDLED_CLI_PATH"
  echo "==> Signing app with $SIGN_IDENTITY"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
elif [[ "$ADHOC_SIGN" == "1" ]]; then
  echo "==> Ad-hoc signing bundled CLI"
  codesign --force --sign - "$BUNDLED_CLI_PATH"
  echo "==> Ad-hoc signing app bundle"
  codesign --force --sign - "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
fi

if [[ "$CREATE_ZIP" == "1" ]]; then
  echo "==> Creating $ZIP_PATH"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
fi

echo ""
echo "Created macOS app bundle: $APP_BUNDLE"
echo "Bundled CLI:              $BUNDLED_CLI_PATH"
if [[ "$CREATE_ZIP" == "1" ]]; then
  echo "Zip archive:               $ZIP_PATH"
fi
