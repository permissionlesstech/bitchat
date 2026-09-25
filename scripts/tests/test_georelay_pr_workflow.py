import re
from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github/workflows/validate_georelays.yml"
RELAY_DATA_PATH = "relays/online_relays_gps.csv"
VALIDATOR_PATH = "scripts/validate_georelays.py"


class ValidateGeoRelaysWorkflowTests(unittest.TestCase):
    """The relay directory is reviewed data. A pull request that changes it must
    be judged by the base branch's validator, on the bytes that would actually
    merge, and the job that does so must not run anything the pull request
    wrote -- the `gate` job is the trust boundary, `proposed-validator` is not.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        # Comments explain why a construct is absent and would otherwise trip
        # the assertions looking for it, so directives are checked without them.
        cls.directives = "\n".join(
            line for line in cls.workflow.splitlines() if not line.lstrip().startswith("#")
        )

    def job(self, name: str) -> str:
        block = re.search(rf"^  {name}:\n(.*?)(?=^  \S|\Z)", self.directives, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(block, f"no {name} job in the workflow")
        return block.group(1)

    def test_runs_on_untrusted_pull_request_trigger(self) -> None:
        self.assertIn("pull_request:", self.directives)
        # pull_request_target would run PR-authored code with repository secrets.
        self.assertNotIn("pull_request_target", self.directives)

    def test_no_job_holds_a_write_scope(self) -> None:
        self.assertIn("permissions:\n  contents: read", self.directives)
        write_scope = re.search(r"^\s*[\w-]+:\s*write\s*$", self.directives, re.MULTILINE)
        self.assertIsNone(write_scope, "a job running PR-authored code must not hold a write scope")

    def test_checkout_does_not_persist_credentials(self) -> None:
        self.assertEqual(2, self.directives.count("persist-credentials: false"))

    def test_relay_data_changes_trigger_the_workflow(self) -> None:
        paths_block = re.search(r"paths:\n((?:\s+- .+\n)+)", self.directives)
        self.assertIsNotNone(paths_block)
        self.assertIn(RELAY_DATA_PATH, paths_block.group(1))
        self.assertIn(VALIDATOR_PATH, paths_block.group(1))

    def test_gate_checks_out_the_reviewed_base(self) -> None:
        # Checking out the merge ref would put the pull request's validator and
        # tests in the gate's workspace.
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", self.job("gate"))

    def test_gate_runs_nothing_the_pull_request_wrote(self) -> None:
        gate = self.job("gate")
        self.assertNotIn("unittest discover", gate)
        # The candidate is read as a git object, never from the worktree, so
        # code running earlier in the job cannot substitute the bytes validated.
        self.assertIn('git show "${HEAD_SHA}:' + RELAY_DATA_PATH + '"', gate)
        self.assertIn('--input "$RUNNER_TEMP/candidate.csv"', gate)
        self.assertNotIn(f"--input {RELAY_DATA_PATH}", gate)

    def test_gate_pins_both_inputs_to_the_event(self) -> None:
        gate = self.job("gate")
        self.assertIn("HEAD_SHA: ${{ github.event.pull_request.head.sha }}", gate)
        # A head that moved after the event means these bytes are not the ones
        # this run was asked about.
        self.assertIn('if [[ "$fetched_sha" != "$HEAD_SHA" ]]; then', gate)
        self.assertIn("exit 1", gate)

    def test_gate_validation_cannot_write_to_the_reviewed_file(self) -> None:
        gate = self.job("gate")
        self.assertIn('--output "$RUNNER_TEMP/', gate)
        self.assertNotIn(f"--output {RELAY_DATA_PATH}", gate)

    def test_proposed_validator_is_exercised_against_the_real_directory(self) -> None:
        # Unit-test fixtures are small and synthetic; a new constraint can pass
        # them while invalidating the committed directory.
        job = self.job("proposed-validator")
        self.assertIn("unittest discover", job)
        self.assertIn(f"--input {RELAY_DATA_PATH}", job)
        self.assertIn('git show "${BASE_SHA}:' + RELAY_DATA_PATH + '"', job)


if __name__ == "__main__":
    unittest.main()
