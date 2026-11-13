import importlib.util
import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "rootfs_notices", Path(__file__).resolve().parents[2] / "scripts/rootfs-notices.py"
)
rootfs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rootfs)


class RootfsNoticeTests(unittest.TestCase):
    def capture(self, records):
        return rootfs.BEGIN + "\n" + records + "\n" + rootfs.END + "\n"

    def test_fields_after_version_and_last_record_without_blank_line(self):
        text = "P:ssl_client\nV:1.0-r0\nL:GPL-2.0-only\no:busybox"
        inventory = rootfs.packages("emulator diagnostic\n" + self.capture(text))
        self.assertEqual(inventory, [{
            "P": "ssl_client", "V": "1.0-r0", "L": "GPL-2.0-only", "o": "busybox",
        }])
        self.assertIn("| `ssl_client` | `1.0-r0` | `GPL-2.0-only` | `busybox` |",
                      rootfs.render(inventory))

    def test_records_are_sorted_and_all_packages_are_retained(self):
        text = "P:z\nV:1\nL:MIT\no:z\n\nP:a\nV:2\nL:ISC\no:source"
        self.assertEqual([p["P"] for p in rootfs.packages(self.capture(text))], ["a", "z"])

    def test_missing_fields_and_failed_guest_capture_fail(self):
        for text in ("P:a\nV:1", "P:a\nV:1\nL:MIT", ""):
            with self.subTest(text=text), self.assertRaises(ValueError):
                rootfs.packages(self.capture(text))
        with self.assertRaisesRegex(ValueError, "incomplete installed database"):
            rootfs.packages(rootfs.BEGIN + "\ncat: cannot read installed\n")
        with self.assertRaises(ValueError):
            rootfs.packages(self.capture("P:a\nV:1\nV:2\nL:MIT\no:a"))

    def test_all_license_ids_and_exceptions_are_required(self):
        expression = "(MIT OR BSD-2-Clause) AND GPL-3.0-or-later WITH GCC-exception-3.1"
        self.assertEqual(rootfs.license_ids(expression),
                         {"MIT", "BSD-2-Clause", "GPL-3.0-or-later", "GCC-exception-3.1"})
        self.assertEqual(rootfs.license_ids(expression.replace("OR", "or")
                                          .replace("AND", "And").replace("WITH", "with")),
                         rootfs.license_ids(expression))

    def test_unknown_license_or_missing_copyright_fails(self):
        inventory = rootfs.packages(self.capture("P:liba\nV:1-r0\nL:MIT\no:source"))
        tree = {"LICENSES/rootfs/texts/MIT.txt": "License fixture"}
        with patch.object(Path, "is_file", lambda path: str(path) in tree), \
                patch.object(Path, "read_text", lambda path, **kw: tree[str(path)]):
            with self.assertRaisesRegex(ValueError, "source@1-r0.txt"):
                rootfs.check(inventory, Path("LICENSES/rootfs"))
            tree["LICENSES/rootfs/packages/source@1-r0.txt"] = "Copyright fixture"
            rootfs.check(inventory, Path("LICENSES/rootfs"))
            inventory[0]["L"] = "MIT and New-License"
            with self.assertRaisesRegex(ValueError, "New-License.txt"):
                rootfs.check(inventory, Path("LICENSES/rootfs"))
            tree["LICENSES/rootfs/texts/New-License.txt"] = " \n"
            with self.assertRaises(ValueError):
                rootfs.check(inventory, Path("LICENSES/rootfs"))

    def test_custom_and_unsupported_expressions_keep_the_draft(self):
        for expression in ("custom:example", "MIT / BSD"):
            with self.subTest(expression=expression):
                text = self.capture(f"P:a\nV:1\nL:{expression}\no:a")
                output, errors = io.StringIO(), io.StringIO()
                with patch.object(Path, "read_text", return_value=text), \
                        patch.object(Path, "is_file", return_value=False), \
                        redirect_stdout(output), redirect_stderr(errors):
                    self.assertEqual(rootfs.main(["rootfs-notices.py", "capture", "licenses"]), 1)
                self.assertIn(f"| `a` | `1` | `{expression}` | `a` |", output.getvalue())
                self.assertIn("a: ", errors.getvalue())
                self.assertIn("packages/a@1.txt", errors.getvalue())
        with self.assertRaisesRegex(ValueError, "explicit reviewed mapping"):
            rootfs.license_ids("CUSTOM:example")

    def test_invalid_capture_does_not_emit_a_draft(self):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(Path, "read_text", return_value=rootfs.BEGIN + "\nP:a\n"), \
                redirect_stdout(output), redirect_stderr(errors):
            self.assertEqual(rootfs.main(["rootfs-notices.py", "capture", "licenses"]), 1)
        self.assertEqual(output.getvalue(), "")

    def test_unsafe_metadata_fails(self):
        with self.assertRaises(ValueError):
            rootfs.packages(self.capture("P:a\nV:1\nL:MIT\no:../outside"))
        with self.assertRaises(ValueError):
            rootfs.license_ids("MIT / BSD")


if __name__ == "__main__":
    unittest.main()
