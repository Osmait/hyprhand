complete -c hyprhand -f
complete -c hyprhand -n '__fish_use_subcommand' -a 'doctor state monitors windows workspaces sessions session launch observe cursor preview focus workspace move click doubleclick drag scroll type key act sequence journal replay stop enable wait events logs gc accessibility'
complete -c hyprhand -n '__fish_seen_subcommand_from preview' -l fps -r -a '1 5 10 15' -d 'PiP maximum capture frequency'
complete -c hyprhand -n '__fish_seen_subcommand_from preview' -l host-monitor -r -d 'Host monitor for the PiP window'
complete -c hyprhand -n '__fish_seen_subcommand_from observe' -l retry -r -a '0 1 2 3' -d 'Retry timeouts and stale frames'
complete -c hyprhand -n '__fish_seen_subcommand_from observe' -l max-edge -r -a '1568 1920 2576' -d 'Longest image side in pixels'
complete -c hyprhand -n '__fish_seen_subcommand_from observe' -l since -r -d 'Report changed and a pixel diff'
complete -c hyprhand -n '__fish_seen_subcommand_from observe' -l marks -d 'Number the operable elements'
complete -c hyprhand -n '__fish_seen_subcommand_from move click doubleclick drag scroll' -l mark -r -d 'Aim at a mark of --frame'
complete -c hyprhand -n '__fish_seen_subcommand_from state windows' -l compact -d 'Short window summary'
complete -c hyprhand -n '__fish_seen_subcommand_from click' -l count -r -a '1 2 3' -d 'Single, double or triple click'
complete -c hyprhand -n '__fish_seen_subcommand_from click doubleclick drag scroll' -l mods -r -a 'ctrl shift alt super ctrl+shift' -d 'Modifiers held during the action'
complete -c hyprhand -n '__fish_seen_subcommand_from key' -l repeat -r -d 'Tap the chord N times'
complete -c hyprhand -l button -r -a 'left right middle back forward'
complete -c hyprhand -n '__fish_seen_subcommand_from enable' -l gate -r -a 'ask human off' -d 'Confirmation gate'
complete -c hyprhand -n '__fish_seen_subcommand_from act click doubleclick key' -l ack -r -d 'Confirmation ID the human agreed to'
complete -c hyprhand -l then -r -a 'state observe accessibility' -d 'Report after the action'
complete -c hyprhand -l settle-ms -r -d 'Pause before the --then report'
complete -c hyprhand -n '__fish_seen_subcommand_from act' -a 'click focus set-value toggle check uncheck expand collapse select scroll-to'
complete -c hyprhand -n '__fish_seen_subcommand_from act' -l ref -r -d 'Accessibility ref @SNAP:eN'
complete -c hyprhand -n '__fish_seen_subcommand_from accessibility' -l interactive -d 'Only elements with refs'
complete -c hyprhand -n '__fish_seen_subcommand_from session' -l sandbox -d 'Run apps in bubblewrap with a private home'
complete -c hyprhand -n '__fish_seen_subcommand_from session' -l offline -d 'Sandbox without network'
complete -c hyprhand -n '__fish_seen_subcommand_from journal' -a 'start stop show'
complete -c hyprhand -n '__fish_seen_subcommand_from replay' -l execute -d 'Run the steps instead of planning'
complete -c hyprhand -n '__fish_seen_subcommand_from session' -a 'create inspect destroy'
complete -c hyprhand -n '__fish_seen_subcommand_from wait' -a 'stable window focus workspace'
complete -c hyprhand -l session -r -d 'Explicit target session'
complete -c hyprhand -l backend -r -a 'auto native helper clipboard'
complete -c hyprhand -l scroll-mode -r -a 'auto wheel continuous'
complete -c hyprhand -l indicator -r -a 'none outline'
complete -c hyprhand -l headless-bridge -r -F -d 'Experimental trusted library, new headless compositor only'
for option in window monitor frame x y to-x to-y duration-ms move-duration-ms dx dy text timeout-ms stable-ms class workspace limit depth older-than-ms
    complete -c hyprhand -l $option -r
end
for option in dry-run pixels nested lua no-aura
    complete -c hyprhand -l $option
end
