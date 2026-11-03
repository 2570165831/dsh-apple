#!/usr/bin/env python3
"""Parse the actual Swift-embedded JavaScript before simulator acceptance."""
import hashlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root / 'app/DSHPortC/MobileWebPolish.swift').read_text()
body = source.split('static func bootstrapScript() -> String {', 1)[1].split('"""', 2)[1]
if '\\(' in body:
    raise SystemExit('Swift interpolation requires evaluating the literal before checking it')
body = body.replace('\\\\', '\\')
with tempfile.TemporaryDirectory(prefix='step18-js-') as directory:
    script = Path(directory) / 'bootstrap.js'
    script.write_text(body)
    result = subprocess.run(['node', '--check', str(script)], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise SystemExit(result.stderr)
print('bootstrap JavaScript parses; sha256=' + hashlib.sha256(body.encode()).hexdigest())
