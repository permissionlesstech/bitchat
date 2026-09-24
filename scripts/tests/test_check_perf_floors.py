import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
GATE = REPOSITORY_ROOT / "scripts/check-perf-floors.sh"


class CheckPerfFloorsTests(unittest.TestCase):
    """The floor gate is what stands between an order-of-magnitude regression
    and main, and it decides by parsing captured test output. These run the
    real script against fixture logs and pin its exit-code contract: which
    outcomes skip, which are re-measured, and which fail without a retry.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="perf-floors-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.invocations = self.tmp / "remeasure-invocations"

    def floors(self, **floors: int) -> Path:
        path = self.tmp / "floors.json"
        entries = ",\n".join(f'    "{name}": {floor}' for name, floor in floors.items())
        path.write_text('{\n  "floors": {\n' + entries + "\n  }\n}\n", encoding="utf-8")
        return path

    def log(self, *lines: str) -> Path:
        path = self.tmp / "perf-output.log"
        path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
        return path

    def remeasure(self, append: str | None = None) -> Path:
        """A stand-in for `swift test`: records each invocation and appends one
        line to the log the gate points it at, the way a real re-run would."""
        script = self.tmp / "remeasure.sh"
        body = ["#!/bin/sh", f'echo run >> "{self.invocations}"']
        if append is not None:
            body.append(f"printf '%s\\n' '{append}' >> \"$BITCHAT_PERF_LOG\"")
        script.write_text("\n".join(body) + "\n", encoding="utf-8")
        script.chmod(0o755)
        return script

    def run_gate(
        self,
        log: Path,
        floors: Path,
        *,
        remeasure: Path | None = None,
        attempts: int | None = None,
        skip: bool = False,
    ) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith("BITCHAT_")}
        # Never fall through to the default `swift test` re-measure: a test
        # that unexpectedly retries must fail fast, not build the app.
        env["BITCHAT_PERF_REMEASURE_CMD"] = str(remeasure or self.remeasure())
        if attempts is not None:
            env["BITCHAT_PERF_GATE_ATTEMPTS"] = str(attempts)
        if skip:
            env["BITCHAT_SKIP_PERF_BASELINES"] = "1"
        return subprocess.run(
            [str(GATE), str(log), str(floors)],
            cwd=self.tmp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def remeasure_count(self) -> int:
        if not self.invocations.exists():
            return 0
        return len(self.invocations.read_text(encoding="utf-8").splitlines())

    def test_every_floor_met_passes(self) -> None:
        result = self.run_gate(
            self.log("PERF[a.one]: 1000 ops/sec (avg 1 ms)", "PERF[b.two]: 250.5 items/sec"),
            self.floors(**{"a.one": 100, "b.two": 200}),
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("all benchmarks at or above their floors", result.stdout)
        self.assertEqual(self.remeasure_count(), 0)

    def test_best_value_across_appended_attempts_is_what_counts(self) -> None:
        # Re-measurements append to the same log, so one line clearing the
        # floor is enough even when an earlier attempt sat under it.
        result = self.run_gate(
            self.log("PERF[a.one]: 50 ops/sec", "PERF[a.one]: 500 ops/sec"),
            self.floors(**{"a.one": 100}),
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remeasure_count(), 0)

    def test_below_floor_is_remeasured_and_passes_once_it_clears(self) -> None:
        result = self.run_gate(
            self.log("PERF[a.one]: 50 ops/sec"),
            self.floors(**{"a.one": 100}),
            remeasure=self.remeasure(append="PERF[a.one]: 500 ops/sec"),
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remeasure_count(), 1)
        self.assertIn("re-measuring (attempt 2", result.stdout)

    def test_below_floor_on_every_attempt_fails(self) -> None:
        result = self.run_gate(
            self.log("PERF[a.one]: 50 ops/sec"),
            self.floors(**{"a.one": 100}),
            remeasure=self.remeasure(append="PERF[a.one]: 60 ops/sec"),
            attempts=2,
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.remeasure_count(), 1)
        self.assertIn("BELOW    a.one: 60 ops/sec is under floor 100", result.stdout)
        self.assertIn("treating as a real regression", result.stderr)

    def test_missing_floored_benchmark_fails_without_a_retry(self) -> None:
        # A re-measurement that happened to produce the missing line would
        # paper over a silently dropped benchmark, so this must not retry.
        result = self.run_gate(
            self.log("PERF[a.one]: 1000 ops/sec"),
            self.floors(**{"a.one": 100, "b.two": 200}),
            remeasure=self.remeasure(append="PERF[b.two]: 900 ops/sec"),
        )

        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(self.remeasure_count(), 0)
        self.assertIn("MISSING  b.two: floored benchmark reported no PERF line", result.stdout)

    def test_unfloored_benchmark_fails_without_a_retry(self) -> None:
        # The mirror of the missing case: a benchmark that measures but has no
        # floor guards nothing, and no re-measurement can supply the floor.
        result = self.run_gate(
            self.log("PERF[a.one]: 1000 ops/sec", "PERF[c.new]: 1000 ops/sec"),
            self.floors(**{"a.one": 100}),
        )

        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("NO-FLOOR c.new: 1000 ops/sec reports a PERF line but has no floor", result.stdout)
        self.assertEqual(self.remeasure_count(), 0)

    def test_output_without_perf_lines_skips(self) -> None:
        # Package-only matrix entries produce no benchmarks; the gate must
        # not fail them for it.
        result = self.run_gate(
            self.log("Test Suite 'All tests' passed", "Executed 12 tests"),
            self.floors(**{"a.one": 100}),
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no PERF lines", result.stdout)

    def test_skip_flag_bypasses_the_gate_entirely(self) -> None:
        result = self.run_gate(
            self.log("PERF[a.one]: 1 ops/sec"),
            self.floors(**{"a.one": 100}),
            skip=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BITCHAT_SKIP_PERF_BASELINES=1", result.stdout)
        self.assertEqual(self.remeasure_count(), 0)


if __name__ == "__main__":
    unittest.main()
