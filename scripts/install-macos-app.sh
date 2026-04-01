#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/version.env"

DIST_ROOT="${DIST_DIR}"
if [[ "$DIST_ROOT" != /* ]]; then
  DIST_ROOT="$REPO_ROOT/$DIST_ROOT"
fi

INSTALL_ROOT="${INSTALL_APPLICATIONS_DIR:-/Applications}"
if [[ "$INSTALL_ROOT" != /* ]]; then
  INSTALL_ROOT="$REPO_ROOT/$INSTALL_ROOT"
fi

OPEN_APP="${OPEN_APP:-1}"
APP_BUNDLE="$DIST_ROOT/${APP_NAME}.app"
DEST_APP="$INSTALL_ROOT/${APP_NAME}.app"
DEST_CLI="$DEST_APP/Contents/MacOS/${CLI_PRODUCT}"

fatal() {
  echo "error: $*" >&2
  exit 1
}

if [[ -e "$DEST_APP" ]]; then
  if [[ ! -w "$DEST_APP" ]]; then
    fatal "No write access to $DEST_APP. Re-run as a user who can update it or set INSTALL_APPLICATIONS_DIR=~/Applications."
  fi
else
  mkdir -p "$INSTALL_ROOT" 2>/dev/null || true
  if [[ ! -d "$INSTALL_ROOT" ]]; then
    fatal "Install destination does not exist and could not be created: $INSTALL_ROOT"
  fi
  if [[ ! -w "$INSTALL_ROOT" ]]; then
    fatal "No write access to $INSTALL_ROOT. Re-run as a user who can write there or set INSTALL_APPLICATIONS_DIR=~/Applications."
  fi
fi

"$SCRIPT_DIR/package-macos-app.sh"

[[ -d "$APP_BUNDLE" ]] || fatal "Missing packaged app bundle: $APP_BUNDLE"

echo "==> Installing $APP_NAME to $DEST_APP"
mkdir -p "$DEST_APP"
rsync -a --delete "$APP_BUNDLE/" "$DEST_APP/"

if ! codesign --verify --deep --strict --verbose=2 "$DEST_APP" >/dev/null 2>&1; then
  fatal "Installed app failed codesign verification: $DEST_APP"
fi

echo "Installed app: $DEST_APP"
echo "Bundled CLI: $DEST_CLI"
echo "Symlink it into your PATH with something like:"
echo "  ln -sf \"$DEST_CLI\" /usr/local/bin/${CLI_PRODUCT}"

if [[ "$OPEN_APP" == "1" ]]; then
  open "$DEST_APP"
fi
