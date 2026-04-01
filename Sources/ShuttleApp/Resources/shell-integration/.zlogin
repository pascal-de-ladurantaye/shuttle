# Shuttle zlogin shim.
if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${SHUTTLE_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$SHUTTLE_ZSH_ZDOTDIR"
    builtin unset SHUTTLE_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi
builtin typeset _shuttle_file="${ZDOTDIR-$HOME}/.zlogin"
[[ ! -r "$_shuttle_file" ]] || builtin source -- "$_shuttle_file"
builtin unset _shuttle_file
