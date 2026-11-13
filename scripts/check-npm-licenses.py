#!/usr/bin/env python3
"""Check the trimmed payload, not the optional packages in the npm lock file."""

import json
import os
import re
import sys
from pathlib import Path

LICENSE_NAME = re.compile(r"^(licen[cs]e|copying)(?:[._-].*)?$", re.I)
PACKAGE_NAME = re.compile(r"(?:@[a-z0-9._-]+/)?[a-z0-9._-]+")
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9.+_-]*")


def has_text(path):
    return path.is_file() and bool(path.read_text(encoding="utf-8").strip())


def check(node_modules, supplements):
    count = 0
    missing = []
    for root, _, files in os.walk(node_modules):
        directory = Path(root)
        # Ignore package.json files in examples, fixtures and bundled sources.
        installed = directory.parent.name == "node_modules" or (
            directory.parent.name.startswith("@")
            and directory.parent.parent.name == "node_modules"
        )
        if not installed or "package.json" not in files:
            continue
        package = json.loads((directory / "package.json").read_text(encoding="utf-8"))
        name, version = package.get("name", ""), package.get("version", "")
        if (not isinstance(name, str) or not PACKAGE_NAME.fullmatch(name)
                or any(part in (".", "..") for part in name.split("/"))
                or not isinstance(version, str) or not VERSION.fullmatch(version)):
            raise ValueError(f"invalid package identity: {directory}")
        count += 1
        bundled = any(
            LICENSE_NAME.fullmatch(file) and has_text(directory / file)
            for file in files
        )
        supplement = supplements / f"{name}@{version}.txt"
        if not bundled and not has_text(supplement):
            missing.append(f"{name}@{version}: {supplement}")
    if not count:
        raise ValueError(f"no installed npm packages found in {node_modules}")
    if missing:
        raise ValueError("missing npm license texts:\n" + "\n".join(sorted(missing)))
    return count


def main(argv):
    if len(argv) != 3:
        print("usage: check-npm-licenses.py <node_modules> <LICENSES/npm>", file=sys.stderr)
        return 2
    try:
        count = check(Path(argv[1]), Path(argv[2]))
    except (OSError, ValueError) as error:
        print(f"npm licenses: {error}", file=sys.stderr)
        return 1
    print(f"npm licenses: checked {count} packages")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
