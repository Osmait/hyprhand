#!/bin/sh
set -eu
set -f
if [ "$#" -ne 2 ]; then
    echo 'Usage: build.sh SOURCE.cpp OUTPUT.so (compile only; never preloads a bridge)' >&2
    exit 2
fi
if [ "$(pkg-config --modversion aquamarine)" != '0.15.0' ]; then
    echo 'Experimental headless bridge requires Aquamarine 0.15.0 headers and library' >&2
    exit 1
fi
compiler=${CXX:-c++}
command -v "$compiler" >/dev/null
command -v sha256sum >/dev/null
case $1 in /*) source=$1 ;; *) source=$PWD/$1 ;; esac
case $2 in /*) output=$2 ;; *) output=$PWD/$2 ;; esac
test -f "$source"
cflags=$(pkg-config --cflags aquamarine pixman-1 libdrm)
libs=$(pkg-config --libs aquamarine)
umask 077
build_dir=$(mktemp -d "${output}.build.XXXXXX")
cleanup() {
    rm -f -- "$build_dir/artifact.so" "$build_dir/artifact.so.build-metadata" "$build_dir/macros"
    rmdir -- "$build_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Preserve the interposed method; no backend layout or vtable rewrites.
# pkg-config flags are word-split, never evaluated or globbed. This bridge
# links Aquamarine, so unresolved references here are a build failure.
"$compiler" -std=c++23 -shared -fPIC -O2 -Wall -Wextra \
    -Werror=return-type -Werror=uninitialized -Wl,-z,defs,-z,relro,-z,now \
    $cflags "$source" -o "$build_dir/artifact.so" $libs
printf '#include <string>\n' | \
    "$compiler" -std=c++23 $cflags -dM -E -x c++ - > "$build_dir/macros"
source_hash=$(sha256sum < "$source")
binary_hash=$(sha256sum < "$build_dir/artifact.so")
compiler_target=$("$compiler" -dumpmachine)
{
    printf 'format=hyprhand-experimental-build-v1\nbridge=headless-formats\n'
    printf 'aquamarine=0.15.0\nsource_sha256=%s\nbinary_sha256=%s\n' "${source_hash%% *}" "${binary_hash%% *}"
    printf 'compiler=%s\ncompiler_target=%s\n' "$compiler" "$compiler_target"
    "$compiler" --version
    printf 'flags=-std=c++23 -shared -fPIC -O2 -Wall -Wextra -Werror=return-type -Werror=uninitialized -Wl,-z,defs,-z,relro,-z,now\npkg_cflags=%s\npkg_libs=%s\n' "$cflags" "$libs"
    for package in pixman-1 libdrm; do
        package_version=$(pkg-config --modversion "$package")
        printf '%s=%s\n' "$package" "$package_version"
    done
    LC_ALL=C sed -n '/^#define _GLIBCXX_USE_CXX11_ABI /p; /^#define __GLIBCXX__ /p; /^#define _LIBCPP_VERSION /p' "$build_dir/macros"
} > "$build_dir/artifact.so.build-metadata"
# Each rename is atomic; the pair is not. Verify the recorded binary checksum.
mv -fT -- "$build_dir/artifact.so.build-metadata" "$output.build-metadata"
mv -fT -- "$build_dir/artifact.so" "$output"
printf 'Built (not loaded): %s\nBuild metadata: %s\n' "$output" "$output.build-metadata"
