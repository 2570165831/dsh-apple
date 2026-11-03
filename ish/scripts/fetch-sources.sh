#!/bin/bash
# Create (or verify) the iSH source tree this repository builds from.
#
# The tree is not committed. `ish/src/ish-arm64` is a git checkout at the commit
# pinned in `ish/UPSTREAM.lock.json`, with `ish/patches/*.patch` applied on top.
# Both steps are replayed from scratch, so "which source produced this library?"
# has an answer that does not depend on what happened to be on disk.
#
#   ish/scripts/fetch-sources.sh          create or reset the tree to the pinned state
#   ish/scripts/fetch-sources.sh --check  verify the tree still matches, change nothing
#
# A local patch that fails to apply is a hard error, not a warning: a patch that
# silently stops applying is how a fix disappears without anyone noticing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$(cd "$HERE/.." && pwd)"
LOCK="$ISH_DIR/UPSTREAM.lock.json"
SRC="$ISH_DIR/src/ish-arm64"
PATCH_DIR="$ISH_DIR/patches"
STATE="$ISH_DIR/.source-state"

MODE="${1:-fetch}"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required to read $LOCK"
[ -f "$LOCK" ] || die "missing $LOCK"

REPO="$(jq -er '.ish.repository' "$LOCK")"
COMMIT="$(jq -er '.ish.commit' "$LOCK")"

shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob

# A stable digest of the working tree relative to the pin. This is what the
# patch series is supposed to produce; anything else means someone edited the
# checkout by hand, and a build from it would not be reproducible.
tree_digest() {
    {
        git -C "$SRC" status --porcelain -uno | LC_ALL=C sort
        echo '--'
        git -C "$SRC" diff --no-color HEAD
    } | shasum -a 256 | awk '{print $1}'
}

check_submodules() {
    local sub path want have
    for sub in $(jq -er '.ish.submodules | to_entries[] | select(.value.required) | .key' "$LOCK"); do
        path="$(jq -er --arg s "$sub" '.ish.submodules[$s].path' "$LOCK")"
        want="$(jq -er --arg s "$sub" '.ish.submodules[$s].commit' "$LOCK")"
        have="$(git -C "$SRC" ls-tree HEAD "$path" | awk '{print $3}')"
        [ "$have" = "$want" ] || die "gitlink $path is $have, lock says $want"
        [ -n "$(ls -A "$SRC/$path" 2>/dev/null)" ] || die "submodule $path is not checked out"
        have="$(git -C "$SRC/$path" rev-parse HEAD 2>/dev/null || echo missing)"
        [ "$have" = "$want" ] || die "submodule $path is checked out at $have, lock says $want"
    done
}

check_tree() {
    [ -d "$SRC/.git" ] || die "no source checkout at $SRC — run ish/scripts/fetch-sources.sh"
    local head
    head="$(git -C "$SRC" rev-parse HEAD)"
    [ "$head" = "$COMMIT" ] || die "checkout is at $head, lock says $COMMIT"
    check_submodules

    [ -f "$STATE" ] || die "missing $STATE — run ish/scripts/fetch-sources.sh"
    grep -qx "commit $COMMIT" "$STATE" || die "$STATE describes a different commit"
    local p
    for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
        grep -qx "patch $(basename "$p") $(shasum -a 256 "$p" | awk '{print $1}')" "$STATE" \
            || die "$(basename "$p") changed since the tree was created"
    done

    local recorded actual
    recorded="$(grep '^tree ' "$STATE" | tail -1 | cut -d' ' -f2)"
    actual="$(tree_digest)"
    [ "$recorded" = "$actual" ] \
        || die "tracked files differ from the patched pin (recorded $recorded, now $actual)"

    # An untracked file is not automatically a problem (a build directory
    # lives here), but a source file that is not from the pin is.
    local untracked
    untracked="$(git -C "$SRC" status --porcelain --untracked-files=normal \
                 | awk '$1=="??"{print $2}' | grep -v -E '^(build|build-|\.)' || true)"
    [ -z "$untracked" ] || { printf '%s\n' "$untracked" >&2; die "unexpected untracked files in the source tree"; }
    log "tree matches the pin: $COMMIT, $(grep -c '^patch ' "$STATE" || true) local patch(es)"
}

if [ "$MODE" = "--check" ]; then
    check_tree
    exit 0
fi

log "pinned commit $COMMIT"
if [ -d "$SRC/.git" ]; then
    log "resetting existing checkout"
    git -C "$SRC" fetch --quiet --depth=1 origin "$COMMIT" 2>/dev/null || true
    git -C "$SRC" checkout --quiet --force "$COMMIT"
    # Drop the previous patch application so it is replayed, not accumulated.
    git -C "$SRC" checkout --quiet -- .
else
    log "cloning $REPO (blobs on demand)"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet --filter=blob:none --no-checkout "$REPO" "$SRC"
    git -C "$SRC" checkout --quiet "$COMMIT"
fi
# Untracked files from a previous run would confuse the digest below, but a
# build directory is expensive to throw away, so those are left alone.
git -C "$SRC" clean -qfd -e build -e 'build-*' -- kernel fs emu asbestos util platform vdso deps/*/ kernel/arch 2>/dev/null || true

locally_modified="$(git -C "$SRC" status --porcelain -uno)"
[ -z "$locally_modified" ] || { printf '%s\n' "$locally_modified" >&2; die "source tree still has local changes after reset"; }

HEAD_NOW="$(git -C "$SRC" rev-parse HEAD)"
[ "$HEAD_NOW" = "$COMMIT" ] || die "checkout is at $HEAD_NOW, expected $COMMIT"

log "checking out required submodules"
for sub in $(jq -er '.ish.submodules | to_entries[] | select(.value.required) | .key' "$LOCK"); do
    path="$(jq -er --arg s "$sub" '.ish.submodules[$s].path' "$LOCK")"
    git -C "$SRC" submodule update --init --depth=1 "$path"
done

# --- patches ---------------------------------------------------------------
# Applied with `git apply --3way` so a patch whose base moved fails loudly on a
# conflict instead of quietly landing in the wrong place.
echo "commit $COMMIT" > "$STATE"
if [ ${#PATCHES[@]} -gt 0 ]; then
    log "applying ${#PATCHES[@]} local patch(es)"
    for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
        name="$(basename "$p")"
        if git -C "$SRC" apply --check "$p" 2>/dev/null; then
            git -C "$SRC" apply "$p"
            log "  applied $name"
        elif git -C "$SRC" apply --check --3way "$p" 2>/dev/null; then
            git -C "$SRC" apply --3way "$p"
            log "  applied $name (3-way)"
        else
            die "patch does not apply: $name — the pin moved, or the patch is stale"
        fi
        echo "patch $name $(shasum -a 256 "$p" | awk '{print $1}')" >> "$STATE"
    done
else
    log "no local patches"
fi
echo "tree $(tree_digest)" >> "$STATE"

log "recorded source state in ish/.source-state"
check_tree
