#!/usr/bin/env python3
"""Rewrite one session log's header cwd, for building a stale-container fixture.

    scripts/rewrite-session-header.py --log PATH --cwd NEW_CWD

Reads the first Zstandard frame (which by DSH's format is exactly the header
line), replaces `cwd`, recompresses that frame with a checksum, and copies every
following frame through untouched. Writes via a temp file + rename so a crash
cannot leave a half-written log.

This exists so the container-change test can build the state a device update
leaves behind without also exercising the production rewrite while it builds the
fixture: using `sim/session-migrate.mjs` to create the fixture would make the test
compare the code against itself. The one thing it shares is the frame layout,
which is DSH's own.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile


def scan_frames(buffer: bytes, limit: int | None = None) -> list[tuple[int, int]]:
    """Byte ranges of the Zstandard frames in `buffer`."""
    frames: list[tuple[int, int]] = []
    offset = 0
    while offset < len(buffer):
        start = offset
        if buffer[offset:offset + 4] != b"\x28\xb5\x2f\xfd":
            raise SystemExit(f"not a Zstandard frame at byte {offset}")
        offset += 4
        descriptor = buffer[offset]
        offset += 1
        if descriptor & 24:
            raise SystemExit(f"reserved frame-header bit at byte {offset - 1}")
        single = bool(descriptor & 32)
        checksum = bool(descriptor & 4)
        dictionary = descriptor & 3
        dictionary_bytes = 4 if dictionary == 3 else dictionary
        content_size = (1 if single else 0) if descriptor >> 6 == 0 else 1 << (descriptor >> 6)
        offset += (0 if single else 1) + dictionary_bytes + content_size
        while True:
            header = int.from_bytes(buffer[offset:offset + 3], "little")
            offset += 3
            last = header & 1
            block_type = (header >> 1) & 3
            size = header >> 3
            if block_type == 3:
                raise SystemExit(f"reserved block type at byte {offset - 3}")
            offset += 1 if block_type == 1 else size
            if last:
                break
        if checksum:
            offset += 4
        frames.append((start, offset))
        if limit is not None and len(frames) >= limit:
            break
    return frames


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", required=True, help="session .jsonl.zstd to rewrite in place")
    parser.add_argument("--cwd", required=True, help="the header cwd to write")
    args = parser.parse_args()

    raw = open(args.log, "rb").read()
    frames = scan_frames(raw, limit=1)
    if not frames:
        raise SystemExit("no frame in the log")
    start, end = frames[0]
    # Python's zlib has no Zstandard decoder, so both directions go through the
    # `zstd` CLI. That is a host tool for building a fixture, not part of the app:
    # the app's own rewrite uses node:zlib (sim/session-migrate.mjs).
    import subprocess
    header_text = subprocess.run(["zstd", "-dc"], input=raw[start:end],
                                 capture_output=True, check=True).stdout
    if not header_text.endswith(b"\n") or header_text.count(b"\n") != 1:
        raise SystemExit("the first frame is not exactly one header line")
    header = json.loads(header_text[:-1])
    header["cwd"] = args.cwd
    new_line = json.dumps(header, separators=(",", ":")).encode() + b"\n"
    # Recompress with the same CLI: a real Zstandard frame with a checksum, in the
    # shape DSH writes and the shape sim/session-migrate.mjs produces.
    frame = subprocess.run(["zstd", "-c", "--no-progress", "-19"], input=new_line,
                           capture_output=True, check=True).stdout
    rebuilt = frame + raw[end:]

    directory = os.path.dirname(os.path.abspath(args.log))
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".rewrite-")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(rebuilt)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, args.log)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    print(json.dumps({"log": args.log, "cwd": args.cwd, "bytes": len(rebuilt)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
