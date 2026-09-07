complete -c hyprhand -f
complete -c hyprhand -n '__fish_use_subcommand' -a 'doctor state monitors windows workspaces sessions session launch observe preview focus workspace move click doubleclick drag scroll type key stop enable wait events logs gc accessibility'
complete -c hyprhand -n '__fish_seen_subcommand_from preview' -l fps -r -a '1 5 10 15' -d 'Read-only PiP maximum capture frequency'
complete -c hyprhand -n '__fish_seen_subcommand_from session' -a 'create inspect destroy'
complete -c hyprhand -n '__fish_seen_subcommand_from wait' -a 'stable window focus workspace'
complete -c hyprhand -l session -r -d 'Explicit target session'
complete -c hyprhand -l backend -r -a 'auto native helper'
complete -c hyprhand -l scroll-mode -r -a 'auto wheel continuous'
complete -c hyprhand -l indicator -r -a 'none outline'
complete -c hyprhand -l headless-bridge -r -F -d 'Experimental trusted library, new headless compositor only'
for option in window monitor frame x y to-x to-y duration-ms move-duration-ms button dx dy text timeout-ms stable-ms class workspace limit depth older-than-ms
    complete -c hyprhand -l $option -r
end
for option in dry-run pixels nested lua no-aura
    complete -c hyprhand -l $option
end
