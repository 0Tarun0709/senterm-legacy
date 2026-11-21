# Source from .zshrc to enable prompt navigation and directory display in senterm.
[[ $TERM_PROGRAM == senterm && -o interactive ]] || return 0
autoload -Uz add-zsh-hook

_senterm_precmd() {
    local exit_code=$?
    if [[ -n ${_senterm_started-} ]]; then
        if (( SECONDS - _senterm_started >= 10 )); then
            printf '\e]7502;senterm-done;%d\a' "$exit_code"
        fi
        unset _senterm_started
    fi
    emulate -L zsh
    unsetopt multibyte
    local LC_ALL=C encoded='' byte escaped i
    for (( i = 1; i <= ${#PWD}; i++ )); do
        byte=${PWD[i]}
        case $byte in
            [a-zA-Z0-9/._~-]) encoded+=$byte ;;
            *) printf -v escaped '%%%02X' "'$byte"; encoded+=$escaped ;;
        esac
    done
    printf '\e]7;file://%s\a\e]133;D;%d\a\e]133;P;k=i\a' "$encoded" "$exit_code"
}

_senterm_preexec() {
    _senterm_started=$SECONDS
    printf '\e]133;C\a'
}

add-zsh-hook precmd _senterm_precmd
add-zsh-hook preexec _senterm_preexec

if [[ -n ${SENTERM_DIFF_TOKEN-} ]]; then
    typeset -g _senterm_diff_token=$SENTERM_DIFF_TOKEN
    unset SENTERM_DIFF_TOKEN
    # shortcut: handle plain and staged diffs only; leave other arguments to git.
    function git {
        local scope
        if [[ $1 == diff && -t 0 && -t 1 && -t 2 && -z ${GIT_DIR-}${GIT_WORK_TREE-}${GIT_INDEX_FILE-} ]]; then
            if (( $# == 1 )); then
                scope=unstaged
            elif (( $# == 2 )) && [[ $2 == --cached || $2 == --staged ]]; then
                scope=staged
            fi
            if [[ -n $scope && $(command git rev-parse --is-inside-work-tree 2>/dev/null) == true ]]; then
                printf '\e]7503;%s;%s\a' "$_senterm_diff_token" "$scope"
                return
            fi
        fi
        command git "$@"
    }
fi
