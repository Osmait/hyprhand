_deskctl_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local commands='doctor state monitors windows workspaces sessions session launch observe preview focus workspace move click doubleclick drag scroll type key stop enable wait events logs gc accessibility'
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == session && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'create inspect destroy' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == wait && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'stable window focus workspace' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == preview ]]; then
        COMPREPLY=( $(compgen -W '--session --monitor --fps' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --backend ]]; then
        COMPREPLY=( $(compgen -W 'auto native helper' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --scroll-mode ]]; then
        COMPREPLY=( $(compgen -W 'auto wheel continuous' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --indicator ]]; then
        COMPREPLY=( $(compgen -W 'none outline' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --headless-bridge ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
    else
        COMPREPLY=( $(compgen -W '--session --window --monitor --frame --x --y --to-x --to-y --duration-ms --scroll-mode --move-duration-ms --no-aura --indicator --headless-bridge --button --dx --dy --text --backend --dry-run --timeout-ms --stable-ms --pixels --class --workspace --limit --depth --older-than-ms --nested --lua' -- "$cur") )
    fi
}
complete -F _deskctl_complete deskctl
