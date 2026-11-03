#!/usr/bin/env python3
"""Rewrite an ar archive so its bytes depend only on its members.

Darwin's `ar` records each member's mtime, uid, gid and mode in the
`!<arch>` header. Two builds of identical sources produce identical object
files but different mtimes, so the archives are the same size and differ in a
handful of header bytes. macOS `ar` has no `-D` (GNU's deterministic mode), so
the normalisation happens here instead.

Only header metadata changes. Member order, member contents and the symbol table
are copied through byte for byte: the symbol table's entries are offsets into
the archive, so rewriting them would be a real change, not a cosmetic one.

The header is 60 bytes with fixed-width fields, and getting a width wrong is not
a cosmetic bug: it resizes the buffer and every later field shifts, which makes
the archive unreadable by ar and ld. The widths are therefore asserted rather
than trusted.

Usage: normalize-archive.py <archive> [<archive> ...]
"""

import sys

GLOBAL_HEADER = b"!<arch>\n"
HEADER_SIZE = 60
# field name, (start, end) into the 60-byte header, replacement value.
# These widths are the archive format's; they are not free choices.
FIELDS = (
    ("mtime", 16, 28, b"0".ljust(12)),
    ("uid", 28, 34, b"0".ljust(6)),
    ("gid", 34, 40, b"0".ljust(6)),
    ("mode", 40, 48, b"100644".ljust(8)),
)


def normalize(path: str) -> None:
    with open(path, "rb") as handle:
        data = handle.read()

    if not data.startswith(GLOBAL_HEADER):
        raise SystemExit(f"{path}: not an ar archive (bad magic)")

    out = bytearray(GLOBAL_HEADER)
    offset = len(GLOBAL_HEADER)

    while offset < len(data):
        if offset + HEADER_SIZE > len(data):
            raise SystemExit(f"{path}: truncated header at offset {offset}")
        header = bytearray(data[offset:offset + HEADER_SIZE])

        if header[58:60] != b"`\n":
            raise SystemExit(f"{path}: bad header magic at offset {offset}")

        name = bytes(header[0:16]).rstrip()
        size_field = bytes(header[48:58]).strip()
        try:
            size = int(size_field)
        except ValueError:
            raise SystemExit(f"{path}: unparsable size {size_field!r} for {name!r}")

        # BSD-style long names: the "__.SYMDEF" / "__.SYMDEF SORTED" table is a
        # member like any other, so no special casing is needed.
        for field_name, start, end, value in FIELDS:
            if end - start != len(value):
                raise SystemExit(
                    f"{path}: internal error: {field_name} field is {end - start} "
                    f"bytes but its replacement is {len(value)}"
                )
            header[start:end] = value
        assert len(header) == HEADER_SIZE, f"{path}: header resized while editing"

        out += header
        body = data[offset + HEADER_SIZE:offset + HEADER_SIZE + size]
        if len(body) != size:
            raise SystemExit(f"{path}: truncated member {name!r}")
        out += body

        # Members are padded to an even offset; the pad byte is not part of the
        # recorded size.
        offset += HEADER_SIZE + size
        if size % 2:
            if offset >= len(data):
                raise SystemExit(f"{path}: missing pad byte after {name!r}")
            out += data[offset:offset + 1]
            offset += 1

    if len(out) != len(data):
        raise SystemExit(f"{path}: rewritten archive is {len(out)} bytes, was {len(data)}")

    with open(path, "wb") as handle:
        handle.write(bytes(out))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    for path in argv[1:]:
        normalize(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
