#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/tmp/cli-app-smoke/$RUN_ID}"
LOG_FILE="$RESULTS_DIR/run.log"
SUMMARY_FILE="$RESULTS_DIR/summary.txt"
START_DELAY_SECONDS="${START_DELAY_SECONDS:-5}"
STEP_PAUSE_SECONDS="${STEP_PAUSE_SECONDS:-2}"

mkdir -p "$RESULTS_DIR"
: > "$LOG_FILE"

PROFILE="${SHUTTLE_PROFILE:-prod}"
ORIGINAL_WORKSPACE_ID="${SHUTTLE_WORKSPACE_ID:-}"
ORIGINAL_SESSION_ID="${SHUTTLE_SESSION_ID:-}"
ORIGINAL_PANE_ID="${SHUTTLE_PANE_ID:-}"
ORIGINAL_TAB_ID="${SHUTTLE_TAB_ID:-}"
CURRENT_PROJECT_ID="${SHUTTLE_PROJECT_ID:-}"
CURRENT_PROJECT_NAME="${SHUTTLE_PROJECT_NAME:-}"

RESTORE_ON_EXIT=1
SHUTTLE_BIN="${SHUTTLE_BIN:-shuttle}"
SHUTTLE_BIN_RESOLVED=""

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE" >&2
}

cmd_string() {
  local out arg quoted
  printf -v out '%q' "$SHUTTLE_BIN_RESOLVED"
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    out="$out $quoted"
  done
  printf -v quoted '%q' --json
  out="$out $quoted"
  printf '%s\n' "$out"
}

restore_original_ui() {
  if [[ "$RESTORE_ON_EXIT" != "1" ]]; then
    return
  fi

  if [[ -n "$ORIGINAL_WORKSPACE_ID" && -n "$ORIGINAL_SESSION_ID" && -n "$SHUTTLE_BIN_RESOLVED" ]]; then
    log
    log "[cleanup] attempting to restore original Shuttle UI: $ORIGINAL_WORKSPACE_ID / $ORIGINAL_SESSION_ID"
    "$SHUTTLE_BIN_RESOLVED" workspace open "$ORIGINAL_WORKSPACE_ID" >/dev/null 2>&1 || true
    "$SHUTTLE_BIN_RESOLVED" session open "$ORIGINAL_SESSION_ID" >/dev/null 2>&1 || true
  fi
}

trap restore_original_ui EXIT

assert_envelope() {
  local file="$1"
  local expected_type="$2"
  python3 - "$file" "$expected_type" <<'PY'
import json
import sys

path, expected_type = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    obj = json.load(fh)

if obj.get('schema_version') != 2:
    raise SystemExit(f"Expected schema_version=2 in {path}, got {obj.get('schema_version')!r}")
if obj.get('ok') is not True:
    raise SystemExit(f"Expected ok=true in {path}, got {obj.get('ok')!r}")
if obj.get('type') != expected_type:
    raise SystemExit(f"Expected type={expected_type!r} in {path}, got {obj.get('type')!r}")
if 'data' not in obj:
    raise SystemExit(f"Missing top-level 'data' in {path}")
PY
}

json_get() {
  local file="$1"
  local expression="$2"
  python3 - "$file" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    obj = json.load(fh)

namespace = {"__builtins__": {}, "obj": obj, "len": len, "any": any, "all": all, "abs": abs, "set": set}
value = eval(expression, namespace, namespace)

if isinstance(value, bool):
    print('true' if value else 'false')
elif value is None:
    print('')
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(value)
PY
}

assert_py() {
  local file="$1"
  local expression="$2"
  local message="$3"
  python3 - "$file" "$expression" "$message" <<'PY'
import json
import sys

path, expression, message = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as fh:
    obj = json.load(fh)

namespace = {"__builtins__": {}, "obj": obj, "len": len, "any": any, "all": all, "abs": abs, "set": set}
ok = bool(eval(expression, namespace, namespace))
if not ok:
    raise SystemExit(f"Assertion failed: {message}\n  file={path}\n  expression={expression}")
PY
}

assert_text_contains() {
  local file="$1"
  local expression="$2"
  local needle="$3"
  local message="$4"
  python3 - "$file" "$expression" "$needle" "$message" <<'PY'
import json
import sys

path, expression, needle, message = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, 'r', encoding='utf-8') as fh:
    obj = json.load(fh)

namespace = {"__builtins__": {}, "obj": obj, "len": len, "any": any, "all": all, "abs": abs, "set": set}
text = eval(expression, namespace, namespace)
if needle not in (text or ""):
    raise SystemExit(f"Assertion failed: {message}\n  file={path}\n  missing_text={needle!r}")
PY
}

run_shuttle_json() {
  local label="$1"
  local expected_type="$2"
  shift 2

  local file="$RESULTS_DIR/${label}.json"
  log "+ $(cmd_string "$@")"

  if "$SHUTTLE_BIN_RESOLVED" "$@" --json > "$file"; then
    :
  else
    local status=$?
    log "error: command failed with exit $status: $(cmd_string "$@")"
    if [[ -s "$file" ]]; then
      log "note: partial stdout was written to $file"
    fi
    return "$status"
  fi

  if [[ ! -s "$file" ]]; then
    log "error: command produced no JSON output: $(cmd_string "$@")"
    return 1
  fi

  assert_envelope "$file" "$expected_type"
  printf '%s\n' "$file"
}

run_shuttle_json_retry() {
  local attempts="$1"
  local delay_seconds="$2"
  local label="$3"
  local expected_type="$4"
  shift 4

  local attempt=1
  local file
  while true; do
    if file=$(run_shuttle_json "$label" "$expected_type" "$@"); then
      printf '%s\n' "$file"
      return 0
    fi

    local status=$?
    if (( attempt >= attempts )); then
      return "$status"
    fi

    log "retry: command failed; retrying in ${delay_seconds}s (${attempt}/${attempts})"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

observe() {
  local message="$1"
  local seconds="${2:-$STEP_PAUSE_SECONDS}"
  log "[observe ${seconds}s] $message"
  sleep "$seconds"
}

if [[ -z "$ORIGINAL_WORKSPACE_ID" || -z "$ORIGINAL_SESSION_ID" || -z "$ORIGINAL_TAB_ID" ]]; then
  log "error: run this from inside a Shuttle shell session (missing SHUTTLE_WORKSPACE_ID / SHUTTLE_SESSION_ID / SHUTTLE_TAB_ID)."
  exit 1
fi

if ! SHUTTLE_BIN_RESOLVED="$(command -v "$SHUTTLE_BIN" 2>/dev/null)"; then
  log "error: could not find '$SHUTTLE_BIN' on PATH"
  log "hint: install/symlink the packaged Shuttle CLI first, or run with SHUTTLE_BIN=/absolute/path/to/shuttle"
  exit 1
fi

log "Shuttle CLI ↔ app smoke validation"
log "repo:    $REPO_ROOT"
log "cli:     $SHUTTLE_BIN_RESOLVED"
log "profile: $PROFILE"
log "results: $RESULTS_DIR"
log "note:    the app will switch away from this tab during the smoke test; output is also recorded to $LOG_FILE and the script restores your original session at the end."
observe "Starting in ${START_DELAY_SECONDS}s. Press Ctrl-C now if you want to abort." "$START_DELAY_SECONDS"

log
log "== Preflight + JSON/control-plane checks =="

CONTROL_PING_FILE=$(run_shuttle_json 01-control-ping control_pong control ping)
assert_py "$CONTROL_PING_FILE" "obj['data']['message'] == 'pong'" "control ping should return pong"
assert_py "$CONTROL_PING_FILE" "obj['data']['profile'] == '$PROFILE'" "control ping should report the active profile"

CONTROL_CAPABILITIES_FILE=$(run_shuttle_json 02-control-capabilities control_capabilities control capabilities)
assert_py "$CONTROL_CAPABILITIES_FILE" "obj['data']['protocol_version'] == 1" "control capabilities should report protocol_version=1"
assert_py "$CONTROL_CAPABILITIES_FILE" "'workspace.open' in obj['data']['supported_commands']" "capabilities should include workspace.open"
assert_py "$CONTROL_CAPABILITIES_FILE" "'session.open' in obj['data']['supported_commands']" "capabilities should include session.open"
assert_py "$CONTROL_CAPABILITIES_FILE" "'session.rename' in obj['data']['supported_commands']" "capabilities should include session.rename"
assert_py "$CONTROL_CAPABILITIES_FILE" "'session.close' in obj['data']['supported_commands']" "capabilities should include session.close"
assert_py "$CONTROL_CAPABILITIES_FILE" "'layout.apply' in obj['data']['supported_commands']" "capabilities should include layout.apply"
assert_py "$CONTROL_CAPABILITIES_FILE" "'layout.save-current' in obj['data']['supported_commands']" "capabilities should include layout.save-current"
assert_py "$CONTROL_CAPABILITIES_FILE" "'tab.send' in obj['data']['supported_commands']" "capabilities should include tab.send"
assert_py "$CONTROL_CAPABILITIES_FILE" "'tab.read' in obj['data']['supported_commands']" "capabilities should include tab.read"
assert_py "$CONTROL_CAPABILITIES_FILE" "'tab.wait' in obj['data']['supported_commands']" "capabilities should include tab.wait"

CONTROL_SOCKET_FILE=$(run_shuttle_json 03-control-socket-path control_socket_path control socket-path)
assert_py "$CONTROL_SOCKET_FILE" "obj['data']['socket_path'] != ''" "control socket-path should not be empty"

CONFIG_PATH_FILE=$(run_shuttle_json 04-config-path config_path config path)
assert_py "$CONFIG_PATH_FILE" "obj['data']['profile'] == '$PROFILE'" "config path should report the active profile"

BOOTSTRAP_HINT_FILE=$(run_shuttle_json 05-bootstrap-hint bootstrap_hint app bootstrap-hint)
assert_py "$BOOTSTRAP_HINT_FILE" "obj['data']['hint'] != ''" "bootstrap hint should not be empty"

CURRENT_CONTEXT_FILE=$(run_shuttle_json 06-current-session-context session_context session context "$ORIGINAL_SESSION_ID")
assert_py "$CURRENT_CONTEXT_FILE" "obj['data']['session']['id'] == '$ORIGINAL_SESSION_ID'" "session context should reference the current session"
assert_py "$CURRENT_CONTEXT_FILE" "obj['data']['workspace']['id'] == '$ORIGINAL_WORKSPACE_ID'" "session context should reference the current workspace"
assert_py "$CURRENT_CONTEXT_FILE" "len(obj['data']['projects']) >= 1" "session context should include at least one project"

if [[ -z "$CURRENT_PROJECT_ID" ]]; then
  CURRENT_PROJECT_ID=$(json_get "$CURRENT_CONTEXT_FILE" "obj['data']['projects'][0]['id']")
fi
if [[ -z "$CURRENT_PROJECT_NAME" ]]; then
  CURRENT_PROJECT_NAME=$(json_get "$CURRENT_CONTEXT_FILE" "obj['data']['projects'][0]['name']")
fi
CURRENT_WORKSPACE_NAME=$(json_get "$CURRENT_CONTEXT_FILE" "obj['data']['workspace']['name']")
CURRENT_SESSION_NAME=$(json_get "$CURRENT_CONTEXT_FILE" "obj['data']['session']['name']")

PROJECT_SHOW_FILE=$(run_shuttle_json 07-current-project project project show "$CURRENT_PROJECT_ID")
assert_py "$PROJECT_SHOW_FILE" "obj['data']['project']['id'] == '$CURRENT_PROJECT_ID'" "project show should resolve the current project"

ORIGINAL_WORKSPACE_SHOW_FILE=$(run_shuttle_json 08-original-workspace workspace workspace show "$ORIGINAL_WORKSPACE_ID")
assert_py "$ORIGINAL_WORKSPACE_SHOW_FILE" "obj['data']['workspace']['id'] == '$ORIGINAL_WORKSPACE_ID'" "workspace show should resolve the current workspace"

log "current workspace: $CURRENT_WORKSPACE_NAME ($ORIGINAL_WORKSPACE_ID)"
log "current session:   $CURRENT_SESSION_NAME ($ORIGINAL_SESSION_ID)"
log "seed project:      $CURRENT_PROJECT_NAME ($CURRENT_PROJECT_ID)"

SCRATCH_WORKSPACE_ID="$ORIGINAL_WORKSPACE_ID"
SCRATCH_WORKSPACE_NAME="$CURRENT_WORKSPACE_NAME"
SCRATCH_SESSION_NAME="cli-smoke-$RUN_ID"
SCRATCH_SESSION_RENAMED="cli-smoke-renamed-$RUN_ID"
SCRATCH_LAYOUT_NAME="cli-smoke-layout-$RUN_ID"
MARKER="__SHUTTLE_CLI_SMOKE_${RUN_ID}__"

log
log "== Create scratch session in the current workspace =="

SCRATCH_SESSION_CREATE_FILE=$(run_shuttle_json 10-scratch-session-create session session new --workspace "$SCRATCH_WORKSPACE_ID" --name "$SCRATCH_SESSION_NAME" --layout single)
SCRATCH_SESSION_ID=$(json_get "$SCRATCH_SESSION_CREATE_FILE" "obj['data']['session']['id']")
assert_py "$SCRATCH_SESSION_CREATE_FILE" "obj['data']['session']['id'] == '$SCRATCH_SESSION_ID'" "session new should create the scratch session"
assert_py "$SCRATCH_SESSION_CREATE_FILE" "obj['data']['session']['layout_name'] == 'single'" "scratch session should start with the single layout"
assert_py "$SCRATCH_SESSION_CREATE_FILE" "len(obj['data']['panes']) == 1" "single layout should start with one pane"
assert_py "$SCRATCH_SESSION_CREATE_FILE" "len(obj['data']['tabs']) == 1" "single layout should start with one tab"
observe "The app should now have opened the scratch session '$SCRATCH_SESSION_NAME'."

SCRATCH_WORKSPACE_SHOW_FILE=$(run_shuttle_json 11-scratch-workspace-show workspace workspace show "$SCRATCH_WORKSPACE_ID")
assert_py "$SCRATCH_WORKSPACE_SHOW_FILE" "obj['data']['workspace']['id'] == '$SCRATCH_WORKSPACE_ID'" "workspace show should resolve the current workspace"
assert_py "$SCRATCH_WORKSPACE_SHOW_FILE" "any(session['id'] == '$SCRATCH_SESSION_ID' for session in obj['data']['sessions'])" "the current workspace should list the scratch session"

SCRATCH_WORKSPACE_OPEN_FILE=$(run_shuttle_json 12-scratch-workspace-open workspace_open workspace open "$SCRATCH_WORKSPACE_ID")
assert_py "$SCRATCH_WORKSPACE_OPEN_FILE" "obj['data']['workspace']['id'] == '$SCRATCH_WORKSPACE_ID'" "workspace open should focus the current workspace"
observe "The app should now be focused on workspace '$SCRATCH_WORKSPACE_NAME'."

SCRATCH_SESSION_OPEN_FILE=$(run_shuttle_json 13-scratch-session-open session_open session open "$SCRATCH_SESSION_ID")
assert_py "$SCRATCH_SESSION_OPEN_FILE" "obj['data']['bundle']['session']['id'] == '$SCRATCH_SESSION_ID'" "session open should focus the scratch session"
observe "The app should now be focused on session '$SCRATCH_SESSION_NAME'."

log
log "== Session rename + show/context =="

SCRATCH_SESSION_RENAME_FILE=$(run_shuttle_json 15-scratch-session-rename session session rename "$SCRATCH_SESSION_ID" "$SCRATCH_SESSION_RENAMED")
assert_py "$SCRATCH_SESSION_RENAME_FILE" "obj['data']['session']['id'] == '$SCRATCH_SESSION_ID'" "session rename should keep the same session id"
assert_py "$SCRATCH_SESSION_RENAME_FILE" "obj['data']['session']['name'] == '$SCRATCH_SESSION_RENAMED'" "session rename should update the name"
observe "The app should now show the renamed session '$SCRATCH_SESSION_RENAMED'."

SCRATCH_SESSION_SHOW_FILE=$(run_shuttle_json 16-scratch-session-show session session show "$SCRATCH_SESSION_ID")
assert_py "$SCRATCH_SESSION_SHOW_FILE" "obj['data']['session']['name'] == '$SCRATCH_SESSION_RENAMED'" "session show should reflect the renamed session"

SCRATCH_SESSION_LIST_ACTIVE_FILE=$(run_shuttle_json 17-scratch-session-list-active session_list session list --workspace "$SCRATCH_WORKSPACE_ID")
assert_py "$SCRATCH_SESSION_LIST_ACTIVE_FILE" "any(item['id'] == '$SCRATCH_SESSION_ID' and item['status'] == 'active' for item in obj['data']['items'])" "session list should show the scratch session as active"

log
log "== Layout + pane/tab mutation checks =="

LAYOUT_LIST_FILE=$(run_shuttle_json 20-layout-list layout_list layout list)
assert_py "$LAYOUT_LIST_FILE" "set(['single', 'dev', 'agent']).issubset(set(item['id'] for item in obj['data']['items']))" "layout list should include the built-in presets"

LAYOUT_SHOW_DEV_FILE=$(run_shuttle_json 21-layout-show-dev layout layout show dev)
assert_py "$LAYOUT_SHOW_DEV_FILE" "obj['data']['id'] == 'dev'" "layout show dev should resolve the dev preset"
assert_py "$LAYOUT_SHOW_DEV_FILE" "obj['data']['origin'] == 'built_in'" "dev layout should be built_in"

LAYOUT_APPLY_DEV_FILE=$(run_shuttle_json 22-layout-apply-dev session layout apply --session "$SCRATCH_SESSION_ID" --layout dev)
assert_py "$LAYOUT_APPLY_DEV_FILE" "obj['data']['session']['layout_name'] == 'dev'" "layout apply should update the session layout name"
observe "The app should now show the built-in dev layout (2 visible panes backed by a root split container)."

PANE_LIST_AFTER_LAYOUT_FILE=$(run_shuttle_json 23-pane-list-after-layout pane_list pane list --session "$SCRATCH_SESSION_ID")
assert_py "$PANE_LIST_AFTER_LAYOUT_FILE" "len(obj['data']['items']) == 3" "dev layout should produce 3 stored panes (root + 2 leaf panes)"
assert_py "$PANE_LIST_AFTER_LAYOUT_FILE" "len([item for item in obj['data']['items'] if item['raw_id'] not in set(p.get('parent_pane_id') for p in obj['data']['items'] if p.get('parent_pane_id') is not None)]) == 2" "dev layout should expose 2 leaf panes"
TARGET_PANE_ID=$(json_get "$PANE_LIST_AFTER_LAYOUT_FILE" "[item['id'] for item in obj['data']['items'] if item['raw_id'] not in set(p.get('parent_pane_id') for p in obj['data']['items'] if p.get('parent_pane_id') is not None)][0]")

TAB_LIST_AFTER_LAYOUT_FILE=$(run_shuttle_json 24-tab-list-after-layout tab_list tab list --session "$SCRATCH_SESSION_ID")
assert_py "$TAB_LIST_AFTER_LAYOUT_FILE" "len(obj['data']['items']) == 2" "dev layout should produce 2 tabs"

PANE_SHOW_FILE=$(run_shuttle_json 25-pane-show pane pane show --session "$SCRATCH_SESSION_ID" --pane "$TARGET_PANE_ID")
assert_py "$PANE_SHOW_FILE" "obj['data']['pane']['id'] == '$TARGET_PANE_ID'" "pane show should resolve the target pane"

TAB_NEW_FILE=$(run_shuttle_json 26-tab-new session tab new --session "$SCRATCH_SESSION_ID" --pane "$TARGET_PANE_ID")
observe "The app should now show an additional tab in the selected leaf pane."

TAB_LIST_AFTER_NEW_FILE=$(run_shuttle_json 27-tab-list-after-new tab_list tab list --session "$SCRATCH_SESSION_ID")
assert_py "$TAB_LIST_AFTER_NEW_FILE" "len(obj['data']['items']) == 3" "tab new should increase the tab count to 3"

PANE_SPLIT_FILE=$(run_shuttle_json 28-pane-split session pane split right --session "$SCRATCH_SESSION_ID" --pane "$TARGET_PANE_ID")
observe "The app should now show a 3-pane visible layout after splitting the selected leaf pane."

PANE_LIST_AFTER_SPLIT_FILE=$(run_shuttle_json 29-pane-list-after-split pane_list pane list --session "$SCRATCH_SESSION_ID")
assert_py "$PANE_LIST_AFTER_SPLIT_FILE" "len(obj['data']['items']) == 5" "splitting one leaf inside the dev layout should produce 5 stored panes (2 split containers + 3 leaf panes)"
assert_py "$PANE_LIST_AFTER_SPLIT_FILE" "len([item for item in obj['data']['items'] if item['raw_id'] not in set(p.get('parent_pane_id') for p in obj['data']['items'] if p.get('parent_pane_id') is not None)]) == 3" "pane split should expose 3 leaf panes"
SPLIT_CONTAINER_ID=$(json_get "$PANE_SPLIT_FILE" "[item['id'] for item in obj['data']['panes'] if item['raw_id'] == [p.get('parent_pane_id') for p in obj['data']['panes'] if p['id'] == '$TARGET_PANE_ID'][0]][0]")
SPLIT_CLONE_PANE_ID=$(json_get "$PANE_SPLIT_FILE" "[item['id'] for item in obj['data']['panes'] if item.get('parent_pane_id') == [p.get('parent_pane_id') for p in obj['data']['panes'] if p['id'] == '$TARGET_PANE_ID'][0] and item['id'] != '$TARGET_PANE_ID'][0]")
SPLIT_CLONE_TAB_ID=$(json_get "$PANE_SPLIT_FILE" "[item['id'] for item in obj['data']['tabs'] if item['pane_id'] == [pane['raw_id'] for pane in obj['data']['panes'] if pane['id'] == '$SPLIT_CLONE_PANE_ID'][0]][0]")

TAB_LIST_AFTER_SPLIT_FILE=$(run_shuttle_json 30-tab-list-after-split tab_list tab list --session "$SCRATCH_SESSION_ID")
assert_py "$TAB_LIST_AFTER_SPLIT_FILE" "len(obj['data']['items']) == 4" "pane split should clone a tab and increase the tab count to 4"

PANE_RESIZE_FILE=$(run_shuttle_json 31-pane-resize session pane resize --session "$SCRATCH_SESSION_ID" --pane "$SPLIT_CONTAINER_ID" --ratio 0.35)
assert_py "$PANE_RESIZE_FILE" "any(pane['id'] == '$SPLIT_CONTAINER_ID' and (pane.get('ratio') is not None) and abs(pane['ratio'] - 0.35) < 0.0001 for pane in obj['data']['panes'])" "pane resize should persist the updated split ratio on the split container"
observe "The app should now show the resized split ratio."

LAYOUT_SAVE_FILE=$(run_shuttle_json 32-layout-save-current layout layout save-current --session "$SCRATCH_SESSION_ID" --name "$SCRATCH_LAYOUT_NAME" --description "CLI smoke test $RUN_ID")
assert_py "$LAYOUT_SAVE_FILE" "obj['data']['name'] == '$SCRATCH_LAYOUT_NAME'" "layout save-current should create the custom preset"
assert_py "$LAYOUT_SAVE_FILE" "obj['data']['origin'] == 'custom'" "saved layout should be custom"

LAYOUT_SHOW_SAVED_FILE=$(run_shuttle_json 33-layout-show-saved layout layout show "$SCRATCH_LAYOUT_NAME")
assert_py "$LAYOUT_SHOW_SAVED_FILE" "obj['data']['name'] == '$SCRATCH_LAYOUT_NAME'" "layout show should resolve the saved preset"
assert_py "$LAYOUT_SHOW_SAVED_FILE" "obj['data']['origin'] == 'custom'" "saved preset should be custom"

TAB_CLOSE_FILE=$(run_shuttle_json 34-tab-close session tab close --session "$SCRATCH_SESSION_ID" --tab "$SPLIT_CLONE_TAB_ID")
observe "The split-created pane/tab should now have been removed, collapsing back toward the original 2-pane visible dev layout."

PANE_LIST_AFTER_TAB_CLOSE_FILE=$(run_shuttle_json 35-pane-list-after-tab-close pane_list pane list --session "$SCRATCH_SESSION_ID")
assert_py "$PANE_LIST_AFTER_TAB_CLOSE_FILE" "len(obj['data']['items']) == 3" "closing the split-clone tab should collapse back to 3 stored panes (root + 2 leaf panes)"
assert_py "$PANE_LIST_AFTER_TAB_CLOSE_FILE" "len([item for item in obj['data']['items'] if item['raw_id'] not in set(p.get('parent_pane_id') for p in obj['data']['items'] if p.get('parent_pane_id') is not None)]) == 2" "closing the split-clone tab should return to 2 leaf panes"

TAB_LIST_AFTER_TAB_CLOSE_FILE=$(run_shuttle_json 36-tab-list-after-tab-close tab_list tab list --session "$SCRATCH_SESSION_ID")
assert_py "$TAB_LIST_AFTER_TAB_CLOSE_FILE" "len(obj['data']['items']) == 3" "closing the split-clone tab should reduce the tab count back to 3"

PANE1_TABS_FILE=$(run_shuttle_json 37-pane1-tabs tab_list tab list --session "$SCRATCH_SESSION_ID" --pane "$TARGET_PANE_ID")
assert_py "$PANE1_TABS_FILE" "len(obj['data']['items']) == 2" "the selected leaf pane should still have 2 tabs after cleanup"
RUNTIME_TAB_ID=$(json_get "$PANE1_TABS_FILE" "obj['data']['items'][-1]['id']")

log
log "== Runtime tab send/read/wait checks =="

observe "Giving the scratch session a moment to settle before sending runtime automation." 2
printf -v RUNTIME_PAYLOAD "printf '%s cwd=%%s\\n' \"\$PWD\"" "$MARKER"

TAB_SEND_FILE=$(run_shuttle_json 40-tab-send tab_send tab send --tab "$RUNTIME_TAB_ID" --text "$RUNTIME_PAYLOAD" --submit)
assert_py "$TAB_SEND_FILE" "obj['data']['tab']['id'] == '$RUNTIME_TAB_ID'" "tab send should target the selected runtime tab"
assert_py "$TAB_SEND_FILE" "obj['data']['submitted'] == True" "tab send should report submit=true when requested"
assert_py "$TAB_SEND_FILE" "obj['data']['cursor']['token'] != ''" "tab send should return a cursor token"
TAB_SEND_CURSOR=$(json_get "$TAB_SEND_FILE" "obj['data']['cursor']['token']")
observe "The runtime marker command should now execute inside the scratch tab." 2

TAB_WAIT_FILE=$(run_shuttle_json 41-tab-wait tab_wait tab wait --tab "$RUNTIME_TAB_ID" --text "$MARKER" --mode scrollback --lines 400 --timeout-ms 20000 --after-cursor "$TAB_SEND_CURSOR")
assert_py "$TAB_WAIT_FILE" "obj['data']['matched_text'] == '$MARKER'" "tab wait should match the runtime marker"
assert_py "$TAB_WAIT_FILE" "obj['data']['is_incremental'] == True" "tab wait should report incremental reads when using --after-cursor"
assert_py "$TAB_WAIT_FILE" "obj['data']['after_cursor']['token'] == '$TAB_SEND_CURSOR'" "tab wait should echo the starting cursor"
assert_py "$TAB_WAIT_FILE" "obj['data']['cursor']['token'] != '$TAB_SEND_CURSOR'" "tab wait should return a fresh cursor"

TAB_READ_SCREEN_FILE=$(run_shuttle_json 42-tab-read-screen tab_read tab read --tab "$RUNTIME_TAB_ID" --mode screen --lines 120)
TAB_READ_SCROLLBACK_FILE=$(run_shuttle_json 43-tab-read-scrollback tab_read tab read --tab "$RUNTIME_TAB_ID" --mode scrollback --lines 400)
assert_text_contains "$TAB_READ_SCROLLBACK_FILE" "obj['data']['text']" "$MARKER" "tab read scrollback should contain the runtime marker"
assert_text_contains "$TAB_READ_SCREEN_FILE" "obj['data']['text']" "$MARKER" "tab read screen should contain the runtime marker"

log
log "== Session close/reopen/restore checks =="

observe "Waiting briefly so the prompt-return checkpoint can settle before closing the session." 2
SCRATCH_SESSION_CLOSE_FILE=$(run_shuttle_json 50-scratch-session-close session session close "$SCRATCH_SESSION_ID")
assert_py "$SCRATCH_SESSION_CLOSE_FILE" "obj['data']['session']['status'] == 'closed'" "session close should mark the scratch session as closed"
observe "The scratch session should now close/archive in the app." 2

SCRATCH_SESSION_LIST_CLOSED_FILE=$(run_shuttle_json 51-scratch-session-list-closed session_list session list --workspace "$SCRATCH_WORKSPACE_ID")
assert_py "$SCRATCH_SESSION_LIST_CLOSED_FILE" "any(item['id'] == '$SCRATCH_SESSION_ID' and item['status'] == 'closed' for item in obj['data']['items'])" "session list should show the scratch session as closed"

SCRATCH_SESSION_REOPEN_FILE=$(run_shuttle_json 52-scratch-session-reopen session_open session reopen "$SCRATCH_SESSION_ID")
assert_py "$SCRATCH_SESSION_REOPEN_FILE" "obj['data']['bundle']['session']['id'] == '$SCRATCH_SESSION_ID'" "session reopen should reopen the scratch session"
assert_py "$SCRATCH_SESSION_REOPEN_FILE" "obj['data']['bundle']['session']['status'] == 'active'" "session reopen should make the scratch session active again"
assert_py "$SCRATCH_SESSION_REOPEN_FILE" "any(tab['id'] == '$RUNTIME_TAB_ID' and tab['runtime_status'] == 'idle' for tab in obj['data']['bundle']['tabs'])" "session reopen should bring back the runtime tab in idle/restorable state"
WAS_RESTORED=$(json_get "$SCRATCH_SESSION_REOPEN_FILE" "obj['data']['was_restored']")
observe "The scratch session should now reopen; its runtime should restore shortly." 3

REOPEN_MARKER="__SHUTTLE_CLI_REOPEN_${RUN_ID}__"
printf -v REOPEN_RUNTIME_PAYLOAD "printf '%s reopen cwd=%%s\\n' \"\$PWD\"" "$REOPEN_MARKER"

TAB_SEND_AFTER_REOPEN_FILE=$(run_shuttle_json_retry 5 1 53-tab-send-after-reopen tab_send tab send --tab "$RUNTIME_TAB_ID" --text "$REOPEN_RUNTIME_PAYLOAD" --submit)
assert_py "$TAB_SEND_AFTER_REOPEN_FILE" "obj['data']['tab']['id'] == '$RUNTIME_TAB_ID'" "tab send should still work after reopening the session"
assert_py "$TAB_SEND_AFTER_REOPEN_FILE" "obj['data']['submitted'] == True" "post-reopen tab send should report submit=true when requested"
assert_py "$TAB_SEND_AFTER_REOPEN_FILE" "obj['data']['cursor']['token'] != ''" "post-reopen tab send should return a cursor token"
TAB_SEND_AFTER_REOPEN_CURSOR=$(json_get "$TAB_SEND_AFTER_REOPEN_FILE" "obj['data']['cursor']['token']")

TAB_WAIT_AFTER_REOPEN_FILE=$(run_shuttle_json_retry 5 1 54-tab-wait-after-reopen tab_wait tab wait --tab "$RUNTIME_TAB_ID" --text "$REOPEN_MARKER" --mode scrollback --lines 400 --timeout-ms 20000 --after-cursor "$TAB_SEND_AFTER_REOPEN_CURSOR")
assert_py "$TAB_WAIT_AFTER_REOPEN_FILE" "obj['data']['matched_text'] == '$REOPEN_MARKER'" "the reopened session should accept runtime input and surface it through tab wait"
assert_py "$TAB_WAIT_AFTER_REOPEN_FILE" "obj['data']['is_incremental'] == True" "post-reopen tab wait should report incremental reads when using --after-cursor"

TAB_READ_AFTER_REOPEN_FILE=$(run_shuttle_json_retry 5 1 55-tab-read-after-reopen tab_read tab read --tab "$RUNTIME_TAB_ID" --mode scrollback --lines 400)
assert_text_contains "$TAB_READ_AFTER_REOPEN_FILE" "obj['data']['text']" "$REOPEN_MARKER" "the reopened session scrollback should contain the post-reopen runtime marker"

log
log "== Return app to the original session =="

FINAL_SCRATCH_SESSION_CLOSE_FILE=$(run_shuttle_json 60-final-scratch-session-close session session close "$SCRATCH_SESSION_ID")
assert_py "$FINAL_SCRATCH_SESSION_CLOSE_FILE" "obj['data']['session']['status'] == 'closed'" "final scratch close should leave the scratch session archived"
observe "The scratch session is being archived again before returning you to the original session." 1

ORIGINAL_WORKSPACE_OPEN_FILE=$(run_shuttle_json 61-original-workspace-open workspace_open workspace open "$ORIGINAL_WORKSPACE_ID")
assert_py "$ORIGINAL_WORKSPACE_OPEN_FILE" "obj['data']['workspace']['id'] == '$ORIGINAL_WORKSPACE_ID'" "workspace open should return to the original workspace"
observe "The app should now be moving back toward the original workspace." 1

ORIGINAL_SESSION_OPEN_FILE=$(run_shuttle_json 62-original-session-open session_open session open "$ORIGINAL_SESSION_ID")
assert_py "$ORIGINAL_SESSION_OPEN_FILE" "obj['data']['bundle']['session']['id'] == '$ORIGINAL_SESSION_ID'" "session open should return to the original session"
observe "The app should now be back on the original session/tab running this script." 1

RESTORE_ON_EXIT=0

cat > "$SUMMARY_FILE" <<EOF
Shuttle CLI ↔ app smoke validation
run_id: $RUN_ID
profile: $PROFILE
cli: $SHUTTLE_BIN_RESOLVED
results_dir: $RESULTS_DIR
log_file: $LOG_FILE

original_workspace: $CURRENT_WORKSPACE_NAME ($ORIGINAL_WORKSPACE_ID)
original_session: $CURRENT_SESSION_NAME ($ORIGINAL_SESSION_ID)
original_pane: $ORIGINAL_PANE_ID
original_tab: $ORIGINAL_TAB_ID
seed_project: $CURRENT_PROJECT_NAME ($CURRENT_PROJECT_ID)

scratch_workspace: $SCRATCH_WORKSPACE_NAME ($SCRATCH_WORKSPACE_ID) [reused existing workspace]
scratch_session: $SCRATCH_SESSION_RENAMED ($SCRATCH_SESSION_ID)
saved_layout: $SCRATCH_LAYOUT_NAME
runtime_tab: $RUNTIME_TAB_ID
marker: $MARKER
was_restored_on_reopen: $WAS_RESTORED

artifacts left behind intentionally:
- a closed session named $SCRATCH_SESSION_RENAMED
- a custom layout preset named $SCRATCH_LAYOUT_NAME

manual cleanup (if desired):
- delete the scratch session from the Shuttle app
- remove the saved layout preset from the Layout Library
EOF

log
log "Smoke validation passed."
log "summary: $SUMMARY_FILE"
log "results: $RESULTS_DIR"
log "reopen was_restored: $WAS_RESTORED"
log
log "Artifacts intentionally left behind for inspection:"
log "  session:   $SCRATCH_SESSION_RENAMED ($SCRATCH_SESSION_ID) [closed]"
log "  layout:    $SCRATCH_LAYOUT_NAME"
