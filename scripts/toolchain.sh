#!/bin/bash
# Locate the build tools this repository needs, without touching the host.
#
# Everything is resolved from environment variables first, then from tools that
# already exist on this machine (including another task's tools/venv, read-only),
# and only then from $ROOT/tools. Nothing is installed globally and no shell
# profile is modified.
#
# Source it: `. scripts/toolchain.sh`
# It exports: DEVELOPER_DIR, CC_TOOL, AR_TOOL, LLD, MESON, NINJA, and prepends
# the directories they live in to PATH.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "toolchain: DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2
    return 1 2>/dev/null || exit 1
fi

# --- meson / ninja ---------------------------------------------------------
# A venv inside this task wins; then one from a sibling task (read-only); then
# whatever is on PATH. The sibling path is a fallback, not a dependency: the
# build must still work if that directory is gone.
find_tool() {
    local name="$1"; shift
    local candidate
    for candidate in "$@"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

MESON="${MESON:-$(find_tool meson \
    "$ROOT/tools/venv/bin/meson")}" || MESON=""
NINJA="${NINJA:-$(find_tool ninja \
    "$ROOT/tools/venv/bin/ninja")}" || NINJA=""

if [ -z "${MESON:-}" ] || [ -z "${NINJA:-}" ]; then
    echo "toolchain: meson and ninja are required; set MESON= and NINJA= or create tools/venv" >&2
    return 1 2>/dev/null || exit 1
fi
export MESON NINJA

# --- LLVM's linker ---------------------------------------------------------
# The guest VDSO is a real aarch64 Linux ELF shared object. Apple's ld cannot
# produce one, so the VDSO needs lld. Without it meson silently builds a stub
# and the guest cannot run a single process.
LLD="${LLD:-$(find_tool ld.lld \
    "$ROOT/tools/llvm/bin/ld.lld" \
    /opt/homebrew/opt/llvm/bin/ld.lld \
    /usr/local/opt/llvm/bin/ld.lld)}" || LLD=""
if [ -z "${LLD:-}" ]; then
    echo "toolchain: ld.lld not found. The guest VDSO needs it; set LLD=<path>." >&2
    return 1 2>/dev/null || exit 1
fi
export LLD

# A clang that can target aarch64-linux-gnu AND use lld. Apple's clang works for
# this (it is the linker that is missing), so prefer the Xcode one and fall back
# to a standalone LLVM install.
CC_TOOL="${CC_TOOL:-}"
if [ -z "$CC_TOOL" ]; then
    for candidate in \
        "$(dirname "$LLD")/clang" \
        /opt/homebrew/opt/llvm/bin/clang \
        "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"; do
        if [ -x "$candidate" ]; then CC_TOOL="$candidate"; break; fi
    done
fi
if [ -z "${CC_TOOL:-}" ] || [ ! -x "$CC_TOOL" ]; then
    echo "toolchain: no clang found; set CC_TOOL=<path>" >&2
    return 1 2>/dev/null || exit 1
fi
export CC_TOOL
export AR_TOOL="${AR_TOOL:-$(xcrun --find ar)}"

export PATH="$(dirname "$MESON"):$(dirname "$NINJA"):$(dirname "$LLD"):$(dirname "$CC_TOOL"):$PATH"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

SDKROOT_SIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"
export SDKROOT_SIM

# --- sanity ---------------------------------------------------------------
# This check exists because the failure it catches is silent: meson reports
# success, the VDSO is an empty file, and the guest hangs on the first process.
# dsh-ios's README calls this out and it is worth failing loudly instead.
if ! "$CC_TOOL" -target aarch64-linux-gnu -fuse-ld=lld -nostdlib -shared -fPIC \
        -x c /dev/null -o /dev/null 2>/dev/null; then
    echo "toolchain: $CC_TOOL cannot link an aarch64-linux ELF with $LLD." >&2
    echo "toolchain: the guest VDSO would be an empty stub and nothing would run." >&2
    return 1 2>/dev/null || exit 1
fi

toolchain_summary() {
    echo "DEVELOPER_DIR=$DEVELOPER_DIR"
    echo "meson=$MESON ($("$MESON" --version))"
    echo "ninja=$NINJA ($("$NINJA" --version))"
    echo "clang=$CC_TOOL ($("$CC_TOOL" --version | head -1))"
    echo "ld.lld=$LLD ($("$LLD" --version | head -1))"
    echo "sdk=$(basename "$SDKROOT_SIM")"
}
