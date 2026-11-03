#!/usr/bin/env python3
"""Compare the app's built-in reset table against the planner's TIERS.

WHY THIS EXISTS
---------------
`sim/reset-plan.mjs` is the one place that decides which paths a reset moves, and
`app/DSHPortC/ResetSheet.swift` carries a second copy of the same table because
the failure screen needs it when Node never ran (`boot/reset-plan.json` is written
by Node at launch, and the launch that failed is exactly the one that did not
write it).

Two copies of one table is how a data-loss bug starts: a path added to `TIERS` and
not to the Swift table would be left behind by the fallback, and a path added to
the Swift table and not to `TIERS` would be moved by a plan nobody reviewed. This
script fails when the two disagree, so the copy stays a copy.

HOW IT READS THE SWIFT SIDE
---------------------------
The Swift table is a literal in `ResetSheet.swift` (`ResetTable.tiers`), one
`("relative", "reason")` pair per line. It is parsed as text rather than compiled,
so this runs without Xcode and without a built app — the same reason
`scripts/check-exif.py` is a script and not a test target.

APPLE-SIDE PATHS AND THE PLANNER'S ROOTS
----------------------------------------
`TIERS` names each entry against a root key (`dshHome`, `appSupport`,
`container`); the Swift table spells the resulting container-relative path out in
full, because the app resolves it against the container and never computes
`Library/Application Support/DSH` from parts. `relativeTable()` is the function
that turns one into the other, and it is what this script compares against, so the
mapping itself is not re-implemented here either.

    python3 scripts/reset-plan-parity.py            # check, exit 1 on drift
    python3 scripts/reset-plan-parity.py --json     # machine-readable result
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT = ROOT / "app/DSHPortC/ResetSheet.swift"

# The four tiers, in the order the sheet shows them. `guest` is in the table but
# not in any of the four combinations — the sheet keeps it as a separate entrance,
# and `relativeCombos()` mirrors that.
TIERS = ("always", "conversations", "settings", "guest")

ENTRY = re.compile(r'\(\s*"([^"]+)"\s*,\s*\n?\s*"([^"]*)"\s*\)')


def node_table() -> dict[str, list[tuple[str, str]]]:
    """`relativeTable()` from sim/reset-plan.mjs, as Python data."""
    script = (
        "import('./sim/reset-plan.mjs').then((m) => {"
        "  const t = m.relativeTable();"
        "  process.stdout.write(JSON.stringify(t));"
        "});"
    )
    result = subprocess.run(
        ["node", "--input-type=module", "-e", script],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"node could not import sim/reset-plan.mjs:\n{result.stderr}")
    raw = json.loads(result.stdout)
    return {tier: [(e["relative"], e["reason"]) for e in entries] for tier, entries in raw.items()}


def swift_table() -> dict[str, list[tuple[str, str]]]:
    """`ResetTable.tiers` from ResetSheet.swift, parsed as text.

    Scoped to the `static let tiers` block so the many other `(...)` pairs and
    string literals in that file — accessibility identifiers, key names — cannot be
    mistaken for entries.
    """
    text = SWIFT.read_text(encoding="utf-8")
    start = text.index("static let tiers")
    # The block ends at the first `]` that closes the outer array: the table is the
    # only thing between them, and every inner `]` is preceded by a `)`.
    end = text.index("\n    ]\n", start)
    block = text[start:end]

    # Split into tier segments first, then match whole entries inside each one.
    # Matching line by line would miss every entry: the Swift table puts the path
    # and the reason on two lines (`("path",` / `"reason"),`), which is what makes
    # the longer reasons readable in the source.
    segments = list(re.finditer(r'\("(\w+)",\s*\[', block))
    table: dict[str, list[tuple[str, str]]] = {}
    for index, segment in enumerate(segments):
        tier = segment.group(1)
        body_start = segment.end()
        body_end = segments[index + 1].start() if index + 1 < len(segments) else len(block)
        body = block[body_start:body_end]
        table.setdefault(tier, [])
        for entry in ENTRY.finditer(body):
            table[tier].append((entry.group(1), entry.group(2)))
    return table


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the comparison as JSON")
    args = parser.parse_args()

    node = node_table()
    swift = swift_table()

    problems: list[str] = []

    for tier in TIERS:
        if tier not in node:
            problems.append(f"TIERS has no {tier} tier but the app's table does")
            continue
        if tier not in swift:
            problems.append(f"ResetSheet.swift has no {tier} tier")
            continue
        node_paths = [p for p, _ in node[tier]]
        swift_paths = [p for p, _ in swift[tier]]
        for path in node_paths:
            if path not in swift_paths:
                problems.append(f"{tier}: {path} is in TIERS but not in ResetSheet.swift")
        for path in swift_paths:
            if path not in node_paths:
                problems.append(f"{tier}: {path} is in ResetSheet.swift but not in TIERS")
        if len(node_paths) != len(set(node_paths)):
            problems.append(f"{tier}: TIERS names a path twice")
        if len(swift_paths) != len(set(swift_paths)):
            problems.append(f"{tier}: ResetSheet.swift names a path twice")
        if node_paths != swift_paths:
            # Order matters: the sheet lists the paths in the order it shows them,
            # and a reordering that only the fallback knows about makes the panel
            # change shape depending on whether Node answered.
            problems.append(f"{tier}: the entries are in a different order")

    for tier in swift:
        if tier not in TIERS:
            problems.append(f"{tier} is a tier in ResetSheet.swift that TIERS does not have")

    result = {
        "ok": not problems,
        "problems": problems,
        "tiers": {tier: len(node.get(tier, [])) for tier in TIERS},
    }
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"tiers: {', '.join(f'{t}={len(node.get(t, []))}' for t in TIERS)}")
        if problems:
            print("DRIFT between sim/reset-plan.mjs TIERS and ResetSheet.swift ResetTable.tiers:")
            for problem in problems:
                print(f"  - {problem}")
        else:
            print("OK: the app's built-in table matches TIERS entry for entry, in order")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
