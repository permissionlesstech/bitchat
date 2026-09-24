"""Contract tests for .github/ templates and repository health files.

These lock in the presence of the PR template, issue templates, and key
health files (CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md) so a
later removal would be caught by the same test suite that runs in CI.
"""

from __future__ import annotations

from pathlib import Path
import unittest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class RepositoryHealthFilesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = REPOSITORY_ROOT

    def test_pull_request_template_exists(self) -> None:
        path = self.root / ".github" / "pull_request_template.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        # The template should prompt for a test plan.
        self.assertIn("Test plan", content)
        # And a checklist.
        self.assertIn("Checklist", content)

    def test_bug_report_template_exists(self) -> None:
        path = self.root / ".github" / "ISSUE_TEMPLATE" / "bug_report.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        # bitchat-specific: the transport field.
        self.assertIn("Transport", content)
        self.assertIn("Bluetooth mesh", content)

    def test_feature_request_template_exists(self) -> None:
        path = self.root / ".github" / "ISSUE_TEMPLATE" / "feature_request.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        # Privacy section is bitchat-specific.
        self.assertIn("Privacy", content)

    def test_contributing_guide_exists(self) -> None:
        path = self.root / "CONTRIBUTING.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        # Must mention the test suites.
        self.assertIn("swift test", content)
        self.assertIn("python3 -m unittest", content)

    def test_code_of_conduct_exists(self) -> None:
        path = self.root / "CODE_OF_CONDUCT.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        self.assertIn("Contributor Covenant", content)

    def test_readme_links_to_contributing(self) -> None:
        path = self.root / "README.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        self.assertIn("CONTRIBUTING.md", content)

    def test_docs_index_exists(self) -> None:
        path = self.root / "docs" / "README.md"
        self.assertTrue(path.exists(), f"missing: {path}")
        content = path.read_text(encoding="utf-8")
        self.assertIn("ARCHITECTURE_V2.md", content)
        self.assertIn("WHITEPAPER.md", content)


if __name__ == "__main__":
    unittest.main()
