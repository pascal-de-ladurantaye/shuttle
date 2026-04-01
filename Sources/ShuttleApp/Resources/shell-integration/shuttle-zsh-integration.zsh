# Shuttle shell integration for zsh.
# Emits OSC title + cwd markers so the embedded terminal host can track
# current working directory and prompt/command context more faithfully.

(( ${+_SHUTTLE_ZSH_INTEGRATION_LOADED} )) && return 0
_SHUTTLE_ZSH_INTEGRATION_LOADED=1

autoload -Uz add-zsh-hook

_shuttle_print_restore_boundary() {
    local label="$1"
    [[ -n "$label" ]] || return 0
    print -r -- "[Shuttle] --- $label ---"
}

_shuttle_restore_scrollback_once() {
    local path="${SHUTTLE_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset SHUTTLE_RESTORE_SCROLLBACK_FILE
    [[ -r "$path" ]] || return 0

    print -r -- ""
    _shuttle_print_restore_boundary "begin restored scrollback"
    /bin/cat -- "$path" 2>/dev/null || true
    /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    print -r -- ""
}
_shuttle_restore_scrollback_once

_shuttle_ensure_ghostty_preexec_strips_both_marks() {
    local fn_name="$1"
    (( $+functions[$fn_name] )) || return 0

    local old_strip new_strip updated
    old_strip=$'PS1=${PS1//$\'%{\\e]133;A;cl=line\\a%}\'}'
    new_strip=$'PS1=${PS1//$\'%{\\e]133;A;redraw=last;cl=line\\a%}\'}'
    updated="${functions[$fn_name]}"

    if [[ "$updated" == *"$new_strip"* && "$updated" != *"$old_strip"* ]]; then
        updated="${updated/$new_strip/$old_strip
        $new_strip}"
        functions[$fn_name]="$updated"
        return 0
    fi
    if [[ "$updated" == *"$old_strip"* && "$updated" != *"$new_strip"* ]]; then
        updated="${updated/$old_strip/$old_strip
        $new_strip}"
        functions[$fn_name]="$updated"
    fi
}

_shuttle_patch_ghostty_semantic_redraw() {
    local old_frag new_frag
    old_frag='133;A;cl=line'
    new_frag='133;A;redraw=last;cl=line'

    if (( $+functions[_ghostty_deferred_init] )); then
        functions[_ghostty_deferred_init]="${functions[_ghostty_deferred_init]//$old_frag/$new_frag}"
    fi
    if (( $+functions[_ghostty_precmd] )); then
        functions[_ghostty_precmd]="${functions[_ghostty_precmd]//$old_frag/$new_frag}"
    fi
    if (( $+functions[_ghostty_preexec] )); then
        functions[_ghostty_preexec]="${functions[_ghostty_preexec]//$old_frag/$new_frag}"
    fi

    _shuttle_ensure_ghostty_preexec_strips_both_marks _ghostty_deferred_init
    _shuttle_ensure_ghostty_preexec_strips_both_marks _ghostty_preexec
}
_shuttle_patch_ghostty_semantic_redraw

_shuttle_urlencode_path() {
    local value="$1"
    value="${value//%/%25}"
    value="${value// /%20}"
    value="${value//#/%23}"
    value="${value//\?/%3F}"
    value="${value//\[/%5B}"
    value="${value//\]/%5D}"
    print -r -- "$value"
}

_shuttle_basename_path() {
    local path="$1"
    path="${path%/}"
    [[ -n "$path" ]] || {
        print -r -- ""
        return 0
    }
    print -r -- "${path:t}"
}

_shuttle_relative_to() {
    local root="$1"
    local path="$2"
    [[ -n "$root" && -n "$path" ]] || return 1

    root="${root%/}"
    path="${path%/}"

    if [[ "$path" == "$root" ]]; then
        print -r -- ""
        return 0
    fi
    if [[ "$path" == "$root/"* ]]; then
        print -r -- "${path#$root/}"
        return 0
    fi
    return 1
}

_shuttle_is_assignment_word() {
    [[ "$1" == [A-Za-z_][A-Za-z0-9_]*=* ]]
}

_shuttle_idle_title() {
    local session_root="${SHUTTLE_SESSION_ROOT:-}"
    local project_path="${SHUTTLE_PROJECT_PATH:-}"
    local relative root_name

    if relative="$(_shuttle_relative_to "$session_root" "$PWD" 2>/dev/null)"; then
        [[ -n "$relative" ]] && {
            print -r -- "$relative"
            return 0
        }
        root_name="$(_shuttle_basename_path "$session_root")"
        [[ -n "$root_name" ]] || root_name="${SHUTTLE_SESSION_NAME:-${PWD:t}}"
        print -r -- "$root_name"
        return 0
    fi

    if relative="$(_shuttle_relative_to "$project_path" "$PWD" 2>/dev/null)"; then
        root_name="$(_shuttle_basename_path "$project_path")"
        [[ -n "$root_name" ]] || root_name="${PWD:t}"
        if [[ -n "$relative" ]]; then
            print -r -- "$root_name/$relative"
        else
            print -r -- "$root_name"
        fi
        return 0
    fi

    print -r -- "${PWD:t}"
}

_shuttle_command_title() {
    local cmd="$1"
    local -a words
    local idx raw exe next third title

    words=("${(z)cmd}")
    (( $#words > 0 )) || {
        print -r -- "$(_shuttle_idle_title)"
        return 0
    }

    idx=1
    while (( idx <= $#words )); do
        raw="${words[idx]}"
        case "$raw" in
            sudo|command|builtin|noglob|nocorrect|time)
                (( idx++ ))
                continue
                ;;
            env|/usr/bin/env)
                (( idx++ ))
                while (( idx <= $#words )) && _shuttle_is_assignment_word "${words[idx]}"; do
                    (( idx++ ))
                done
                continue
                ;;
        esac
        if _shuttle_is_assignment_word "$raw"; then
            (( idx++ ))
            continue
        fi
        break
    done

    while (( idx <= $#words )); do
        raw="${words[idx]}"
        exe="${raw:t}"
        next="${words[$((idx + 1))]-}"

        case "$exe" in
            bundle)
                if [[ "$next" == "exec" ]]; then
                    (( idx += 2 ))
                    continue
                fi
                ;;
            uv|poetry|pipenv)
                if [[ "$next" == "run" ]]; then
                    (( idx += 2 ))
                    continue
                fi
                ;;
            npm|pnpm|yarn|bun)
                if [[ "$next" == "exec" ]]; then
                    (( idx += 2 ))
                    continue
                fi
                ;;
        esac
        break
    done

    raw="${words[idx]-}"
    [[ -n "$raw" ]] || {
        print -r -- "$cmd"
        return 0
    }

    exe="${raw:t}"
    next="${words[$((idx + 1))]-}"
    third="${words[$((idx + 2))]-}"

    if [[ "$exe" == python* ]]; then
        if [[ "$next" == "-m" && -n "$third" ]]; then
            print -r -- "$third"
        else
            print -r -- "$exe"
        fi
        return 0
    fi

    case "$exe" in
        npm|pnpm|bun)
            if [[ "$next" == "run" && -n "$third" ]]; then
                print -r -- "$exe:$third"
            elif [[ -n "$next" && "$next" != -* ]]; then
                print -r -- "$exe $next"
            else
                print -r -- "$exe"
            fi
            return 0
            ;;
        yarn)
            if [[ "$next" == "run" && -n "$third" ]]; then
                print -r -- "yarn:$third"
            elif [[ -n "$next" && "$next" != -* ]]; then
                print -r -- "yarn:$next"
            else
                print -r -- "yarn"
            fi
            return 0
            ;;
        ruby)
            if [[ "$next" == "-S" && -n "$third" ]]; then
                print -r -- "${third:t}"
            else
                print -r -- "$exe"
            fi
            return 0
            ;;
        docker)
            if [[ "$next" == "compose" ]]; then
                if [[ -n "$third" && "$third" != -* ]]; then
                    print -r -- "docker compose $third"
                else
                    print -r -- "docker compose"
                fi
            elif [[ -n "$next" && "$next" != -* ]]; then
                print -r -- "docker $next"
            else
                print -r -- "docker"
            fi
            return 0
            ;;
        git|gh|gt|go|cargo|swift|terraform|kubectl|helm|make)
            if [[ -n "$next" && "$next" != -* ]]; then
                print -r -- "$exe $next"
            else
                print -r -- "$exe"
            fi
            return 0
            ;;
        rails|rake)
            if [[ -n "$next" && "$next" != -* ]]; then
                print -r -- "$exe $next"
            else
                print -r -- "$exe"
            fi
            return 0
            ;;
    esac

    print -r -- "$exe"
}

_shuttle_emit_pwd() {
    local host="${HOST:-localhost}"
    local encoded
    encoded="$(_shuttle_urlencode_path "$PWD")"
    printf '\e]7;file://%s%s\a' "$host" "$encoded"
}

_shuttle_emit_title() {
    local title="$1"
    [[ -n "$title" ]] || title="$(_shuttle_idle_title)"
    printf '\e]2;%s\a' "$title"
}

_shuttle_precmd() {
    if [[ "${_SHUTTLE_HOOKS_REORDERED:-0}" != "1" ]]; then
        typeset -g _SHUTTLE_HOOKS_REORDERED=1
        _shuttle_install_title_hooks
    fi
    _shuttle_emit_pwd
    _shuttle_emit_title "$(_shuttle_idle_title)"
}

_shuttle_preexec() {
    local cmd="$1"
    [[ -n "$cmd" ]] || return 0
    _shuttle_emit_title "$(_shuttle_command_title "$cmd")"
}

_shuttle_install_title_hooks() {
    add-zsh-hook -d precmd _shuttle_precmd 2>/dev/null || true
    add-zsh-hook -d preexec _shuttle_preexec 2>/dev/null || true
    add-zsh-hook precmd _shuttle_precmd
    add-zsh-hook preexec _shuttle_preexec
}

_shuttle_install_title_hooks
