import re
from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github/workflows/fetch_georelays.yml"


class FetchGeoRelaysWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_write_capable_checkout_action_is_immutable(self) -> None:
        checkout = re.search(r"uses: actions/checkout@([0-9a-f]+)", self.workflow)
        self.assertIsNotNone(checkout)
        self.assertRegex(checkout.group(1), r"^[0-9a-f]{40}$")
        self.assertIn("persist-credentials: false", self.workflow)

    def test_pr_failure_has_single_issue_fallback_with_review_metadata(self) -> None:
        required_fragments = [
            "issues: write",
            "TRACKING_ISSUE_TITLE: GeoRelay update awaiting pull request",
            "gh pr create",
            "gh issue create",
            "gh issue edit",
            "compare/main...${UPDATE_BRANCH}?expand=1",
            "Upstream commit: $SOURCE_COMMIT",
            "Data rows: $DATA_ROWS",
            "Unique normalized relays: $UNIQUE_RELAYS",
            "SHA-256: $DATA_SHA256",
            '[[ -n "$issue_url" ]]',
        ]
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.workflow)

        confirmed = self.workflow.index('[[ -n "$issue_url" ]]')
        success_summary = self.workflow.index(
            "Published GeoRelay tracking issue fallback: $issue_url"
        )
        self.assertLess(confirmed, success_summary)

    def test_obsolete_review_state_is_cleaned_without_pushing_main(self) -> None:
        self.assertIn("gh pr close", self.workflow)
        self.assertIn("gh issue close", self.workflow)
        self.assertIn('git push origin --delete "$UPDATE_BRANCH"', self.workflow)
        self.assertIn('git switch -C "$UPDATE_BRANCH"', self.workflow)
        self.assertNotIn("git push origin main", self.workflow)
        self.assertNotIn("git push --force origin main", self.workflow)

    def test_workflow_runs_all_validator_tests(self) -> None:
        self.assertIn(
            'python3 -m unittest discover -s scripts/tests -p "test_*.py" -v',
            self.workflow,
        )


if __name__ == "__main__":
    unittest.main()
