# Restore the user's startup directory before running any user startup files.
_senterm_integration=$ZDOTDIR/shell-integration.zsh
if [[ -v SENTERM_ORIGINAL_ZDOTDIR ]]; then
    export ZDOTDIR=$SENTERM_ORIGINAL_ZDOTDIR
    unset SENTERM_ORIGINAL_ZDOTDIR
else
    unset ZDOTDIR
fi
if [[ -r ${ZDOTDIR-$HOME}/.zshenv ]]; then
    source "${ZDOTDIR-$HOME}/.zshenv"
fi
if [[ -o rcs && -r $_senterm_integration ]]; then
    source "$_senterm_integration"
fi
unset _senterm_integration
