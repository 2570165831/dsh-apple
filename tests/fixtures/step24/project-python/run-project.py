"""The Python project used by step 24's "real project" criterion.

Why it is a generator rather than a checked-in tree, and why its test story is
`unittest` rather than `pytest`: the image ships no `pip` (step 24's own
constraint — no pip, no compiler), so a project that needed a downloaded test
runner could not run at all. `unittest` is in the standard library, which makes
the honest claim "a Python project can be laid out, imported, and tested here"
rather than "a Python project can install anything here".

A virtualenv IS available: `python3 -m venv` works because CPython carries its
own `pip` wheel internally (`ensurepip`), and building it needs no download and
no compiler. That is measured too — it is the one dependency path this image has,
and the report has to say what it can and cannot reach.

The script prints ONE json line on stdout; everything else goes to stderr.
"""

import json
import os
import subprocess
import sys
import time

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
if not ROOT:
    sys.stderr.write("usage: python3 run-project.py <dir>\n")
    raise SystemExit(2)


def shell(command):
    """Run a shell command in the project; return the exit code and both streams."""
    started = time.time()
    completed = subprocess.run(
        command,
        shell=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    return {
        "command": command,
        "exitCode": completed.returncode,
        "stdout": completed.stdout[-2000:],
        "stderr": completed.stderr[-2000:],
        "seconds": round(time.time() - started, 2),
    }


FILES = {
    "pyproject.toml": """[build-system]
requires = []
build-backend = "step24_backend"

[project]
name = "step24-textstat"
version = "1.0.0"
description = "A small project that is imported and tested without pip"
requires-python = ">=3.12"

[tool.step24]
note = "no build backend is used; this file records the layout"
""",

    "src/textstat/__init__.py": """\"\"\"Text statistics, deliberately dependency-free.

The image has no pip and no compiler, so a project whose value came from a
third-party package could not run here at all. What this package shows instead is
the part that does work: a package layout, a relative import, a dataclass, a
generator, and a ``__main__`` entry point.
\"\"\"

from .counts import Summary, summarise, words

__all__ = ["Summary", "summarise", "words"]
""",

    "src/textstat/counts.py": """\"\"\"The actual logic, in its own module so the tests exercise a real import.\"\"\"

from dataclasses import dataclass, field
from typing import Iterable


@dataclass(frozen=True)
class Summary:
    \"\"\"What ``summarise`` reports about a piece of text.\"\"\"

    characters: int
    words: int
    lines: int
    longest: str
    frequencies: dict = field(default_factory=dict)

    def as_dict(self):
        return {
            "characters": self.characters,
            "words": self.words,
            "lines": self.lines,
            "longest": self.longest,
            "top": sorted(self.frequencies.items(), key=lambda item: (-item[1], item[0]))[:3],
        }


def words(text: str) -> Iterable[str]:
    \"\"\"Yield the words in ``text``, lowercased, punctuation stripped.

    A generator on purpose: the test suite checks that it is lazy, because that
    is the kind of thing an emulated interpreter can get subtly wrong.
    \"\"\"
    current = []
    for character in text:
        if character.isalnum() or character in "-_":
            current.append(character)
        elif current:
            yield "".join(current).lower()
            current = []
    if current:
        yield "".join(current).lower()


def summarise(text: str) -> Summary:
    \"\"\"Count the things ``Summary`` describes.\"\"\"
    found = list(words(text))
    frequencies = {}
    for word in found:
        frequencies[word] = frequencies.get(word, 0) + 1
    longest = max(found, key=len) if found else ""
    return Summary(
        characters=len(text),
        words=len(found),
        lines=len(text.splitlines()),
        longest=longest,
        frequencies=frequencies,
    )
""",

    "src/textstat/__main__.py": """\"\"\"``python3 -m textstat`` — the entry point a real project has.\"\"\"

import sys

from .counts import summarise


def main(argv):
    text = " ".join(argv[1:]) if len(argv) > 1 else sys.stdin.read()
    summary = summarise(text)
    print(summary.characters, summary.words, summary.lines, summary.longest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
""",

    "tests/test_counts.py": """\"\"\"The project's own test suite: stdlib ``unittest``, no downloads.\"\"\"

import sys
import unittest
from pathlib import Path

# A src layout means the package is not importable without this. Doing it here
# rather than installing the project keeps the test honest about what is on the
# path when it runs.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from textstat import Summary, summarise, words  # noqa: E402


class WordsTest(unittest.TestCase):
    def test_splits_on_whitespace_and_punctuation(self):
        self.assertEqual(list(words("Hello, world!  again")), ["hello", "world", "again"])

    def test_is_lazy(self):
        source = words("a b c d e")
        self.assertEqual(next(source), "a")

    def test_keeps_internal_hyphens(self):
        self.assertEqual(list(words("well-known state-of-the-art")),
                         ["well-known", "state-of-the-art"])


class SummariseTest(unittest.TestCase):
    def test_counts(self):
        summary = summarise("one two two\\nthree")
        self.assertIsInstance(summary, Summary)
        self.assertEqual(summary.words, 4)
        self.assertEqual(summary.lines, 2)
        self.assertEqual(summary.characters, len("one two two\\nthree"))

    def test_longest(self):
        self.assertEqual(summarise("a longer word").longest, "longer")

    def test_empty(self):
        summary = summarise("")
        self.assertEqual((summary.words, summary.longest, summary.lines), (0, "", 0))

    def test_top_three(self):
        summary = summarise("b b b a a c d")
        self.assertEqual([word for word, _ in summary.as_dict()["top"]], ["b", "a", "c"])


if __name__ == "__main__":
    unittest.main()
""",

    "tests/test_entry.py": """\"\"\"The module entry point, run as a subprocess so the real path is tested.\"\"\"

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class EntryTest(unittest.TestCase):
    def test_module_main(self):
        completed = subprocess.run(
            [sys.executable, "-m", "textstat", "hello", "world"],
            cwd=ROOT / "src",
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.split(), ["11", "2", "1", "hello"])


if __name__ == "__main__":
    unittest.main()
""",
}

out = {"root": ROOT, "files": []}

for name, content in FILES.items():
    target = os.path.join(ROOT, name)
    os.makedirs(os.path.dirname(target) or ROOT, exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(content)
    out["files"].append({"name": name, "bytes": len(content.encode("utf-8"))})

# The image's own pip, before any venv. This is expected to FAIL, and recording
# the exact failure is the point: it is the constraint the capability text ships.
out["system_pip"] = shell("python3 -m pip --version")

# The one dependency path this image has: a venv, built from CPython's bundled
# pip wheel (no download, no compiler).
out["venv"] = shell("python3 -m venv .venv")
out["venv_pip"] = shell(".venv/bin/python3 -m pip --version")
# And a pure-Python wheel, which is the only kind that can install here.
out["venv_install"] = shell(
    ".venv/bin/python3 -m pip install --disable-pip-version-check --no-input six"
)

# The compiled-extension arm. Recorded as a fact, not attempted as a hope: this
# image has no compiler and no headers, so a source distribution must fail.
# A package that ships ONLY an sdist, into a fresh venv, because `--no-binary` on
# an already-installed wheel is satisfied by the wheel and builds nothing.
out["sdist_attempt"] = shell(
    "python3 -m venv .venv-sdist >/dev/null 2>&1; "
    ".venv-sdist/bin/python3 -m pip install --disable-pip-version-check --no-input "
    "--no-binary :all: --no-cache-dir six 2>&1 | tail -6; echo \"EXIT=$?\""
)

# PIPESTATUS, not `$?`: a pipeline ending in `tail` reports tail's status, so a
# failing suite printed EXIT=0 and the control proved nothing. Measured here.
out["test"] = shell("python3 -m unittest discover -s tests -v > /tmp/u.log 2>&1; "
                    "rc=$?; cat /tmp/u.log; echo \"EXIT=$rc\"")

# A negative control: the suite must be able to fail.
with open(os.path.join(ROOT, "tests", "test_zz_deliberate.py"), "w", encoding="utf-8") as handle:
    handle.write("import unittest\n\n\nclass DeliberateTest(unittest.TestCase):\n"
                 "    def test_must_fail(self):\n        self.assertEqual(1, 2)\n")
out["negative_control"] = shell("python3 -m unittest discover -s tests > /tmp/n.log 2>&1; "
                                "rc=$?; tail -4 /tmp/n.log; echo \"EXIT=$rc\"")
os.unlink(os.path.join(ROOT, "tests", "test_zz_deliberate.py"))

sys.stderr.write(out["test"]["stderr"])
sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
