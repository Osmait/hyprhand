#!/bin/sh
set -eu
if [ "$(pkg-config --modversion aquamarine)" != '0.15.0' ]; then
    echo 'Experimental headless bridge requires Aquamarine 0.15.0 headers and library' >&2
    exit 1
fi
exec c++ -std=c++23 -shared -fPIC -O2 $(pkg-config --cflags aquamarine pixman-1 libdrm) \
    "$1" -o "$2" $(pkg-config --libs aquamarine)
