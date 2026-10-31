#!/usr/bin/env bash
# (Re)create the stand-in desktop "demo-host" and its host alias (wayland-demo).
set -eu
# Creates a headless session "demo-host" that stands in for the user's desktop, and
# exposes it to hyprhand as a host (instance alias + wayland-demo socket link) so a
# terminal inside it can create sessions and open previews there. Recording-only:
# it never touches the real desktop. Remove the alias afterwards.
D=${TOUR_STATE:-${XDG_RUNTIME_DIR:?}/hyprhand-tour}
mkdir -p "$D"
sess() { hyprhand session inspect "$1" | jq -r ".session.$2"; }
hc() {
    local s=$1; shift
    local r i; r=$(sess "$s" runtime); i=$(sess "$s" instance)
    XDG_RUNTIME_DIR=$r HYPRLAND_INSTANCE_SIGNATURE=$i hyprctl "$@"
}
hyprhand session destroy demo-host >/dev/null 2>&1 || true
old=$(cat $D/alias-sig 2>/dev/null || true)
[ -n "$old" ] && rm -rf "$XDG_RUNTIME_DIR/hypr/$old"
rm -f $XDG_RUNTIME_DIR/wayland-demo
hyprhand session create demo-host --headless-bridge "${HYPRHAND_BRIDGE:-$HOME/.local/lib/hyprhand/hyprhand-headless-formats.so}" >/dev/null
R=$(sess demo-host runtime); S=$(sess demo-host instance)
hc demo-host eval "hl.monitor({output='HEADLESS-1',mode='1024x1024@60',position='0x0',scale=1})" >/dev/null
hc demo-host eval "hl.config({general={gaps_in=0,gaps_out=0,border_size=0},ecosystem={no_donation_nag=true,no_update_news=true}})" >/dev/null
F=$XDG_RUNTIME_DIR/hypr/$S
mkdir -m 700 "$F"
ln -s "$R/hypr/$S/.socket.sock" "$F/.socket.sock"
ln -s "$R/hypr/$S/.socket2.sock" "$F/.socket2.sock"
printf '%s\nwayland-demo\n' "$(head -1 $R/hypr/$S/hyprland.lock)" > "$F/hyprland.lock"
chmod 600 "$F/hyprland.lock"
ln -s "$R/wayland-1" $XDG_RUNTIME_DIR/wayland-demo
echo "$S" > $D/alias-sig
hyprhand enable --session demo-host >/dev/null
echo "demo-host ready. In a terminal inside it, use:"
echo "  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE=$S WAYLAND_DISPLAY=wayland-demo"
