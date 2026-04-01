# Fallback shim: restore the real ZDOTDIR and source the user's real .zshrc.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${SHUTTLE_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$SHUTTLE_ZSH_ZDOTDIR"
    builtin unset SHUTTLE_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _shuttle_file="${ZDOTDIR-$HOME}/.zshrc"
[[ ! -r "$_shuttle_file" ]] || builtin source -- "$_shuttle_file"

if [[ -o interactive ]]; then
    if (( $+functions[_shuttle_install_title_hooks] )); then
        _shuttle_install_title_hooks
    elif [[ "${SHUTTLE_SHELL_INTEGRATION:-1}" != "0" && -n "${SHUTTLE_SHELL_INTEGRATION_DIR:-}" ]]; then
        builtin typeset _shuttle_integ="$SHUTTLE_SHELL_INTEGRATION_DIR/shuttle-zsh-integration.zsh"
        [[ ! -r "$_shuttle_integ" ]] || builtin source -- "$_shuttle_integ"
    fi
fi

builtin unset _shuttle_file _shuttle_integ
