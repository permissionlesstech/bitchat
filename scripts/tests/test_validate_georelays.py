import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import validate_georelays as validator


def csv_bytes(rows: list[str]) -> bytes:
    return ("Relay URL,Latitude,Longitude\n" + "\n".join(rows) + "\n").encode()


class ValidateGeoRelaysTests(unittest.TestCase):
    def test_validates_and_deduplicates_secure_relay_addresses(self) -> None:
        data = csv_bytes(
            [
                "relay.example.com,10,20",
                "wss://relay.example.com:443/,10,20",
                "https://second.example.org,11,21",
            ]
        )

        summary = validator.validate_bytes(data, minimum_unique_relays=2)

        self.assertEqual(summary.data_rows, 3)
        self.assertEqual(summary.unique_relays, 2)

    def test_rejects_insecure_or_non_host_relay_urls(self) -> None:
        bad_addresses = [
            "http://relay.example.com",
            "ws://relay.example.com",
            "wss://user@relay.example.com",
            "wss://relay.example.com/path",
            "wss://relay.example.com?",
            "wss://relay.example.com#",
            "relay.example.com:0",
            "relay.example.com:99999",
            "localhost",
            "127.0.0.1",
            "relay_example.com",
            "relay\u202e.example.com",
        ]

        for address in bad_addresses:
            with self.subTest(address=address):
                with self.assertRaises(validator.ValidationError):
                    validator.validate_bytes(
                        csv_bytes([f"{address},10,20"]),
                        minimum_unique_relays=1,
                    )

    def test_rejects_malformed_rows_and_unsafe_coordinates(self) -> None:
        bad_rows = [
            "relay.example.com,10",
            "relay.example.com,NaN,20",
            "relay.example.com,1_0,20",
            "relay.example.com,\u0661\u0660,20",
            "relay.example.com,\uff11\uff10,20",
            "relay.example.com,91,20",
            "relay.example.com,10,-181",
            "relay.example.com,10,20,extra",
            '"relay.example.com",10,20',
        ]

        for row in bad_rows:
            with self.subTest(row=row):
                with self.assertRaises(validator.ValidationError):
                    validator.validate_bytes(csv_bytes([row]), minimum_unique_relays=1)

    def test_accepts_ascii_coordinate_forms_supported_by_swift_double(self) -> None:
        summary = validator.validate_bytes(
            csv_bytes(
                [
                    "one.example.com,+1,-.5",
                    "two.example.com,1.e1,2E+1",
                    "three.example.com,01,20.",
                ]
            ),
            minimum_unique_relays=3,
        )

        self.assertEqual(summary.unique_relays, 3)

    def test_rejects_conflicts_limits_and_large_baseline_deltas(self) -> None:
        with self.assertRaises(validator.ValidationError):
            validator.validate_bytes(
                csv_bytes(["relay.example.com,10,20", "relay.example.com,11,21"]),
                minimum_unique_relays=1,
            )
        with self.assertRaises(validator.ValidationError):
            validator.validate_bytes(b"x" * 20, maximum_bytes=10, minimum_unique_relays=1)
        with self.assertRaises(validator.ValidationError):
            validator.validate_bytes(
                csv_bytes(["one.example.com,1,1", "two.example.com,2,2"]),
                minimum_unique_relays=3,
            )

        baseline = csv_bytes(
            [f"relay-{index}.example.com,{index % 80},{index % 170}" for index in range(120)]
        )
        shrunken = csv_bytes(
            [f"relay-{index}.example.com,{index % 80},{index % 170}" for index in range(59)]
        )
        with self.assertRaises(validator.ValidationError):
            validator.validate_update(shrunken, baseline)

        smaller_baseline = csv_bytes(
            [f"relay-{index}.example.com,{index % 80},{index % 170}" for index in range(60)]
        )
        expanded = csv_bytes(
            [f"relay-{index}.example.com,{index % 80},{index % 170}" for index in range(121)]
        )
        with self.assertRaises(validator.ValidationError):
            validator.validate_update(expanded, smaller_baseline)

    def test_update_requires_exact_normalized_baseline_entry_overlap(self) -> None:
        baseline_rows = [
            f"relay-{index}.example.com,{index % 80},{index % 170}"
            for index in range(60)
        ]
        baseline = csv_bytes(baseline_rows)
        disjoint = csv_bytes(
            [
                f"attacker-{index}.example.com,{index % 80},{index % 170}"
                for index in range(60)
            ]
        )
        rewritten_coordinates = csv_bytes(
            [
                f"relay-{index}.example.com,{(index % 80) + 0.5},{index % 170}"
                for index in range(60)
            ]
        )

        for candidate in (disjoint, rewritten_coordinates):
            with self.subTest(candidate=candidate[:80]):
                with self.assertRaisesRegex(
                    validator.ValidationError,
                    "exact relay-coordinate entries",
                ):
                    validator.validate_update(candidate, baseline)

        half_retained = csv_bytes(
            [
                f"wss://relay-{index}.example.com:443/,{index % 80},{index % 170}"
                for index in range(30)
            ]
            + [
                f"replacement-{index}.example.com,{index % 80},{index % 170}"
                for index in range(30)
            ]
        )
        summary = validator.validate_update(half_retained, baseline)
        self.assertEqual(summary.unique_relays, 60)

    def test_cli_copies_only_validated_data_and_emits_review_metadata(self) -> None:
        rows = [f"relay-{index}.example.com,{index % 80},{index % 170}" for index in range(60)]
        data = csv_bytes(rows)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / "candidate.csv"
            baseline = root / "baseline.csv"
            output = root / "output.csv"
            github_output = root / "github-output.txt"
            candidate.write_bytes(data)
            baseline.write_bytes(data)

            result = validator.main(
                [
                    "--input", str(candidate),
                    "--baseline", str(baseline),
                    "--output", str(output),
                    "--github-output", str(github_output),
                ]
            )

            self.assertEqual(result, 0)
            self.assertEqual(output.read_bytes(), data)
            metadata = github_output.read_text()
            self.assertIn("unique_relays=60", metadata)
            self.assertIn("sha256=", metadata)


if __name__ == "__main__":
    unittest.main()
