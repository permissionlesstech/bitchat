import re
from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github/workflows/validate_georelays.yml"
RELAY_DATA_PATH = "relays/online_relays_gps.csv"
VALIDATOR_PATH = "scripts/validate_georelays.py"


class ValidateGeoRelaysWorkflowTests(unittest.TestCase):
    """The relay directory is reviewed data: a PR that changes it must be
    checked by the same validator the weekly automation runs, and must publish
    the hash a reviewer needs to match a proposed snapshot against the
    automation's own published one."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        # Comments explain why a construct is absent and would otherwise trip
        # the assertions looking for it, so directives are checked without them.
        cls.directives = "\n".join(
            line for line in cls.workflow.splitlines() if not line.lstrip().startswith("#")
        )

    def test_runs_on_untrusted_pull_request_trigger(self) -> None:
        self.assertIn("pull_request:", self.directives)
        # pull_request_target would run PR-authored code with repository secrets.
        self.assertNotIn("pull_request_target", self.directives)

    def test_job_holds_no_write_scope(self) -> None:
        self.assertIn("permissions:\n  contents: read", self.directives)
        write_scope = re.search(r"^\s*[\w-]+:\s*write\s*$", self.directives, re.MULTILINE)
        self.assertIsNone(write_scope, "a job running PR-authored code must not hold a write scope")

    def test_checkout_does_not_persist_credentials(self) -> None:
        self.assertIn("uses: actions/checkout@", self.directives)
        self.assertIn("persist-credentials: false", self.directives)

    def test_relay_data_changes_trigger_the_job(self) -> None:
        paths_block = re.search(r"paths:\n((?:\s+- .+\n)+)", self.directives)
        self.assertIsNotNone(paths_block)
        self.assertIn(RELAY_DATA_PATH, paths_block.group(1))
        self.assertIn(VALIDATOR_PATH, paths_block.group(1))

    def test_validates_against_the_base_branch_copy(self) -> None:
        required_fragments = [
            "python3 -m unittest discover -s scripts/tests -p \"test_*.py\" -v",
            f"--input {RELAY_DATA_PATH}",
            "python3 \"$RUNNER_TEMP/reviewed-validator.py\"",
            "--baseline \"$RUNNER_TEMP/baseline.csv\"",
            f"git show \"origin/${{GITHUB_BASE_REF}}:{RELAY_DATA_PATH}\"",
            "--github-output",
            "$GITHUB_STEP_SUMMARY",
        ]
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.directives)

    def test_gate_runs_the_reviewed_validator_not_the_pull_request_copy(self) -> None:
        # A change that edits the relay data and the validator together would
        # otherwise certify itself: dropping most of the directory passes if the
        # same commit relaxes a threshold. The gate must read the base branch's
        # validator; the PR's copy is exercised by the unit-test step instead.
        self.assertIn(
            f'git show "origin/${{GITHUB_BASE_REF}}:{VALIDATOR_PATH}"',
            self.directives,
        )
        self.assertIsNone(
            re.search(rf"python3\s+\S*{re.escape(VALIDATOR_PATH)}", self.directives),
            "the gate must not run the pull request's own validator, however the path is spelled",
        )

    def test_base_ref_is_fetched_before_it_is_read(self) -> None:
        # actions/checkout gives a pull_request run the merge ref, so the base
        # branch is not present unless the job fetches it first.
        fetched = self.directives.index('git fetch --no-tags --depth=1 origin "+refs/heads/${GITHUB_BASE_REF}')
        read = self.directives.index('git show "origin/${GITHUB_BASE_REF}')
        self.assertLess(fetched, read)

    def test_validation_cannot_write_to_the_reviewed_file(self) -> None:
        # --output is required and receives a verbatim copy of --input. Pointed
        # at the tracked file, a validation run would write to reviewed data.
        self.assertIn("--output \"$RUNNER_TEMP/", self.directives)
        self.assertNotIn(f"--output {RELAY_DATA_PATH}", self.directives)


if __name__ == "__main__":
    unittest.main()
