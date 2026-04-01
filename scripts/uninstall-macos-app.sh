#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/version.env"

expand_user_path() {
  local path="$1"
  case "$path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    ~/*)
      printf '%s/%s\n' "$HOME" "${path#~/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

resolve_path() {
  local path
  path="$(expand_user_path "$1")"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$REPO_ROOT/$path"
  fi
}

INSTALL_ROOT="$(resolve_path "${INSTALL_APPLICATIONS_DIR:-/Applications}")"
APP_BUNDLE="$INSTALL_ROOT/${APP_NAME}.app"
APP_SUPPORT_DIR="$(resolve_path "${SHUTTLE_APP_SUPPORT_DIR:-$SHUTTLE_DEFAULT_APP_SUPPORT_DIR}")"
CONFIG_DIR="$(resolve_path "${SHUTTLE_CONFIG_DIR:-$SHUTTLE_DEFAULT_CONFIG_DIR}")"
PREFERENCES_PLIST="$(resolve_path "${SHUTTLE_PREFERENCES_PLIST:-$SHUTTLE_DEFAULT_PREFERENCES_PLIST}")"
SAVED_STATE_DIR="$(resolve_path "${SHUTTLE_SAVED_STATE_DIR:-$SHUTTLE_DEFAULT_SAVED_STATE_DIR}")"
CACHE_DIR="$(resolve_path "${SHUTTLE_CACHE_DIR:-$SHUTTLE_DEFAULT_CACHE_DIR}")"
DELETE_APP_DATA_MODE="${DELETE_APP_DATA:-ask}"
QUIT_RUNNING_APP_MODE="${QUIT_RUNNING_APP:-auto}"

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local reply

  if [[ ! -t 0 ]]; then
    return 1
  fi

  read -r -p "$prompt" reply
  reply="${reply:-$default_answer}"
  [[ "$reply" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

remove_path() {
  local path="$1"
  if [[ -d "$path" && ! -L "$path" ]]; then
    rm -rf -- "$path"
  else
    rm -f -- "$path"
  fi
}

should_quit_running_app() {
  case "$QUIT_RUNNING_APP_MODE" in
    1|true|TRUE|yes|YES|y|Y)
      return 0
      ;;
    0|false|FALSE|no|NO|n|N)
      return 1
      ;;
    auto|AUTO|"")
      [[ "$INSTALL_ROOT" == "/Applications" || "$INSTALL_ROOT" == "$HOME/Applications" ]]
      return
      ;;
    *)
      echo "warning: unknown QUIT_RUNNING_APP value '$QUIT_RUNNING_APP_MODE'; treating it as 'auto'" >&2
      [[ "$INSTALL_ROOT" == "/Applications" || "$INSTALL_ROOT" == "$HOME/Applications" ]]
      return
      ;;
  esac
}

quit_running_app_if_needed() {
  if should_quit_running_app; then
    echo "==> Quitting $APP_NAME if it is running"
    osascript >/dev/null 2>&1 <<EOF || true
ignoring application responses
  tell application id "$BUNDLE_ID" to quit
end ignoring
EOF
    sleep 1
  else
    echo "==> Skipping running-app quit for nonstandard install root: $INSTALL_ROOT"
  fi
}

existing_data_paths=()
for candidate in "$APP_SUPPORT_DIR" "$CONFIG_DIR" "$PREFERENCES_PLIST" "$SAVED_STATE_DIR" "$CACHE_DIR"; do
  if [[ -e "$candidate" ]]; then
    existing_data_paths+=("$candidate")
  fi
done

quit_running_app_if_needed

if [[ -e "$APP_BUNDLE" ]]; then
  echo "==> Removing installed app $APP_BUNDLE"
  remove_path "$APP_BUNDLE"
else
  echo "==> No installed app found at $APP_BUNDLE"
fi

should_delete_app_data=0
case "$DELETE_APP_DATA_MODE" in
  1|true|TRUE|yes|YES|y|Y)
    should_delete_app_data=1
    ;;
  0|false|FALSE|no|NO|n|N)
    should_delete_app_data=0
    ;;
  ask|ASK|prompt|PROMPT|"")
    if [[ ${#existing_data_paths[@]} -gt 0 ]]; then
      echo ""
      echo "$APP_NAME app data found at:"
      printf '  - %s\n' "${existing_data_paths[@]}"
      echo ""
      echo "This removes $APP_NAME config, Application Support state, preferences, saved state, and caches."
      echo "It does NOT remove session roots under your configured session_root."
      if prompt_yes_no "Delete this Shuttle app data too? [y/N] " "N"; then
        should_delete_app_data=1
      fi
    fi
    ;;
  *)
    echo "warning: unknown DELETE_APP_DATA value '$DELETE_APP_DATA_MODE'; treating it as 'ask'" >&2
    if [[ ${#existing_data_paths[@]} -gt 0 ]] && prompt_yes_no "Delete this Shuttle app data too? [y/N] " "N"; then
      should_delete_app_data=1
    fi
    ;;
esac

if [[ $should_delete_app_data -eq 1 ]]; then
  echo "==> Removing Shuttle app data"
  for candidate in "$APP_SUPPORT_DIR" "$CONFIG_DIR" "$PREFERENCES_PLIST" "$SAVED_STATE_DIR" "$CACHE_DIR"; do
    if [[ -e "$candidate" ]]; then
      echo "   removed $candidate"
      remove_path "$candidate"
    fi
  done
else
  echo "==> Keeping Shuttle app data"
fi

echo "Uninstall complete."
