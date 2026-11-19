# swift-format-changed: which lines count as changed, and what --fix touches. Needs swift-format (Xcode).
import os
import shutil
import subprocess
import unittest

from support import REPO, Repository

AVAILABLE = shutil.which("xcrun") is not None and subprocess.run(
    ["xcrun", "--find", "swift-format"], capture_output=True).returncode == 0

# Three statements the formatter would rewrap (and a blank line it would remove), as old code may be.
OLD = """func old() {
    let a = [1,2,3]
      let b = a.map { $0 *  2 }


    print(a, b)
}
"""


@unittest.skipUnless(AVAILABLE, "swift-format isn't installed (it comes with Xcode)")
class SwiftFormatChangedTests(Repository):
    def setUp(self):
        super().setUp()
        shutil.copy(os.path.join(REPO, ".swift-format"), os.path.join(self.root, ".swift-format"))
        self.write("Sources/Old.swift", OLD)
        self.base = self.commit()

    def check(self, *args):
        return self.run_script("swift-format-changed", "--base", self.base, *args)

    def test_unchanged_old_code_passes(self):
        self.assertEqual(self.check().returncode, 0)

    def test_a_pure_rename_changes_no_line(self):
        self.git("mv", "Sources/Old.swift", "Sources/Renamed.swift")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.commit()
        self.assertEqual(self.check().returncode, 0)

    def test_a_rename_counts_only_its_edited_lines(self):
        self.git("mv", "Sources/Old.swift", "Sources/Renamed.swift")
        self.write("Sources/Renamed.swift", OLD.replace("    print(a, b)", "    print(a,b)"))
        result = self.check()
        self.assertEqual(result.returncode, 1)
        # One edit: the changed line, with the extra blank line just above it that the formatter removes too.
        self.assertEqual(result.stdout.count("not formatted"), 1, result.stdout)
        self.assertIn("Sources/Renamed.swift:5: not formatted", result.stdout)
        self.assertIn("+    print(a, b)", result.stdout)

    def test_paths_with_spaces_and_non_ascii(self):
        self.write("Sources/Små filer/Ny fil.swift", "let x = [1,2]\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/Små filer/Ny fil.swift:1: not formatted", result.stdout)
        self.write("Sources/Små filer/Ny fil.swift", "let x = [1, 2]\n")
        self.assertEqual(self.check().returncode, 0)

    def test_fix_formats_around_changed_lines_only(self):
        self.write("Sources/Old.swift", OLD.replace("    print(a, b)", "    print(a,b)"))
        self.assertEqual(self.check("--fix").returncode, 0)
        fixed = self.read("Sources/Old.swift")
        self.assertIn("    print(a, b)", fixed)
        self.assertIn("let a = [1,2,3]", fixed)  # an old line the change didn't touch stays as it was
        self.assertEqual(self.check().returncode, 0)

    def test_fix_reports_rule_findings_at_their_new_lines(self):
        # The first changed statement grows to two lines when formatted; the rule finding below it moves down one.
        long = "    let first = [" + ", ".join(f"value{n}" for n in range(14)) + "]\n"
        self.write("Sources/Old.swift", OLD.replace("    print(a, b)", long.rstrip("\n") + "\n    let Bad_name = 1"))
        result = self.check("--fix")
        fixed = self.read("Sources/Old.swift").splitlines()
        line = next(n for n, text in enumerate(fixed, 1) if "Bad_name" in text)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Sources/Old.swift:{line}:", result.stdout)
        self.assertIn("[AlwaysUseLowerCamelCase]", result.stdout)

    def test_all_counts_every_line(self):
        result = self.run_script("swift-format-changed", "--all")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/Old.swift", result.stdout)


if __name__ == "__main__":
    unittest.main()
