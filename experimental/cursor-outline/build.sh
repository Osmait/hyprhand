#!/bin/sh
set -eu
set -f
if [ "$#" -ne 2 ]; then
    echo 'Usage: build.sh SOURCE.cpp OUTPUT.so (compile only; never loads a plugin)' >&2
    exit 2
fi
if [ "$(pkg-config --modversion hyprland)" != '0.56.2' ]; then
    echo 'Experimental cursor bridge requires Hyprland 0.56.2 headers' >&2
    exit 1
fi
compiler=${CXX:-c++}
command -v "$compiler" >/dev/null
command -v sha256sum >/dev/null
case $1 in /*) source=$1 ;; *) source=$PWD/$1 ;; esac
case $2 in /*) output=$2 ;; *) output=$PWD/$2 ;; esac
test -f "$source"
cflags=$(pkg-config --cflags hyprland)
umask 077
build_dir=$(mktemp -d "${output}.build.XXXXXX")
cleanup() {
    rm -f -- "$build_dir/artifact.so" "$build_dir/artifact.so.build-metadata" "$build_dir/macros"
    rmdir -- "$build_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# pkg-config flags are intentionally word-split, never evaluated or globbed.
# Undefined Hyprland symbols are expected: the explicitly selected compositor
# resolves them. Do not use -z defs or attempt to load the result as a check.
"$compiler" -std=c++23 -shared -fPIC -O2 -Wall -Wextra \
    -Werror=return-type -Werror=uninitialized -Wl,-z,relro,-z,now \
    $cflags "$source" -o "$build_dir/artifact.so"
printf '#include <hyprland/src/version.h>\n#include <string>\n' | \
    "$compiler" -std=c++23 $cflags -dM -E -x c++ - > "$build_dir/macros"
source_hash=$(sha256sum < "$source")
binary_hash=$(sha256sum < "$build_dir/artifact.so")
compiler_target=$("$compiler" -dumpmachine)
{
    printf 'format=deskctl-experimental-build-v1\nbridge=cursor-outline\n'
    printf 'hyprland=0.56.2\nsource_sha256=%s\nbinary_sha256=%s\n' "${source_hash%% *}" "${binary_hash%% *}"
    printf 'compiler=%s\ncompiler_target=%s\n' "$compiler" "$compiler_target"
    "$compiler" --version
    printf 'flags=-std=c++23 -shared -fPIC -O2 -Wall -Wextra -Werror=return-type -Werror=uninitialized -Wl,-z,relro,-z,now\npkg_cflags=%s\n' "$cflags"
    # Record header dependency versions and C++ library ABI switches, without
    # claiming that this small fingerprint proves binary compatibility.
    LC_ALL=C sed -n '/^#define GIT_/p; /^#define .*VERSION /p; /^#define _GLIBCXX_USE_CXX11_ABI /p; /^#define __GLIBCXX__ /p; /^#define _LIBCPP_VERSION /p' "$build_dir/macros"
} > "$build_dir/artifact.so.build-metadata"
# Publish only after compilation and provenance collection both succeed.
# The checksum detects an interrupted two-file publication; the pair is not
# transactional. On ordinary compiler failure an existing result is untouched.
mv -fT -- "$build_dir/artifact.so.build-metadata" "$output.build-metadata"
mv -fT -- "$build_dir/artifact.so" "$output"
printf 'Built (not loaded): %s\nBuild metadata: %s\n' "$output" "$output.build-metadata"
