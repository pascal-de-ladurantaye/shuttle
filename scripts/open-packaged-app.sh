#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/version.env"

DIST_ROOT="$DIST_DIR"
if [[ "$DIST_ROOT" != /* ]]; then
  DIST_ROOT="$REPO_ROOT/$DIST_ROOT"
fi

"$SCRIPT_DIR/package-macos-app.sh"
open "$DIST_ROOT/${APP_NAME}.app"
