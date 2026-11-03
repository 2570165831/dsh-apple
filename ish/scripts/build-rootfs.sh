#!/bin/bash
# Build the Alpine image the app boots.
#
# The image is produced by running a real Alpine userspace inside the same
# emulator the app links, so what ships is what ran. Nothing here assembles a
# tarball on the host: a rootfs built that way has never executed, and the first
# execution would be on a user's device.
#
# Shape of the pipeline (the same idea as dsh-ios's build-rootfs.sh, minus Node
# and DSH, which this app runs on the host side rather than in the guest):
#
#   1. download the pinned Alpine minirootfs
#   2. fakefsify it — turn the tar into the SQLite-backed fakefs iSH mounts
#   3. run apk inside the emulator to install the packages
#   4. trim caches, record what is installed
#   5. unfakefsify back to a tar for the app bundle
#
# Output:
#   build/rootfs/ish-rootfs.tar.gz         the image the app imports
#   build/rootfs/ish-rootfs.version        content-derived version string
#   build/rootfs/ROOTFS-PACKAGES.txt       `apk info -v`, for THIRD_PARTY_NOTICES
#
# Usage: ish/scripts/build-rootfs.sh [--keep-work]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ISH_DIR/.." && pwd)"
SRC="$ISH_DIR/src/ish-arm64"
LOCK="$ISH_DIR/UPSTREAM.lock.json"

CLI_DIR="$ROOT/build/ish/host/cli/ninja"
WORK="$ROOT/build/rootfs/work"
OUT_DIR="$ROOT/build/rootfs"
OUT="$OUT_DIR/ish-rootfs.tar.gz"

KEEP_WORK=0
[ "${1:-}" = "--keep-work" ] && KEEP_WORK=1

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
ALPINE_VER="$(jq -er '.alpine.version' "$LOCK")"
ALPINE_URL="$(jq -er '.alpine.url' "$LOCK")"
ALPINE_SHA256="$(jq -er '.alpine.sha256' "$LOCK")"
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"

[ -x "$CLI_DIR/ish" ] || die "the emulator CLI is not built — run ish/scripts/build-cli.sh"
[ -x "$CLI_DIR/tools/fakefsify" ] || die "fakefsify is not built — run ish/scripts/build-cli.sh"

mkdir -p "$WORK" "$OUT_DIR"
cd "$WORK"

# The emulator writes its noise to stderr, including the "expose_wasm" note that
# appears on every guest process start. Strip it so a real failure is visible.
guest() {
    # pipefail is what makes an apk failure inside this function fail the build.
    # Without it the sed in the pipeline is the command whose status is checked,
    # sed succeeds on empty input, and a broken image exports as a success --
    # which is exactly how the first attempt shipped 15 packages while claiming
    # to install 16.
    local status
    set -o pipefail
    "$CLI_DIR/ish" -f "$WORK/fakefs" /bin/sh "$@" 2>&1 | sed '/expose_wasm/d'
    status=${PIPESTATUS[0]}
    set +o pipefail
    return "$status"
}

# --- 1. base image ---------------------------------------------------------
log "Alpine $ALPINE_VER aarch64"
if [ ! -f "$ALPINE_TARBALL" ]; then
    curl -fsSL -o "$ALPINE_TARBALL.part" "$ALPINE_URL"
    mv "$ALPINE_TARBALL.part" "$ALPINE_TARBALL"
fi
ACTUAL_SHA="$(shasum -a 256 "$ALPINE_TARBALL" | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$ALPINE_SHA256" ] \
    || die "base image SHA-256 mismatch: got $ACTUAL_SHA, lock says $ALPINE_SHA256"

# --- 2. fakefs -------------------------------------------------------------
log "creating the fakefs"
rm -rf fakefs
"$CLI_DIR/tools/fakefsify" "$ALPINE_TARBALL" fakefs

# --- 3. packages -----------------------------------------------------------
# `nodejs`, `npm` and `python3` are EXPERIMENTAL (step 24). They are here so the
# model can write and run a script in the guest instead of only shelling out,
# and the report for that step records which of their capabilities actually ran
# under this emulator. They are Alpine's musl builds, which is the only kind the
# emulated kernel can exec.
#
# Still absent, deliberately: `pip`, `gcc`, `make`, `python3-dev`, `nodejs-dev`,
# and `apk` itself after the install. Without a compiler, a Python package with
# C sources and an npm package with a native addon cannot be built here, so the
# capability this adds is "run pure-Python and pure-JS code", not "manage an
# arbitrary dependency tree". `apk` is removed below so the image cannot grow
# itself at run time; the guest is a command environment, not a distro.
#
# `ripgrep` is not decoration. DSH's `glob`/`grep` tools are ripgrep front-ends
# (`dsh-tool-fs-search` spawns the packaged `@vscode/ripgrep` binary through
# `ctx.subprocess`), and this app's `ctx.subprocess` runs in the GUEST. Without
# `rg` here the tools can only answer "ripgrep launch failed". The npm package's
# binary is a glibc/x86-centric build that the emulated kernel cannot exec, so
# the guest gets Alpine's own musl build (14.1.1, see ROOTFS-PACKAGES.txt) and
# the provider maps the packaged path onto it — see plugins/dsh-subprocess-ish.
GUEST_PACKAGES="bash git coreutils grep sed tar gzip less curl ca-certificates openssh-client ncurses findutils ripgrep nodejs npm python3"

log "installing: $GUEST_PACKAGES"
guest <<EOF
set -e
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
apk update >/dev/null
apk add --no-progress $GUEST_PACKAGES 2>&1 | tail -2
EOF

# A package that silently did not install is the failure mode this build has to
# rule out, because the image still exports fine and the app still boots -- just
# without the command the user asked for.
#
# THE ANSWER IS READ FROM STDOUT, NOT FROM THE EXIT STATUS. The host `ish` CLI
# does not propagate the guest command's exit code (`main.c` returns 0 whenever
# the guest task ran at all), so `guest -c "apk info -e $pkg"` exits 0 whether or
# not the package is there -- measured with `exit 3`, which also returns 0. A
# status-based check here is therefore always true and would report a 15-package
# image as complete. The sentinel below is what actually distinguishes the two
# cases.
guest_check() {
    local probe="$1"
    local output
    output="$(guest -c "if $probe; then echo GUEST-CHECK-PRESENT; else echo GUEST-CHECK-MISSING; fi" 2>&1 || true)"
    case "$output" in
        *GUEST-CHECK-PRESENT*) return 0 ;;
        *) return 1 ;;
    esac
}

for pkg in $GUEST_PACKAGES; do
    if ! guest_check "apk info -e $pkg >/dev/null 2>&1"; then
        die "package did not install: $pkg"
    fi
done

# --- 4. trim and record ----------------------------------------------------
log "trimming caches and recording contents"
guest <<'EOF'
set -e
rm -rf /var/cache/apk/* /tmp/* /root/.cache /root/.ash_history 2>/dev/null || true
mkdir -p /root/workspace /etc/ish
# Keep the identity of the image in the guest itself: a `cat` from inside the
# debug console answers "which image is this?" without trusting the host side.
echo "built from Alpine minirootfs + the package list in ROOTFS-PACKAGES.txt" > /etc/ish/rootfs-note
# Step 24: the image must not be able to grow itself on the device. This runs
# AFTER the install verification above, so a package that failed to install is
# still a build error; and it runs BEFORE the manifest is written, so the
# manifest describes the image that ships rather than the intermediate state.
# Removing apk-tools takes /sbin/apk with it. /lib/apk/db and /etc/apk are left
# in place: the db is the manifest source below, and it is also what lets an
# operator identify the image from inside the guest.
apk del apk-tools >/dev/null 2>&1
EOF

{
    echo "# Packages in build/rootfs/ish-rootfs.tar.gz"
    echo "# Generated by ish/scripts/build-rootfs.sh from a real apk install inside"
    echo "# the emulator, not from a package list. Versions are what the guest"
    echo "# actually has; THIRD_PARTY_NOTICES.md explains what each license implies."
    echo "#"
    echo "# Read from /lib/apk/db/installed rather than from \`apk info -v\` because"
    echo "# the image does not ship apk: apk-tools is removed at the end of the"
    echo "# build so the guest cannot install anything at run time. The database"
    echo "# records exactly the packages that remain, which is the claim this file"
    echo "# is making."
    echo
    guest <<'EOF'
awk -F: '/^P:/{name=$2} /^V:/{print name "-" $2}' /lib/apk/db/installed | sort
EOF
} > "$OUT_DIR/ROOTFS-PACKAGES.txt"

PKG_COUNT="$(grep -c . <(grep -v '^#' "$OUT_DIR/ROOTFS-PACKAGES.txt" | grep -v '^$') || true)"
log "guest has $PKG_COUNT packages"

# The removal above is the other half of "the image cannot grow itself". Asserting
# it here means a future package list that pulls apk-tools back in fails the build
# instead of shipping quietly. Read through the same stdout sentinel as the
# install checks, for the same reason (the CLI does not forward the exit code).
if guest_check "command -v apk >/dev/null 2>&1"; then
    die "apk is still in the image; the guest must not be able to install packages"
fi
# python3/node/npm must survive that removal, and be runnable, not merely present.
for probe in 'node --version' 'npm --version' 'python3 --version'; do
    if ! guest_check "$probe >/dev/null 2>&1"; then
        die "the runtime does not run after trimming apk: $probe"
    fi
done

# --- 5. package the fakefs ------------------------------------------------
# What ships is the fakefs directory, not unfakefsify's tar.
#
# That tar is the guest's view of its own filesystem: it contains 751 symlinks
# and 8 character devices, and an iOS app cannot create either — no mknod, and
# a symlink into a sandbox path is not what those links mean anyway. The fakefs
# representation keeps symlinks and device numbers inside meta.db, so the whole
# tree is regular files and directories. That is what an app can unpack, and it
# is also the representation the kernel actually mounts, so unpacking it is a
# copy rather than a conversion.
log "packaging the fakefs"
rm -f "$OUT"
# -C so the archive has no leading path component; the app extracts into place.
# COPYFILE_DISABLE stops BSD tar from writing AppleDouble ._* files, which would
# land inside the guest as thousands of stray files.
COPYFILE_DISABLE=1 tar czf "$OUT" -C fakefs .

# The unfakefsify form is still produced, for the case where someone wants the
# guest-readable tree (inspecting it on a Mac, or feeding it back to fakefsify).
UNFAKED="$OUT_DIR/ish-rootfs-guest-view.tar.gz"
"$CLI_DIR/tools/unfakefsify" fakefs "$UNFAKED"

# A version string that changes when the content changes, so an app update that
# alters the image triggers a re-import and an unchanged one does not.
ROOTFS_SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf '%s\n' "alpine-${ALPINE_VER}-${ROOTFS_SHA:0:16}" > "$OUT_DIR/ish-rootfs.version"

log "products"
printf '  %-28s %10s bytes  (%s MB)\n' "ish-rootfs.tar.gz" "$(stat -f%z "$OUT")" \
    "$(echo "scale=1; $(stat -f%z "$OUT") / 1048576" | bc)"
printf '  %-28s %10s\n' "ish-rootfs.version" "$(cat "$OUT_DIR/ish-rootfs.version")"
printf '  %-28s %10s lines\n' "ROOTFS-PACKAGES.txt" "$(wc -l < "$OUT_DIR/ROOTFS-PACKAGES.txt" | tr -d ' ')"
printf '  %-28s %10s bytes  (guest view, not shipped)\n' "ish-rootfs-guest-view.tar.gz" \
    "$(stat -f%z "$UNFAKED")"
echo "  sha256 $ROOTFS_SHA"

rm -f "$UNFAKED"
if [ "$KEEP_WORK" = 0 ]; then
    rm -rf fakefs
fi

# The notices file quotes package versions; fail loudly when they drift apart
# rather than shipping a notice that describes a different image.
cp "$OUT_DIR/ROOTFS-PACKAGES.txt" "$ROOT/RootfsPackages.md"
log "updated RootfsPackages.md"
