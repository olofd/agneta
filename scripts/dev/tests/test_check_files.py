# check-files: what the whitespace check finds and what --fix may touch; the data and Python checks.
import sys
import unittest

from support import Repository


class WhitespaceTests(Repository):
    def setUp(self):
        super().setUp()
        self.write("clean.txt", "fine\n")
        self.write("tracked.txt", "a  \nb\n\n")
        self.write("notes.md", "a line break  \nnext\n")
        self.write("Licenses/Other.txt", "verbatim  \n")
        self.commit()

    def test_finds_trailing_whitespace_and_blank_end_lines(self):
        result = self.run_script("check-files", "whitespace")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tracked.txt:1: trailing whitespace", result.stdout)
        self.assertIn("tracked.txt: blank line at the end", result.stdout)
        self.assertIn("notes.md:1: trailing whitespace", result.stdout)
        self.assertNotIn("Licenses", result.stdout)

    def test_fix_repairs_tracked_files_only_and_leaves_meaningful_spaces(self):
        self.write("untracked.txt", "x \n")
        result = self.run_script("check-files", "whitespace", "--fix")
        self.assertEqual(self.read("tracked.txt"), "a\nb\n")
        self.assertEqual(self.read("untracked.txt"), "x \n")
        self.assertEqual(self.read("notes.md"), "a line break  \nnext\n")
        self.assertIn("untracked.txt: not repaired: it isn't tracked", result.stdout)
        self.assertIn("notes.md: not repaired: its trailing spaces may be content", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_conflict_markers_are_never_repaired(self):
        self.write("tracked.txt", "<<<<<<< ours\na \n=======\nb\n>>>>>>> theirs\n")
        result = self.run_script("check-files", "whitespace", "--fix")
        self.assertIn("tracked.txt:1: conflict marker", result.stdout)
        self.assertIn("a \n", self.read("tracked.txt"))

    def test_paths_with_spaces_and_non_ascii(self):
        self.write("Små filer/en fil.txt", "x \n")
        self.assertIn("Små filer/en fil.txt:1: trailing whitespace", self.run_script("check-files", "whitespace").stdout)


class DataAndPythonTests(Repository):
    def test_data_files_must_parse(self):
        self.write("good.json", '{"a": 1}\n')
        self.write("bad.lock", '{"a": \n')
        result = self.run_script("check-files", "data")
        self.assertEqual(result.returncode, 1)
        self.assertIn("bad.lock: doesn't parse", result.stdout)

    @unittest.skipIf(sys.version_info >= (3, 11), "TOML is checked on this Python")
    def test_toml_skipped_on_old_python_says_so(self):
        self.write("a.toml", "x = 1\n")
        self.assertIn("1 TOML file(s) not checked", self.run_script("check-files", "data").stdout)

    def test_python_compiles_with_warnings_as_errors(self):
        self.write("tool", "#!/usr/bin/env python3\nprint('\\d')\n")
        result = self.run_script("check-files", "python")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tool: SyntaxError", result.stdout)  # the escape's warning, raised as an error
        self.assertIn("invalid escape sequence", result.stdout)


if __name__ == "__main__":
    unittest.main()
