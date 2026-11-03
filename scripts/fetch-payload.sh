#!/bin/bash
# Rebuild payload/node_modules from the public npm registry:
#   1. npm ci, without running any package's install script
#   2. apply payload-build/payload.patch (see PATCHES.md for why each change exists)
#   3. drop everything the app does not ship
#   4. check every remaining file against payload-build/manifest.sha256.gz
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$ROOT/payload/.fetch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/payload/package.json" "$ROOT/payload/package-lock.json" "$TMP/"
(cd "$TMP" && npm ci --ignore-scripts --no-audit --no-fund)
(cd "$TMP" && git init -q . && git apply --whitespace=nowarn "$ROOT/payload-build/payload.patch" && rm -rf .git)
python3 - "$TMP/node_modules" "$ROOT/payload-build/manifest.sha256.gz" <<'PY'
import gzip, hashlib, os, sys
top, manifest = sys.argv[1:]
want = {}
with gzip.open(manifest, 'rt', encoding='utf-8') as f:
    for line in f:
        digest, path = line.rstrip('\n').split('  ', 1)
        want[path] = digest
seen = removed = 0
for root, dirs, files in os.walk(top, topdown=False):
    for name in files:
        full = os.path.join(root, name)
        rel = os.path.relpath(full, top)
        if rel not in want:
            os.remove(full)
            removed += 1
            continue
        with open(full, 'rb') as f:
            if hashlib.sha256(f.read()).hexdigest() != want[rel]:
                sys.exit(f'payload: hash mismatch: {rel}')
        seen += 1
    if root != top and not os.listdir(root):
        os.rmdir(root)
if seen != len(want):
    sys.exit(f'payload: {len(want) - seen} expected files are missing')
print(f'payload: {seen} files verified, {removed} dropped')
PY
rm -rf "$ROOT/payload/node_modules"
mv "$TMP/node_modules" "$ROOT/payload/node_modules"
