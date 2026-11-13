import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# scripts/fetch-payload.sh ships only in the public tree (it is added by the
# export overlay, together with scripts/bootstrap.sh), so the private tree
# checks the rootfs script alone. A public tree missing it fails, not skips.
# The overlay adds scripts/bootstrap.sh next to fetch-payload.sh.
PUBLIC_TREE = (ROOT / "scripts/bootstrap.sh").exists()
NOTICE_SCRIPTS = (("scripts/fetch-payload.sh",) if PUBLIC_TREE else ()) + ("ish/scripts/build-rootfs.sh",)
STUBS = """
python3() { return "${NOTICE_TEST_PYTHON_STATUS:-1}"; }
shasum() { return "${NOTICE_TEST_HASH_STATUS:-1}"; }
cmp() {
    while IFS= read -r line; do :; done
    return "${NOTICE_TEST_CMP_STATUS:-1}"
}
cd() { return 0; }
"""


class NoticePolicyTests(unittest.TestCase):
    def run_shell(self, script, **variables):
        return subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c",
             STUBS + "\nset -euo pipefail\n" + script],
            cwd=ROOT, env={"PATH": "/usr/bin:/bin", "ROOT": str(ROOT), "SRCROOT": str(ROOT / "app"),
                           "TMP": str(ROOT), "OUT_DIR": str(ROOT), **variables},
            capture_output=True, text=True,
        )

    def wrapper(self, file):
        source = (ROOT / file).read_text(encoding="utf-8")
        block = re.search(r"^if ! python3 .*?^fi$", source, re.M | re.S).group(0)
        # Keep the stubbed command's output in memory rather than creating a draft.
        return block.replace('> "$OUT_DIR/ROOTFS-PACKAGES.txt"', "")

    def phase(self):
        source = (ROOT / "scripts/gen-xcode-project.rb").read_text(encoding="utf-8")
        return source.split("licences.shell_script = <<~SH\n", 1)[1].split("\nSH\n", 1)[0]

    def test_fetch_and_rootfs_warn_by_default_and_fail_only_when_required(self):
        for file in NOTICE_SCRIPTS:
            for required in (None, "0", "1"):
                with self.subTest(file=file, required=required):
                    variables = {} if required is None else {"DSH_REQUIRE_NOTICES": required}
                    result = self.run_shell(self.wrapper(file), **variables)
                    self.assertEqual(result.returncode, 1 if required == "1" else 0)
                    if required != "1":
                        self.assertIn("warning:", result.stderr)

    def test_successful_fetch_and_rootfs_checks_do_not_warn(self):
        for file in NOTICE_SCRIPTS:
            with self.subTest(file=file):
                result = self.run_shell(self.wrapper(file), DSH_REQUIRE_NOTICES="1",
                                        NOTICE_TEST_PYTHON_STATUS="0")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")

    def test_default_debug_builds_warn_on_both_sdks(self):
        for sdk in ("iphoneos", "iphonesimulator"):
            with self.subTest(sdk=sdk):
                result = self.run_shell(self.phase(), CONFIGURATION="Debug",
                                        ACTION="build", PLATFORM_NAME=sdk)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("warning:", result.stderr)
                self.assertNotIn("error:", result.stderr)

    def test_distribution_conditions_cannot_be_disabled_by_zero(self):
        for configuration, action, required in (
                ("Release", "build", "0"), ("Debug", "install", "0"),
                ("Debug", "archive", "0"), ("Debug", "build", "1")):
            for sdk in ("iphoneos", "iphonesimulator"):
                with self.subTest(configuration=configuration, action=action,
                                  required=required, sdk=sdk):
                    result = self.run_shell(self.phase(), CONFIGURATION=configuration,
                                            ACTION=action, PLATFORM_NAME=sdk,
                                            DSH_REQUIRE_NOTICES=required)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("error:", result.stderr)

    def test_each_failed_check_blocks_distribution(self):
        for failed in ("PYTHON", "HASH", "CMP"):
            with self.subTest(failed=failed):
                statuses = {f"NOTICE_TEST_{name}_STATUS": "0"
                            for name in ("PYTHON", "HASH", "CMP")}
                statuses[f"NOTICE_TEST_{failed}_STATUS"] = "1"
                result = self.run_shell(self.phase(), CONFIGURATION="Release", **statuses)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_complete_distribution_checks_pass(self):
        result = self.run_shell(self.phase(), CONFIGURATION="Release", ACTION="install",
                                DSH_REQUIRE_NOTICES="1", NOTICE_TEST_PYTHON_STATUS="0",
                                NOTICE_TEST_HASH_STATUS="0", NOTICE_TEST_CMP_STATUS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
