# Shuttle shell integration for bash.
# Emits OSC title + cwd markers so the embedded terminal host can track
# current working directory and prompt/command context more faithfully.

if [[ -n "${_SHUTTLE_BASH_INTEGRATION_LOADED:-}" ]]; then
  return 0
fi
_SHUTTLE_BASH_INTEGRATION_LOADED=1

_shuttle_print_restore_boundary() {
  local label="$1"
  [[ -n "$label" ]] || return 0
  printf '[Shuttle] --- %s ---\n' "$label"
}

_shuttle_restore_scrollback_once() {
  local path="${SHUTTLE_RESTORE_SCROLLBACK_FILE:-}"
  [[ -n "$path" ]] || return 0
  unset SHUTTLE_RESTORE_SCROLLBACK_FILE
  [[ -r "$path" ]] || return 0

  printf '\n'
  _shuttle_print_restore_boundary "begin restored scrollback"
  /bin/cat -- "$path" 2>/dev/null || true
  /bin/rm -f -- "$path" >/dev/null 2>&1 || true
  printf '\n'
}
_shuttle_restore_scrollback_once

_shuttle_urlencode_path() {
  local value="$1"
  value="${value//%/%25}"
  value="${value// /%20}"
  value="${value//#/%23}"
  value="${value//\?/%3F}"
  value="${value//\[/%5B}"
  value="${value//\]/%5D}"
  printf '%s' "$value"
}

_shuttle_basename_path() {
  local path="$1"
  path="${path%/}"
  [[ -n "$path" ]] || {
    printf '%s' ""
    return 0
  }
  printf '%s' "${path##*/}"
}

_shuttle_relative_to() {
  local root="$1"
  local path="$2"
  local prefix

  [[ -n "$root" && -n "$path" ]] || return 1

  root="${root%/}"
  path="${path%/}"

  if [[ "$path" == "$root" ]]; then
    printf '%s' ""
    return 0
  fi

  prefix="${root}/"
  if [[ "$path" == "$prefix"* ]]; then
    printf '%s' "${path#$prefix}"
    return 0
  fi

  return 1
}

_shuttle_is_assignment_word() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

_shuttle_idle_title() {
  local session_root="${SHUTTLE_SESSION_ROOT:-}"
  local project_path="${SHUTTLE_PROJECT_PATH:-}"
  local relative root_name

  if relative="$(_shuttle_relative_to "$session_root" "$PWD" 2>/dev/null)"; then
    if [[ -n "$relative" ]]; then
      printf '%s' "$relative"
      return 0
    fi
    root_name="$(_shuttle_basename_path "$session_root")"
    [[ -n "$root_name" ]] || root_name="${SHUTTLE_SESSION_NAME:-${PWD##*/}}"
    printf '%s' "$root_name"
    return 0
  fi

  if relative="$(_shuttle_relative_to "$project_path" "$PWD" 2>/dev/null)"; then
    root_name="$(_shuttle_basename_path "$project_path")"
    [[ -n "$root_name" ]] || root_name="${PWD##*/}"
    if [[ -n "$relative" ]]; then
      printf '%s' "$root_name/$relative"
    else
      printf '%s' "$root_name"
    fi
    return 0
  fi

  printf '%s' "${PWD##*/}"
}

_shuttle_command_title() {
  local cmd="$1"
  local -a words
  local idx raw exe next third

  read -r -a words <<< "$cmd"
  if [[ ${#words[@]} -eq 0 ]]; then
    _shuttle_idle_title
    return 0
  fi

  idx=0
  while [[ $idx -lt ${#words[@]} ]]; do
    raw="${words[$idx]}"
    case "$raw" in
      sudo|command|builtin|time|noglob|nocorrect)
        ((idx++))
        continue
        ;;
      env|/usr/bin/env)
        ((idx++))
        while [[ $idx -lt ${#words[@]} ]] && _shuttle_is_assignment_word "${words[$idx]}"; do
          ((idx++))
        done
        continue
        ;;
    esac
    if _shuttle_is_assignment_word "$raw"; then
      ((idx++))
      continue
    fi
    break
  done

  while [[ $idx -lt ${#words[@]} ]]; do
    raw="${words[$idx]}"
    exe="$(_shuttle_basename_path "$raw")"
    next="${words[$((idx + 1))]:-}"

    case "$exe" in
      bundle)
        if [[ "$next" == "exec" ]]; then
          ((idx += 2))
          continue
        fi
        ;;
      uv|poetry|pipenv)
        if [[ "$next" == "run" ]]; then
          ((idx += 2))
          continue
        fi
        ;;
      npm|pnpm|yarn|bun)
        if [[ "$next" == "exec" ]]; then
          ((idx += 2))
          continue
        fi
        ;;
    esac
    break
  done

  raw="${words[$idx]:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' "$cmd"
    return 0
  fi

  exe="$(_shuttle_basename_path "$raw")"
  next="${words[$((idx + 1))]:-}"
  third="${words[$((idx + 2))]:-}"

  if [[ "$exe" == python* ]]; then
    if [[ "$next" == "-m" && -n "$third" ]]; then
      printf '%s' "$third"
    else
      printf '%s' "$exe"
    fi
    return 0
  fi

  case "$exe" in
    npm|pnpm|bun)
      if [[ "$next" == "run" && -n "$third" ]]; then
        printf '%s' "$exe:$third"
      elif [[ -n "$next" && "$next" != -* ]]; then
        printf '%s' "$exe $next"
      else
        printf '%s' "$exe"
      fi
      return 0
      ;;
    yarn)
      if [[ "$next" == "run" && -n "$third" ]]; then
        printf '%s' "yarn:$third"
      elif [[ -n "$next" && "$next" != -* ]]; then
        printf '%s' "yarn:$next"
      else
        printf '%s' "yarn"
      fi
      return 0
      ;;
    ruby)
      if [[ "$next" == "-S" && -n "$third" ]]; then
        printf '%s' "$(_shuttle_basename_path "$third")"
      else
        printf '%s' "$exe"
      fi
      return 0
      ;;
    docker)
      if [[ "$next" == "compose" ]]; then
        if [[ -n "$third" && "$third" != -* ]]; then
          printf '%s' "docker compose $third"
        else
          printf '%s' "docker compose"
        fi
      elif [[ -n "$next" && "$next" != -* ]]; then
        printf '%s' "docker $next"
      else
        printf '%s' "docker"
      fi
      return 0
      ;;
    git|gh|gt|go|cargo|swift|terraform|kubectl|helm|make)
      if [[ -n "$next" && "$next" != -* ]]; then
        printf '%s' "$exe $next"
      else
        printf '%s' "$exe"
      fi
      return 0
      ;;
    rails|rake)
      if [[ -n "$next" && "$next" != -* ]]; then
        printf '%s' "$exe $next"
      else
        printf '%s' "$exe"
      fi
      return 0
      ;;
  esac

  printf '%s' "$exe"
}

_shuttle_emit_pwd() {
  local host="${HOSTNAME:-localhost}"
  local encoded
  encoded="$(_shuttle_urlencode_path "$PWD")"
  printf '\033]7;file://%s%s\007' "$host" "$encoded"
}

_shuttle_emit_title() {
  local title="$1"
  [[ -n "$title" ]] || title="$(_shuttle_idle_title)"
  printf '\033]2;%s\007' "$title"
}

_shuttle_prompt_phase_begin() {
  _SHUTTLE_IN_PROMPT_PHASE=1
}

_shuttle_prompt_command() {
  _shuttle_emit_pwd
  _shuttle_emit_title "$(_shuttle_idle_title)"
  _SHUTTLE_COMMAND_STARTED=0
  _SHUTTLE_IN_PROMPT_PHASE=0
}

_shuttle_debug_trap() {
  local cmd="${BASH_COMMAND:-}"

  [[ "${_SHUTTLE_IN_PROMPT_PHASE:-0}" == "1" ]] && return 0
  [[ "${_SHUTTLE_COMMAND_STARTED:-0}" == "1" ]] && return 0
  [[ -n "$cmd" ]] || return 0

  case "$cmd" in
    _shuttle_*)
      return 0
      ;;
  esac

  _SHUTTLE_COMMAND_STARTED=1
  _shuttle_emit_title "$(_shuttle_command_title "$cmd")"
}

if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
  PROMPT_COMMAND=("_shuttle_prompt_phase_begin" "${PROMPT_COMMAND[@]}" "_shuttle_prompt_command")
else
  if [[ -n "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="_shuttle_prompt_phase_begin;${PROMPT_COMMAND};_shuttle_prompt_command"
  else
    PROMPT_COMMAND="_shuttle_prompt_phase_begin;_shuttle_prompt_command"
  fi
fi

trap '_shuttle_debug_trap' DEBUG
