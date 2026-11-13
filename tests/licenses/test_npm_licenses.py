import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "npm_licenses", Path(__file__).resolve().parents[2] / "scripts/check-npm-licenses.py"
)
npm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(npm)


class NpmLicenseTests(unittest.TestCase):
    def audit(self, tree):
        directories = {}
        for file in tree:
            path = Path(file)
            directories.setdefault(str(path.parent), []).append(path.name)
        walk = [(directory, [], files) for directory, files in directories.items()]
        with patch.object(npm.os, "walk", return_value=walk), \
                patch.object(Path, "is_file", lambda path: str(path) in tree), \
                patch.object(Path, "read_text", lambda path, **kw: tree[str(path)]):
            return npm.check(Path("payload/node_modules"), Path("LICENSES/npm"))

    def package(self, directory="payload/node_modules/example", name="example", version="1.0.0"):
        return {directory + "/package.json": json.dumps({
            "name": name, "version": version, "license": "MIT",
        })}

    def test_metadata_and_notice_are_not_license_texts(self):
        tree = self.package()
        tree["payload/node_modules/example/NOTICE"] = "Attribution fixture"
        with self.assertRaisesRegex(ValueError, "example@1.0.0"):
            self.audit(tree)

    def test_root_license_spellings_and_empty_files(self):
        for name in ("LICENSE", "LICENCE.md", "copying.txt", "LICENSE-MIT"):
            with self.subTest(name=name):
                tree = self.package()
                tree["payload/node_modules/example/" + name] = "License fixture"
                self.assertEqual(self.audit(tree), 1)
                tree["payload/node_modules/example/" + name] = " \n"
                with self.assertRaises(ValueError):
                    self.audit(tree)

    def test_scoped_supplement_is_bound_to_version(self):
        tree = self.package("payload/node_modules/@scope/example", "@scope/example")
        tree["LICENSES/npm/@scope/example@1.0.0.txt"] = "License fixture"
        self.assertEqual(self.audit(tree), 1)
        tree = self.package("payload/node_modules/@scope/example", "@scope/example", "2.0.0")
        tree["LICENSES/npm/@scope/example@1.0.0.txt"] = "License fixture"
        with self.assertRaisesRegex(ValueError, "@scope/example@2.0.0"):
            self.audit(tree)

    def test_nested_dependencies_are_checked_but_examples_are_not(self):
        tree = self.package()
        tree["payload/node_modules/example/LICENSE"] = "License fixture"
        tree.update(self.package("payload/node_modules/example/examples/demo", "demo"))
        nested = "payload/node_modules/example/node_modules/nested"
        tree.update(self.package(nested, "nested"))
        with self.assertRaisesRegex(ValueError, "nested@1.0.0"):
            self.audit(tree)
        tree[nested + "/LICENSE"] = "License fixture"
        self.assertEqual(self.audit(tree), 2)

    def test_vendored_subcomponent_license_does_not_cover_package(self):
        tree = self.package()
        tree["payload/node_modules/example/lib/devtools/LICENSE"] = "Subcomponent fixture"
        with self.assertRaisesRegex(ValueError, "example@1.0.0"):
            self.audit(tree)

    def test_empty_supplement_and_empty_payload_fail(self):
        tree = self.package()
        tree["LICENSES/npm/example@1.0.0.txt"] = "\n"
        with self.assertRaises(ValueError):
            self.audit(tree)
        with self.assertRaisesRegex(ValueError, "no installed npm packages"):
            self.audit({})

    def test_unsafe_identity_fails(self):
        with self.assertRaisesRegex(ValueError, "invalid package identity"):
            self.audit(self.package(name="../outside"))


if __name__ == "__main__":
    unittest.main()
