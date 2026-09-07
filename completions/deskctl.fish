complete -c deskctl -f
complete -c deskctl -n '__fish_use_subcommand' -a 'doctor state monitors windows workspaces sessions session launch observe preview focus workspace move click doubleclick drag scroll type key stop enable wait events logs gc accessibility'
complete -c deskctl -n '__fish_seen_subcommand_from preview' -l fps -r -a '1 5 10 15' -d 'Read-only PiP maximum capture frequency'
complete -c deskctl -n '__fish_seen_subcommand_from session' -a 'create inspect destroy'
complete -c deskctl -n '__fish_seen_subcommand_from wait' -a 'stable window focus workspace'
complete -c deskctl -l session -r -d 'Explicit target session'
complete -c deskctl -l backend -r -a 'auto native helper'
complete -c deskctl -l scroll-mode -r -a 'auto wheel continuous'
complete -c deskctl -l indicator -r -a 'none outline'
complete -c deskctl -l headless-bridge -r -F -d 'Experimental trusted library, new headless compositor only'
for option in window monitor frame x y to-x to-y duration-ms move-duration-ms button dx dy text timeout-ms stable-ms class workspace limit depth older-than-ms
    complete -c deskctl -l $option -r
end
for option in dry-run pixels nested lua no-aura
    complete -c deskctl -l $option
end
