#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/version.env"

DIST_ROOT="${DIST_DIR}"
if [[ "$DIST_ROOT" != /* ]]; then
  DIST_ROOT="$REPO_ROOT/$DIST_ROOT"
fi

APP_BUNDLE="$DIST_ROOT/${APP_NAME}.app"
ZIP_PATH="$DIST_ROOT/${APP_NAME}-${VERSION}-macOS.zip"
CLI_PATH="$DIST_ROOT/${CLI_PRODUCT}"
SIGN_COMPANION_CLI="${SIGN_COMPANION_CLI:-1}"

fatal() {
  echo "error: $*" >&2
  exit 1
}

print_available_codesigning_identities() {
  security find-identity -v -p codesigning 2>/dev/null || true
}

find_developer_id_application_identities() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application:/ { print $2 }'
}

resolve_sign_identity() {
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    return 0
  fi

  identities=()
  while IFS= read -r identity; do
    [[ -n "$identity" ]] && identities+=("$identity")
  done < <(find_developer_id_application_identities)

  case "${#identities[@]}" in
    0)
      echo "No Developer ID Application identity was found in the current keychain search list." >&2
      echo "Available signing identities:" >&2
      print_available_codesigning_identities >&2
      fatal "Install a Developer ID Application certificate or set SIGN_IDENTITY explicitly."
      ;;
    1)
      SIGN_IDENTITY="${identities[0]}"
      export SIGN_IDENTITY
      echo "==> Using detected Developer ID identity: $SIGN_IDENTITY"
      ;;
    *)
      echo "Multiple Developer ID Application identities were found:" >&2
      printf '  - %s\n' "${identities[@]}" >&2
      fatal "Set SIGN_IDENTITY to the exact identity you want to use."
      ;;
  esac
}

validate_sign_identity() {
  [[ -n "${SIGN_IDENTITY:-}" ]] || fatal "Set SIGN_IDENTITY to a Developer ID Application identity."

  if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    fatal "SIGN_IDENTITY must start with 'Developer ID Application:'. Current value: $SIGN_IDENTITY"
  fi

  if ! print_available_codesigning_identities | grep -F -- "\"$SIGN_IDENTITY\"" >/dev/null; then
    echo "Available signing identities:" >&2
    print_available_codesigning_identities >&2
    fatal "Signing identity not found in the keychain: $SIGN_IDENTITY"
  fi
}

validate_notary_profile() {
  [[ -n "${NOTARY_PROFILE:-}" ]] || fatal "Set NOTARY_PROFILE to an xcrun notarytool keychain profile."

  echo "==> Validating notary profile $NOTARY_PROFILE"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fatal "Notary profile '$NOTARY_PROFILE' is unavailable or invalid. Create/repair it with xcrun notarytool store-credentials."
  fi
}

sign_path() {
  local path="$1"
  local label="$2"

  echo "==> Signing $label"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$path"
  codesign --verify --strict --verbose=2 "$path"
}

resolve_sign_identity
validate_sign_identity
validate_notary_profile

ADHOC_SIGN=0 CREATE_ZIP=0 "$SCRIPT_DIR/package-macos-app.sh"

[[ -d "$APP_BUNDLE" ]] || fatal "Missing app bundle: $APP_BUNDLE"
sign_path "$APP_BUNDLE" "$APP_BUNDLE"

if [[ "$SIGN_COMPANION_CLI" == "1" && -x "$CLI_PATH" ]]; then
  sign_path "$CLI_PATH" "$CLI_PATH"
fi

echo "==> Creating notarization archive"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Submitting for notarization with profile $NOTARY_PROFILE"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_BUNDLE"

echo "==> Verifying notarized app"
spctl -a -vv "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Repacking stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Release-ready app: $APP_BUNDLE"
echo "Release-ready zip: $ZIP_PATH"
if [[ "$SIGN_COMPANION_CLI" == "1" && -x "$CLI_PATH" ]]; then
  echo "Signed companion CLI: $CLI_PATH"
fi
