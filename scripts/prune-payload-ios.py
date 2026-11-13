#!/usr/bin/env python3
"""Replay the iOS vendor exclusions recovered from the tracked rc.2 payload.

Move reproducible npm files into work/ rather than permanently deleting them.
This does not run npm, package lifecycle hooks, or any application code.
"""
import json
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    modules = ROOT / 'payload/node_modules'
    if modules.is_symlink() or not modules.is_dir():
        raise ValueError('payload/node_modules must be a real directory')
    policy = json.loads((ROOT / 'payload/ios-pruning.json').read_text())
    candidates = []
    for directory, dirs, files in os.walk(modules, followlinks=False):
        for name in files + [name for name in dirs if (Path(directory) / name).is_symlink()]:
            path = Path(directory) / name
            relative = path.relative_to(modules).as_posix()
            omitted = (
                any(relative == p or relative.startswith(p + '/') for p in policy['omit_packages'])
                or any(relative.endswith(suffix) for suffix in policy['omit_suffixes'])
                or any(relative == p or (p.endswith('/') and relative.startswith(p))
                       for p in policy['omit_paths'])
            )
            if omitted:
                candidates.append((path, relative))
    if not candidates:
        print('iOS payload pruning: 0 files (already pruned)')
        return
    work = ROOT / 'work'
    work.mkdir(exist_ok=True)
    quarantine = Path(tempfile.mkdtemp(prefix='pruned-payload-', dir=work))
    total = 0
    for source, relative in candidates:
        total += source.lstat().st_size
        destination = quarantine / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        source.rename(destination)
    print(f'iOS payload pruning: {len(candidates)} files, {total} bytes; '
          f'recoverable in {quarantine.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
