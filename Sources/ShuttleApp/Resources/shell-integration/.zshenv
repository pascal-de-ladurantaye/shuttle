# Shuttle ZDOTDIR bootstrap for zsh.
#
# Restore the user's real ZDOTDIR immediately, source their real .zshenv, then
# load Ghostty + Shuttle integration for interactive shells.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${SHUTTLE_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$SHUTTLE_ZSH_ZDOTDIR"
    builtin unset SHUTTLE_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    builtin typeset _shuttle_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_shuttle_file" ]] || builtin source -- "$_shuttle_file"
} always {
    if [[ -o interactive ]]; then
        if [[ "${SHUTTLE_LOAD_GHOSTTY_ZSH_INTEGRATION:-0}" == "1" ]]; then
            if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
                builtin typeset _shuttle_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
                [[ -r "$_shuttle_ghostty" ]] && builtin source -- "$_shuttle_ghostty"
            fi
        fi

        if [[ "${SHUTTLE_SHELL_INTEGRATION:-1}" != "0" && -n "${SHUTTLE_SHELL_INTEGRATION_DIR:-}" ]]; then
            builtin typeset _shuttle_integ="$SHUTTLE_SHELL_INTEGRATION_DIR/shuttle-zsh-integration.zsh"
            [[ -r "$_shuttle_integ" ]] && builtin source -- "$_shuttle_integ"
        fi
    fi

    builtin unset _shuttle_file _shuttle_ghostty _shuttle_integ
}
