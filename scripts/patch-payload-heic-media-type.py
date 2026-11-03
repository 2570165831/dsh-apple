#!/usr/bin/env python3
r"""Let the DSH front-end offer HEIC/HEIF images as images, not as files.

WHY THIS IS NEEDED
------------------
The attachment store can decode HEIC (P-10: `ImageIO` does it, and the store
accepts `image/heic` / `image/heif` as SOURCE types). The browser half does not
know that. `@deepseek-ai/dsh-client-ui-conversation` hard-codes the four types it
will treat as images in two functions:

    function imageMediaType(value) {
        switch (value) {
            case "image/png": case "image/jpeg":
            case "image/webp": case "image/gif": return value;
            default: throw new UnsupportedImageMediaTypeError(value);
        }
    }
    function isImageMediaType(value) {
        return value === "image/png" || ... || value === "image/gif";
    }

A file that fails `isImageMediaType` is not refused — it is routed to the FILE
upload path (`createDrafts`, `lib/client.js:4753`). So an iPhone photo becomes a
verbatim attachment with no preview, and the model receives a path to a HEIC file
it cannot open. That is the user-visible symptom "App 里发不了图", and no amount
of server-side decoding fixes it: the bytes never reach the image path.

WHY A PATCH AND NOT A PLUGIN
----------------------------
These two functions are module-private inside a minified client bundle that is
served as one generated `client.js`. There is no service seam, no exported
symbol, and no slot a client plugin can replace: the composer calls them
directly. A client plugin could re-implement the whole composer, which is a far
larger and more fragile change than the two-line edit this needs. PATCHES.md
P-11 records it with the exact strings and what to re-check after an upgrade.

WHAT IT CHANGES, EXACTLY
------------------------
Only the accepted-type predicate. Nothing about dimensions, byte caps, counts,
or the upload path changes, and the four original types still behave identically.

The decode side does not need a matching front-end change: `encodeImage` sends
whatever `imageMediaType` returned as the declared `mediaType`, and the store
accepts HEIC and re-encodes it to JPEG/PNG before storing, so the reference the
session log records is always one of DSH's four types.

BACKUP AND IDEMPOTENCE: the original file is copied to
work/hemp-patch-backup/ before the first rewrite, and re-running with the patch
already applied reports `already_patched` rather than corrupting anything.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAYLOAD = ROOT / "payload"
BACKUP = ROOT / "work" / "heic-media-type-backup"
REPORT = ROOT / "logs" / "heic-media-type-patch.json"

CLIENT = "node_modules/@deepseek-ai/dsh-client-ui-conversation/lib/client.js"

# ---------------------------------------------------------------------------
# 1. The composer's accepted-type predicate (browser bundle).
#
# Narrow on purpose: a loose pattern would match other type switches in the same
# minified file.
# ---------------------------------------------------------------------------
CLIENT_PATCHES: list[tuple[str, str, str]] = [
    (
        CLIENT,
        'case "image/gif": return value;\n\t\t\t\tdefault: throw new UnsupportedImageMediaTypeError(value);',
        'case "image/gif":\n\t\t\t\tcase "image/heic":\n\t\t\t\tcase "image/heif": return value;\n\t\t\t\tdefault: throw new UnsupportedImageMediaTypeError(value);',
    ),
    (
        CLIENT,
        'return value === "image/png" || value === "image/jpeg" || value === "image/webp" || value === "image/gif";',
        'return value === "image/png" || value === "image/jpeg" || value === "image/webp" || value === "image/gif"\n\t\t\t\t|| value === "image/heic" || value === "image/heif";',
    ),
]

# ---------------------------------------------------------------------------
# 2. The RPC boundary schemas that type a prompt's image part.
#
# THIS IS THE ONE THAT ACTUALLY BROKE IT, and it is worth stating plainly: the
# browser can happily encode a HEIC part, but `session/prompt` validates `request`
# against a JSON Schema whose image `mediaType` is a closed enum of four strings.
# An `image/heic` part therefore fails at the gateway with
#
#     typert gateway: session/prompt: wire field "request" failed boundary
#     validation (gateway/input-invalid)
#
# which reaches the user as a generic failure with no hint that HEIC was the
# problem. The enum appears once per direction (host validates input, remote
# client types the same call) in three packages, because all three accept an
# image part: the session prompt, the command prompt, and subagent dispatch.
#
# ONLY THE INPUT DIRECTION IS WIDENED. The `ImageAttachmentRef.mediaType` enum
# (the reference the store hands back) is left alone on purpose: a stored
# attachment is always one of the four, because normalisation re-encodes to
# JPEG/PNG. Widening that one would misdescribe what the store can return.
# ---------------------------------------------------------------------------
BOUNDARY_FILES = [
    "node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js",
    "node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.remote-client.js",
    "node_modules/@deepseek-ai/dsh-subagent/lib/typert.host.js",
    "node_modules/@deepseek-ai/dsh-subagent/lib/typert.remote-client.js",
    "node_modules/@deepseek-ai/dsh-commands/lib/typert.host.js",
    "node_modules/@deepseek-ai/dsh-commands/lib/typert.remote-client.js",
]

# The JSON-Schema mirror (documentation + the shape the client types against).
INPUT_ENUMS = [
    ('"type":{"type":"string","const":"image"},"mediaType":{"type":"string","enum":["image/png","image/jpeg","image/webp","image/gif"]}',
     '"type":{"type":"string","const":"image"},"mediaType":{"type":"string","enum":["image/png","image/jpeg","image/webp","image/gif","image/heic","image/heif"]}'),
    ('"type":{"type":"string","const":"image"},"mediaType":{"type":"string","enum":["image/png","image/jpeg","image/webp","image/gif"],"description"',
     '"type":{"type":"string","const":"image"},"mediaType":{"type":"string","enum":["image/png","image/jpeg","image/webp","image/gif","image/heic","image/heif"],"description"'),
]

# THE ZOD SCHEMA IS THE ONE THAT ACTUALLY REJECTS THE REQUEST.
#
# `typert.host.js` exports a generated `z.object` per RPC input, and the gateway
# validates against THAT (`codec.mode === 'strict'` → `codec.create().parse(...)`),
# not against the JSON Schema above it. Patching only the JSON Schema changed
# nothing on the wire, which is exactly how this was found: the patch was in the
# installed bundle, and `session/prompt` still answered
# `wire field "request" failed boundary validation`.
#
# Only the PROMPT INPUT gets the two new members. Two other places in this file
# spell the same union and are deliberately left alone:
#
#   * `session.attachment`'s RESULT — a stored reference is always one of the
#     four, because normalisation re-encodes to JPEG/PNG.
#   * `imageLimits.mediaTypes` — this is a capability REPORT; widening the
#     accepted INPUT set without widening it would make the browser hide HEIC
#     again. It is patched by ZOD_MEDIA_TYPES below.
ZOD_IMAGE_UNION = (
    'z.union([z.literal("image/png"), z.literal("image/jpeg"), z.literal("image/webp"), z.literal("image/gif")])'
)
ZOD_IMAGE_UNION_WIDE = (
    'z.union([z.literal("image/png"), z.literal("image/jpeg"), z.literal("image/webp"), z.literal("image/gif"), z.literal("image/heic"), z.literal("image/heif")])'
)
# Anchored on the prompt's image part, so the attachment-RESULT union is untouched.
ZOD_INPUT_ANCHOR = (
    "'type': z.literal(\"image\").readonly(),\n  'mediaType': " + ZOD_IMAGE_UNION
)
ZOD_INPUT_ANCHOR_WIDE = (
    "'type': z.literal(\"image\").readonly(),\n  'mediaType': " + ZOD_IMAGE_UNION_WIDE
)
# The capability report: `'mediaTypes': z.array(<union>)`.
ZOD_MEDIA_TYPES = "'mediaTypes': z.array(" + ZOD_IMAGE_UNION + ")"
ZOD_MEDIA_TYPES_WIDE = "'mediaTypes': z.array(" + ZOD_IMAGE_UNION_WIDE + ")"

# ---------------------------------------------------------------------------
# 3. `read_image`'s extension table.
#
# It refuses a path whose extension declares no supported format BEFORE reading
# the bytes (dsh-tool-fs/lib/index.js:1014), so without this the model cannot open
# a HEIC that is already sitting in the workspace.
# ---------------------------------------------------------------------------
READ_IMAGE_PATCHES: list[tuple[str, str, str]] = [
    (
        "node_modules/@deepseek-ai/dsh-tool-fs/lib/index.js",
        '\t".gif": "image/gif"\n};',
        '\t".gif": "image/gif",\n\t".heic": "image/heic",\n\t".heif": "image/heif"\n};',
    ),
]

PATCHES: list[tuple[str, str, str]] = [*CLIENT_PATCHES, *READ_IMAGE_PATCHES]


def backup(target: Path) -> Path:
    BACKUP.mkdir(parents=True, exist_ok=True)
    destination = BACKUP / target.name
    if not destination.exists():
        shutil.copy2(target, destination)
    return destination


def main() -> int:
    if not PAYLOAD.is_dir():
        print(f"no payload at {PAYLOAD}", file=sys.stderr)
        return 1

    records: list[dict] = []
    changed = 0

    # Boundary schemas: substitute every occurrence, since each file spells the
    # one input enum once per direction.
    for relative in BOUNDARY_FILES:
        target = PAYLOAD / relative
        if not target.is_file():
            records.append({"file": relative, "status": "missing", "kind": "boundary"})
            continue
        text = target.read_text(encoding="utf-8")
        original = text
        hits = 0
        for old, new in INPUT_ENUMS:
            hits += text.count(old)
            text = text.replace(old, new)
        # The runtime-enforced zod spellings: the prompt image part, then the
        # capability report. The attachment-RESULT union matches neither anchor,
        # so a stored reference's four types stay enforced.
        hits += text.count(ZOD_INPUT_ANCHOR)
        text = text.replace(ZOD_INPUT_ANCHOR, ZOD_INPUT_ANCHOR_WIDE)
        hits += text.count(ZOD_MEDIA_TYPES)
        text = text.replace(ZOD_MEDIA_TYPES, ZOD_MEDIA_TYPES_WIDE)
        if hits == 0:
            already = ('"image/heic","image/heif"}]' in original
                       or '"image/gif","image/heic","image/heif"]' in original
                       or 'z.literal("image/heic")' in original)
            records.append({
                "file": relative,
                "status": "already_patched" if already else "pattern_not_found",
                "kind": "boundary",
            })
            if not already:
                print(f"warning: input image enum not found in {relative}", file=sys.stderr)
            continue
        backup(target)
        target.write_text(text, encoding="utf-8")
        changed += 1
        records.append({"file": relative, "status": "patched", "kind": "boundary", "occurrences": hits})

    for relative, old, new in PATCHES:
        target = PAYLOAD / relative
        if not target.is_file():
            records.append({"file": relative, "status": "missing"})
            continue
        text = target.read_text(encoding="utf-8")
        if old not in text:
            # Already patched, or the upstream bundle changed. Distinguishing the
            # two is the difference between "nothing to do" and "the patch no
            # longer applies", and only one of them is safe to ignore.
            already = ('"image/heic"' in text) and ("image/heif" in text)
            records.append({
                "file": relative,
                "status": "already_patched" if already else "pattern_not_found",
                "pattern": old[:120],
            })
            if not already:
                print(f"warning: pattern not found in {relative}", file=sys.stderr)
            continue
        saved = backup(target)
        target.write_text(text.replace(old, new, 1), encoding="utf-8")
        changed += 1
        records.append({
            "file": relative,
            "status": "patched",
            "pattern": old[:120],
            "backup": str(saved.relative_to(ROOT)),
        })

    summary = {
        "method": "Add image/heic and image/heif to the composer's accepted image MIME predicate only.",
        "why": (
            "The attachment store decodes HEIC (P-10) but the browser routes a "
            "non-listed type to the verbatim FILE upload path, so an iPhone photo "
            "would never reach the image decoder."
        ),
        "patched_files": changed,
        "records": records,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"heic media-type patch: {changed} change(s)")
    for record in records:
        print(f"  {record['status']:<18} {record['file']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
