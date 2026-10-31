#!/usr/bin/env bash
# Scripted hyprhand showcase. Every displayed command really runs; the
# terminal shows a compact summary of its JSON reply. Hidden lines (marked
# HIDDEN) only arrange the recording: display size, PiP placement, waits.
set -u
# Run it in a terminal on the desktop that should show the preview (the recording
# used the stand-in desktop from stand-in-host.sh). Stage files in $TOUR_STATE let
# a recorder and the person at the keyboard follow along.
TOUR_DIR=$(cd "$(dirname "$0")" && pwd)
D=${TOUR_STATE:-${XDG_RUNTIME_DIR:?}/hyprhand-tour}
mkdir -p "$D"
BRIDGE=${HYPRHAND_BRIDGE:-$HOME/.local/lib/hyprhand/hyprhand-headless-formats.so}
APP=file://$TOUR_DIR/northwind.html
COLS=96

c_dim=$'\e[38;5;244m'; c_cmd=$'\e[38;5;255m'; c_ok=$'\e[38;5;114m'; c_err=$'\e[38;5;210m'
c_head=$'\e[1;38;5;75m'; c_warn=$'\e[1;38;5;221m'; c_off=$'\e[0m'; c_prompt=$'\e[38;5;141m'

mark() { touch "$D/stage-$1"; }                       # HIDDEN: sync with recorder/human
pause() { sleep "${1:-0.8}"; }
chapter() { printf '\n%s%s%s\n' "$c_head" "$1" "$c_off"; pause 1.2; }
note() { printf '%s# %s%s\n' "$c_dim" "$1" "$c_off"; pause 0.6; }

typed() {
    printf '%s❯%s ' "$c_prompt" "$c_off"
    local text=$1 i
    for (( i = 0; i < ${#text}; i++ )); do
        printf '%s%s%s' "$c_cmd" "${text:i:1}" "$c_off"; sleep 0.014
    done
    printf '\n'; pause 0.25
}

# run 'command' 'jq filter': type it, run it, print one summarized JSON line.
run() {
    typed "$1"
    local out; out=$(eval "$1" 2>&1)
    local line; line=$(printf '%s' "$out" | jq -c "${2:-.}" 2>/dev/null || printf '%s' "$out")
    local colour=$c_ok
    if printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1; then colour=$c_err; fi
    printf '%s%s%s\n' "$colour" "$(printf '%s' "$line" | cut -c1-$COLS)" "$c_off"
    pause
}

# assign VAR 'command' 'jq -r path' 'label': fresh value, shown like a shell assignment.
assign() {
    typed "$1=\$($2 | jq -r '$3')"
    local value; value=$(eval "$2" 2>/dev/null | jq -r "$3")
    printf -v "$1" '%s' "$value"
    printf '%s%s = %s%s\n' "$c_ok" "$1" "$value" "$c_off"
    pause 0.5
}

hidden_agent_display() {                             # HIDDEN: legible size for the GIF
    local runtime instance
    runtime=$(hyprhand session inspect agent | jq -r .session.runtime)
    instance=$(hyprhand session inspect agent | jq -r .session.instance)
    XDG_RUNTIME_DIR=$runtime HYPRLAND_INSTANCE_SIGNATURE=$instance hyprctl eval \
        "hl.monitor({output='HEADLESS-1',mode='1024x576@60',position='0x0',scale=1})" >/dev/null
    XDG_RUNTIME_DIR=$runtime HYPRLAND_INSTANCE_SIGNATURE=$instance hyprctl eval \
        "hl.config({general={gaps_in=0,gaps_out=0,border_size=0},ecosystem={no_donation_nag=true,no_update_news=true}})" >/dev/null
}

wait_for() { until [ -e "$D/stage-$1" ]; do sleep 0.2; done; }   # HIDDEN

clear
printf '\n%.0s' {1..60}                          # HIDDEN: start at the bottom
printf '%s  hyprhand%s %s— computer use for Hyprland, from the command line%s\n' \
    "$c_head" "$c_off" "$c_dim" "$c_off"
printf '%s  JSON in, JSON out · native input · no MCP server%s\n' "$c_dim" "$c_off"
mark start
pause 2

chapter "1 · A private desktop for the agent"
run "hyprhand session create agent --headless-bridge \$BRIDGE" \
    '{ok, session: .session.name, nested: .session.nested}'
hidden_agent_display
run "hyprhand enable --session agent" '{ok, control}'
run "hyprhand launch --session agent -- brave --app=\$APP" '{ok, status, pid: .process.pid}'
sleep 3

chapter "2 · Watch it live in a picture-in-picture"
typed "hyprhand preview --session agent --fps 10 &"
hyprhand preview --session agent --fps 10 > "$D/preview-out.json" 2>&1 &
sleep 1.5
printf '%s%s%s\n' "$c_ok" "$(jq -c '{event, session_id, fps}' "$D/preview-out.json" 2>/dev/null)" "$c_off"
mark pip-up
wait_for pip-placed

chapter "3 · observe → act → observe again"
assign W "hyprhand windows --session agent" ".data[0].address"
assign F "hyprhand observe --session agent" ".frame.frame_id"
run "hyprhand click --session agent --frame \$F --x 512 --y 196" '{ok, action, status}'
run "hyprhand type --session agent --window \$W --text b.munoz" '{ok, action, status}'

chapter "4 · Login with captcha → the human takes over"
note "passwords and captchas are the human's job"
printf '%s⏸  Human: press “Take over” in the preview%s\n' "$c_warn" "$c_off"
mark handover
until [ "$(hyprhand state --session agent | jq -r .human_takeover)" = true ]; do sleep 0.3; done
run "hyprhand state --session agent" '{human_takeover, control_enabled}'
assign F "hyprhand observe --session agent" ".frame.frame_id"
run "hyprhand click --session agent --frame \$F --x 512 --y 411" '{ok, err: .err.code}'
note "agent input is blocked until the human presses Return"
until [ "$(hyprhand state --session agent | jq -r .human_takeover)" = false ]; do sleep 0.3; done
run "hyprhand state --session agent" '{human_takeover, control_enabled}'

chapter "5 · Read the screen: accessibility tree"
run "hyprhand accessibility --session agent --window \$W --depth 30 --limit 400" \
    '[.accessibility.nodes[] | select(.role=="heading") | .name]'

chapter "6 · Fill the form: Unicode, menus, drag, scroll"
assign F "hyprhand observe --session agent" ".frame.frame_id"
run "hyprhand click --session agent --frame \$F --x 302 --y 197" '{ok, status}'
run "hyprhand type --session agent --window \$W --text 'Begoña Muñoz Ibáñez'" '{ok, status}'
run "hyprhand click --session agent --frame \$F --x 710 --y 197" '{ok, status}'
assign F "hyprhand observe --session agent" ".frame.frame_id"
run "hyprhand click --session agent --frame \$F --x 563 --y 281" '{ok, status}'
assign F "hyprhand observe --session agent" ".frame.frame_id"
run "hyprhand drag --session agent --frame \$F --x 117 --y 266 --to-x 627 --to-y 266" '{ok, status}'
run "hyprhand click --session agent --frame \$F --x 506 --y 360" '{ok, status}'
run "hyprhand type --session agent --window \$W --text 'Impresora 2.ª planta: «error de cola»'" '{ok, status}'
run "hyprhand scroll --session agent --frame \$F --x 506 --y 480 --dy 5" '{ok, status}'
note "the page moved: observe again before the next click"
assign F "hyprhand observe --session agent" ".frame.frame_id"
run "hyprhand click --session agent --frame \$F --x 121 --y 422" '{ok, status}'
run "hyprhand click --session agent --frame \$F --x 833 --y 473" '{ok, status}'
sleep 1

chapter "7 · Verify the result, then clean up"
run "hyprhand accessibility --session agent --window \$W --depth 30 --limit 400" \
    '[.accessibility.nodes[] | select(.role=="heading") | .name]'
run "hyprhand stop --session agent" '{ok, control}'
run "hyprhand session destroy agent" '{ok, status}'
mark done
pause 3
note "the preview loses its signal; profiles and logs are kept"
sleep 30
