#!/bin/bash
# Build the host-native iSH emulator CLI.
#
# This is a separate build from the one that produces the iOS libraries: the
# `ish` executable is only built for native targets (meson.build gates it on
# `not meson.is_cross_build()`), and it needs libarchive so that fakefsify can
# turn a tar into a fakefs.
#
# It exists because the guest image is built by *running* an Alpine userspace,
# and the only honest way to do that is inside the same emulator the app uses.
# Building the image by assembling a tar on the host would produce something
# that has never run.
#
# Output: build/ish/host/cli/ish, .../tools/fakefsify, .../tools/unfakefsify
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ISH_DIR/.." && pwd)"
SRC="$ISH_DIR/src/ish-arm64"

CLEAN=0
while getopts ":Ch" opt; do
    case "$opt" in
        C) CLEAN=1 ;;
        h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=../../scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"

BUILD_ROOT="$ROOT/build/ish/host/cli"
[ "$CLEAN" = 1 ] && rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
BUILD_DIR="$BUILD_ROOT/ninja"

"$ISH_DIR/scripts/fetch-sources.sh" --check

# libarchive lives in Homebrew on this machine. The emulator's own build system
# looks in both Homebrew prefixes, but only via find_library, which needs the
# directory in the library path.
LIBARCHIVE_PREFIX="${LIBARCHIVE_PREFIX:-}"
if [ -z "$LIBARCHIVE_PREFIX" ]; then
    for candidate in /opt/homebrew/opt/libarchive /usr/local/opt/libarchive; do
        if [ -f "$candidate/lib/libarchive.a" ] || [ -f "$candidate/lib/libarchive.dylib" ]; then
            LIBARCHIVE_PREFIX="$candidate"
            break
        fi
    done
fi
[ -n "$LIBARCHIVE_PREFIX" ] || die "libarchive not found; set LIBARCHIVE_PREFIX=<prefix>"

libarchive_cflags="-I$LIBARCHIVE_PREFIX/include"
libarchive_ldflags="-L$LIBARCHIVE_PREFIX/lib"
export CPPFLAGS="$libarchive_cflags ${CPPFLAGS:-}"
export CFLAGS="$libarchive_cflags ${CFLAGS:-}"
export LDFLAGS="$libarchive_ldflags ${LDFLAGS:-}"

log "libarchive: $LIBARCHIVE_PREFIX"
log "natively compiled (this is the emulator the rootfs is built inside)"

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    "$MESON" setup "$BUILD_DIR" "$SRC" \
        --buildtype release \
        -Db_ndebug=true \
        -Dlog= \
        -Dlog_handler=dprintf \
        -Dkernel=ish \
        -Dengine=asbestos \
        -Dguest_arch=arm64
fi

"$NINJA" -C "$BUILD_DIR" ish tools/fakefsify tools/unfakefsify

for tool in ish tools/fakefsify tools/unfakefsify; do
    [ -e "$BUILD_DIR/$tool" ] || die "$tool was not built"
done

VDSO="$BUILD_DIR/vdso/arm64/libvdso.so.elf"
[ -s "$VDSO" ] || die "the guest VDSO is empty — nothing the guest runs would work"
file "$VDSO" | grep -q 'ELF 64-bit LSB.*ARM aarch64' \
    || die "the guest VDSO is not an aarch64 ELF: $(file "$VDSO")"

log "products"
for tool in ish tools/fakefsify; do
    printf '  %-18s %8s bytes\n' "$tool" "$(stat -f%z "$BUILD_DIR/$tool")"
done
