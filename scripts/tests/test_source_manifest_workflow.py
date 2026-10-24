"""Exercise the checked-in shell steps using only a synthetic Git repository."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/source-manifest.yml"


class SourceManifestWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.run_command("git", "init", "-q")
        self.run_command("git", "config", "user.name", "Fixture")
        self.run_command("git", "config", "user.email", "fixture@example.invalid")
        (self.repo / "source.txt").write_text("synthetic source\n")
        self.run_command("git", "add", "source.txt")
        self.run_command("git", "commit", "-qm", "fixture")
        self.commit = self.run_command("git", "rev-parse", "HEAD").stdout.decode().strip()
        self.env = dict(os.environ, GITHUB_SHA=self.commit, GITHUB_OUTPUT=str(self.root / "output"),
                        SOURCE_REF="v1.2.3", RELEASE_TAG="v1.2.3", GITHUB_EVENT_NAME="release")
        # The manifest workflow runs on Ubuntu. Provide the equivalent local
        # hash executable when only macOS's shasum is available.
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shim = self.bin / "sha256sum"
        shim.write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n')
        shim.chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]

    def run_command(self, *args):
        return subprocess.run(args, cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)

    def step(self, name):
        match = re.search(r"^      - name: " + re.escape(name) + r"\n(.*?)(?=^      - |\Z)",
                          self.workflow, re.M | re.S)
        self.assertIsNotNone(match, "missing workflow step: " + name)
        return match.group(1)

    def run_step(self, name):
        block = self.step(name)
        match = re.search(r"^        run: \|\n((?:^          .*\n|^\n)*)", block, re.M)
        self.assertIsNotNone(match)
        script = "\n".join(line[10:] if line.startswith("          ") else line
                           for line in match.group(1).splitlines())
        # Model Actions expression substitution for the original unsafe steps.
        script = script.replace("${{ github.event.inputs.ref || github.ref_name }}", self.env["SOURCE_REF"])
        script = script.replace("${{ github.ref_name }}", self.env["RELEASE_TAG"])
        return subprocess.run(["bash", "-c", script], cwd=self.repo, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_ref_is_data_not_shell_code(self):
        self.env["SOURCE_REF"] = "v$(touch${IFS}injected)"
        self.run_command("git", "check-ref-format", "refs/tags/" + self.env["SOURCE_REF"])
        result = self.run_step("Build manifest")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse((self.repo / "injected").exists())
        self.assertIn(self.env["SOURCE_REF"], (self.repo / "SOURCE-MANIFEST.txt").read_text())

    def test_provenance_rejects_checkout_from_another_commit(self):
        self.env["GITHUB_SHA"] = "0" * 40
        self.assertNotEqual(self.run_step("Verify source provenance").returncode, 0)

    def test_provenance_accepts_matching_commit(self):
        self.assertEqual(self.run_step("Verify source provenance").returncode, 0)

    def test_generated_manifest_self_checks(self):
        result = self.run_step("Build manifest")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        result = self.run_step("Self-check the manifest")
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_published_release_runs_attachment(self):
        self.assertRegex(self.workflow, r"(?m)^  release:\n    types: \[published\]")
        block = self.step("Attach to release")
        self.assertIn("github.event_name == 'release'", block)
        # An already-created release must be uploaded to, even if no release
        # existed during the earlier tag-push run.
        gh = self.bin / "gh"
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GH_CALLS"\n')
        gh.chmod(0o755)
        self.env["GH_CALLS"] = str(self.root / "gh-calls")
        result = self.run_step("Attach to release")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn("release upload v1.2.3 SOURCE-MANIFEST.txt", Path(self.env["GH_CALLS"]).read_text())


if __name__ == "__main__":
    unittest.main()
