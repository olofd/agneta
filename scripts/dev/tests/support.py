# Throwaway git repositories for the check scripts' tests: each test runs a script, as scripts/check does, inside one.
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

DEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(DEV))


class Repository(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="agneta-check-test-")
        self.addCleanup(shutil.rmtree, self.root)
        self.git("init", "-q", "-b", "main")

    def git(self, *args):
        return subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", *args],
                              cwd=self.root, capture_output=True, text=True, check=True).stdout

    def write(self, name, text):
        path = os.path.join(self.root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as file:
            file.write(text)

    def read(self, name):
        with open(os.path.join(self.root, name), encoding="utf-8") as file:
            return file.read()

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "commit")
        return self.git("rev-parse", "HEAD").strip()

    def run_script(self, script, *args):
        """Runs a Python script of scripts/dev on the Python running the tests, so a run on 3.9 checks 3.9."""
        return subprocess.run([sys.executable, os.path.join(DEV, script), *args], cwd=self.root, capture_output=True,
                              text=True)
