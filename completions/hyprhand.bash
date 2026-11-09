_hyprhand_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local commands='doctor state monitors windows workspaces sessions session launch observe cursor preview focus workspace move click doubleclick drag scroll type key act sequence journal replay dialect stop enable wait events logs gc accessibility'
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == session && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'create inspect destroy' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == dialect && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'anthropic openai gemini' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == journal && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'start stop show' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == act && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'click focus set-value toggle check uncheck expand collapse select scroll-to' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == wait && $COMP_CWORD == 2 ]]; then
        COMPREPLY=( $(compgen -W 'stable window focus workspace' -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == preview ]]; then
        COMPREPLY=( $(compgen -W '--session --monitor --host-monitor --fps' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --backend ]]; then
        COMPREPLY=( $(compgen -W 'auto native helper clipboard' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --scroll-mode ]]; then
        COMPREPLY=( $(compgen -W 'auto wheel continuous' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --gate ]]; then
        COMPREPLY=( $(compgen -W 'ask human off' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --then ]]; then
        COMPREPLY=( $(compgen -W 'state observe accessibility' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --button ]]; then
        COMPREPLY=( $(compgen -W 'left right middle back forward' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --indicator ]]; then
        COMPREPLY=( $(compgen -W 'none outline' -- "$cur") )
    elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --headless-bridge ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
    else
        COMPREPLY=( $(compgen -W '--session --window --monitor --frame --x --y --to-x --to-y --duration-ms --scroll-mode --move-duration-ms --no-aura --indicator --headless-bridge --button --dx --dy --text --backend --dry-run --timeout-ms --stable-ms --pixels --class --workspace --limit --depth --older-than-ms --nested --lua --retry --max-edge --since --compact --count --mods --repeat --ref --interactive --sandbox --offline --then --settle-ms --marks --mark --gate --ack --execute --confirmed' -- "$cur") )
    fi
}
complete -F _hyprhand_complete hyprhand
