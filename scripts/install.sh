#!/usr/bin/env bash
# User-local installer for hyprhand. Idempotent: re-run it to update.
#
#   scripts/install.sh                 build + install into ~/.local
#   scripts/install.sh --update        git pull --ff-only, then install
#   scripts/install.sh --uninstall     remove what a previous install recorded
#
# Options:
#   --prefix DIR        install prefix (default: $HOME/.local)
#   --no-pip            skip the optional GTK4 preview viewer
#   --with-bridge       also build the experimental headless format bridge
#                       (needed for headless sessions on NVIDIA; Aquamarine 0.15.x)
#   --no-skills         do not link the agent skill into ~/.claude / ~/.codex
#   --remove-legacy     remove a pre-rename deskctl install from the prefix
#   --skip-tests        skip `zig build test` before installing
#
# Never edits Hyprland configuration and never needs root.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREFIX="$HOME/.local"
PIP=auto
BRIDGE=0
SKILLS=1
LEGACY=0
TESTS=1
MODE=install

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift ;;
        --prefix=*) PREFIX=${1#--prefix=} ;;
        --no-pip) PIP=0 ;;
        --with-bridge) BRIDGE=1 ;;
        --no-skills) SKILLS=0 ;;
        --remove-legacy) LEGACY=1 ;;
        --skip-tests) TESTS=0 ;;
        --update) MODE=update ;;
        --uninstall) MODE=uninstall ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

case "$PREFIX" in /*) ;; *) die "--prefix must be absolute" ;; esac
MANIFEST="$PREFIX/share/hyprhand/install-manifest.txt"
SKILL_DIRS=("$HOME/.claude/skills" "$HOME/.codex/skills")

link_skill() {
    local parent=$1 target="$PREFIX/share/hyprhand/skills/hyprhand" link
    link="$parent/hyprhand"
    [ -d "$parent" ] || return 0
    if [ -L "$link" ]; then
        ln -sfn "$target" "$link"
    elif [ -e "$link" ]; then
        say "keeping existing non-symlink $link"
        return 0
    else
        ln -s "$target" "$link"
    fi
    printf '%s\n' "$link" >> "$MANIFEST"
    say "skill linked: $link"
}

remove_legacy() {
    local path
    for path in "$PREFIX/bin/deskctl" \
                "$PREFIX/share/bash-completion/completions/deskctl" \
                "$PREFIX/share/fish/vendor_completions.d/deskctl.fish"; do
        if [ -e "$path" ] || [ -L "$path" ]; then rm -f -- "$path"; say "removed legacy $path"; fi
    done
    if [ -d "$PREFIX/share/deskctl" ]; then rm -rf -- "$PREFIX/share/deskctl"; say "removed legacy $PREFIX/share/deskctl"; fi
    for path in "${SKILL_DIRS[@]}"; do
        # Only symlinks; never real directories.
        if [ -L "$path/deskctl" ]; then rm -f -- "$path/deskctl"; say "removed legacy skill link $path/deskctl"; fi
    done
}

uninstall() {
    [ -f "$MANIFEST" ] || die "no install manifest at $MANIFEST"
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in "$PREFIX"/*|"$HOME"/.claude/skills/hyprhand|"$HOME"/.codex/skills/hyprhand) ;; *) continue ;; esac
        if [ -L "$path" ] || [ -f "$path" ]; then rm -f -- "$path"; fi
    done < "$MANIFEST"
    rm -rf -- "$PREFIX/share/hyprhand"
    rmdir -- "$PREFIX/lib/hyprhand" 2>/dev/null || true
    say "hyprhand removed from $PREFIX"
}

if [ "$MODE" = uninstall ]; then uninstall; exit 0; fi

cd "$ROOT"
if [ "$MODE" = update ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then die "working tree has changes; commit or stash before --update"; fi
    say "git pull --ff-only"
    git pull --ff-only
fi

command -v zig >/dev/null || die "zig not found (need $(cat .zigversion))"
want=$(tr -d '\n' < .zigversion)
have=$(zig version)
[ "${have%.*}" = "${want%.*}" ] || die "zig $have found, need ${want%.*}.x (pinned $want)"
for tool in pkg-config wayland-scanner; do command -v "$tool" >/dev/null || die "$tool not found"; done
for module in wayland-client xkbcommon atspi-2 gobject-2.0; do
    pkg-config --exists "$module" || die "missing development package for $module"
done
for tool in grim Hyprland; do command -v "$tool" >/dev/null || say "warning: $tool not in PATH (needed at runtime)"; done

if [ "$PIP" = auto ]; then
    if pkg-config --atleast-version=4.8 gtk4 2>/dev/null; then PIP=1; else PIP=0; say "GTK4 >= 4.8 not found; skipping the preview viewer"; fi
fi

if [ "$TESTS" = 1 ]; then
    say "zig build test"
    zig build test -Doptimize=ReleaseSafe
fi

steps=(install)
if [ "$PIP" = 1 ]; then steps+=(pip); fi
say "zig build ${steps[*]} --prefix $PREFIX"
zig build "${steps[@]}" -Doptimize=ReleaseSafe --prefix "$PREFIX"

BRIDGE_DIR="$PREFIX/lib/hyprhand"
BRIDGE_LIB="$BRIDGE_DIR/hyprhand-headless-formats.so"
if [ "$BRIDGE" = 1 ]; then
    command -v "${CXX:-c++}" >/dev/null || die "C++ compiler not found (needed by --with-bridge)"
    pkg-config --exists aquamarine pixman-1 libdrm || die "--with-bridge needs aquamarine, pixman and libdrm development files"
    say "zig build headless-bridge --prefix-lib-dir $BRIDGE_DIR"
    zig build headless-bridge -Doptimize=ReleaseSafe --prefix "$PREFIX" --prefix-lib-dir "$BRIDGE_DIR"
    chmod go-w "$BRIDGE_LIB"
fi

if [ "$LEGACY" = 1 ]; then remove_legacy; fi

mkdir -p "$(dirname "$MANIFEST")"
{
    printf '%s\n' "$PREFIX/bin/hyprhand" \
        "$PREFIX/share/bash-completion/completions/hyprhand" \
        "$PREFIX/share/fish/vendor_completions.d/hyprhand.fish"
    if [ "$PIP" = 1 ]; then printf '%s\n' "$PREFIX/bin/hyprhand-pip"; fi
    if [ -f "$BRIDGE_LIB" ]; then printf '%s\n' "$BRIDGE_LIB" "$BRIDGE_LIB.build-metadata"; fi
} > "$MANIFEST"
if [ "$SKILLS" = 1 ]; then
    for parent in "${SKILL_DIRS[@]}"; do link_skill "$parent"; done
fi

version=$("$PREFIX/bin/hyprhand" --version)
say "installed $version into $PREFIX"
if [ -f "$BRIDGE_LIB" ]; then
    say "headless bridge: hyprhand session create NAME --headless-bridge $BRIDGE_LIB"
fi
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) say "add $PREFIX/bin to PATH" ;; esac
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    if "$PREFIX/bin/hyprhand" doctor --session host >/dev/null; then say "doctor --session host: ok"; else say "doctor --session host reported problems; run it for details"; fi
else
    say "run 'hyprhand doctor --session host' from a terminal inside Hyprland"
fi
