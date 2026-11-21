"""Release workflow steps against a local gh fixture. Nothing is published."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}", RUNNER_TEMP=temp.name,
                        GITHUB_ENV=str(self.root / "env"), GITHUB_REPOSITORY="example/test", TAG="v1.0.0")

    def mock_gh(self, commands):
        path = self.root / "gh"
        path.write_text("#!/bin/bash\nset -eu\n" + commands, encoding="utf-8")
        path.chmod(0o755)

    def run_step(self, name):
        return subprocess.run([str(REPO / name)], cwd=REPO, env=self.env, capture_output=True, text=True)

    def test_cask_requires_a_published_stable_release(self):
        self.mock_gh("""
case "$1 $2" in
  'release view') echo "$METADATA" ;;
  'release download')
    printf '%064d  Agneta-1.0.0-arm64.dmg\\n' 1 > "$RUNNER_TEMP/SHA256SUMS.txt"
    if [[ -z ${MISSING_INTEL:-} ]]; then
      printf '%064d  Agneta-1.0.0-x86_64.dmg\\n' 2 >> "$RUNNER_TEMP/SHA256SUMS.txt"
    fi ;;
  *) exit 2 ;;
esac
""")
        output = self.root / "agneta.rb"
        for draft, prerelease, tag in [(True, False, "v1.0.0"), (False, True, "v1.0.0"), (False, False, "v2.0.0")]:
            with self.subTest(draft=draft, prerelease=prerelease, tag=tag):
                self.env["METADATA"] = json.dumps(dict(tagName=tag, isDraft=draft, isPrerelease=prerelease))
                self.assertNotEqual(self.run_step("scripts/dev/fill-homebrew-cask").returncode, 0)
                self.assertFalse(output.exists())
        self.env["METADATA"] = json.dumps(dict(tagName="v1.0.0", isDraft=False, isPrerelease=False))
        self.env["MISSING_INTEL"] = "1"
        self.assertNotEqual(self.run_step("scripts/dev/fill-homebrew-cask").returncode, 0)
        self.assertFalse(output.exists())
        del self.env["MISSING_INTEL"]
        result = self.run_step("scripts/dev/fill-homebrew-cask")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('version "1.0.0"', output.read_text(encoding="utf-8"))

    def test_pages_fallback_requires_a_confirmed_empty_release_list(self):
        self.mock_gh("""
case "$1 $2" in
  'api repos/example/test/releases/latest') echo "$LATEST"; exit "$API_STATUS" ;;
  'release list') echo "$RELEASES"; exit "$LIST_STATUS" ;;
  *) exit 2 ;;
esac
""")
        step = "site/latest-release"
        output = self.root / "release.json"
        release = json.dumps(dict(tag_name="v1.0.0", assets=[]))
        self.env.update(LATEST=release, API_STATUS="0", LIST_STATUS="1", RELEASES="[]")
        self.assertEqual(self.run_step(step).returncode, 0)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8")), json.loads(release))

        self.env["LATEST"] = "{}"
        self.assertNotEqual(self.run_step(step).returncode, 0)
        self.env.update(LATEST="", API_STATUS="1")
        self.assertNotEqual(self.run_step(step).returncode, 0)
        self.env.update(LIST_STATUS="0", RELEASES='[{"tagName":"v1.0.0"}]')
        self.assertNotEqual(self.run_step(step).returncode, 0)
        self.env["RELEASES"] = "[]"
        self.assertEqual(self.run_step(step).returncode, 0)
        self.assertEqual(output.read_bytes(), b"")
