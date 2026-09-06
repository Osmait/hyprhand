#!/bin/sh
set -eu
if [ "$(pkg-config --modversion hyprland)" != '0.56.2' ]; then
    echo 'Experimental cursor bridge requires Hyprland 0.56.2 headers' >&2
    exit 1
fi
# pkg-config compiler flags are intentionally word-split, not evaluated.
exec c++ -std=c++23 -shared -fPIC -O2 $(pkg-config --cflags hyprland) \
    "$1" -o "$2"
