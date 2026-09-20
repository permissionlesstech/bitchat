import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay_stats  # type: ignore[import-not-found]
import validate_georelays as validator  # type: ignore[import-not-found]


def csv_bytes(rows: list[str]) -> bytes:
    return ("Relay URL,Latitude,Longitude\n" + "\n".join(rows) + "\n").encode()


class RelayStatsTests(unittest.TestCase):
    def test_collect_stats_counts_rows_unique_and_duplicates(self) -> None:
        data = csv_bytes(
            [
                "alpha.example.com,1,2",
                "beta.example.com,3,4",
                "wss://alpha.example.com:443/,1,2",  # exact duplicate (normalized)
                "gamma.example.com,5,6",
            ]
        )

        stats = relay_stats.collect_stats(data)

        self.assertEqual(stats["data_rows"], 4)
        self.assertEqual(stats["unique_relays"], 3)
        self.assertEqual(stats["duplicate_rows"], 1)
        self.assertEqual(stats["sample_duplicates"], [("alpha.example.com", 2)])

    def test_collect_stats_sha256_matches_validator(self) -> None:
        data = csv_bytes(["alpha.example.com,1,2", "beta.example.com,3,4"])
        stats = relay_stats.collect_stats(data)
        expected = validator.validate_bytes(data, minimum_unique_relays=1).sha256
        self.assertEqual(stats["sha256"], expected)

    def test_collect_stats_with_no_duplicates(self) -> None:
        data = csv_bytes(["alpha.example.com,1,2", "beta.example.com,3,4"])
        stats = relay_stats.collect_stats(data)
        self.assertEqual(stats["duplicate_rows"], 0)
        self.assertEqual(stats["sample_duplicates"], [])

    def test_collect_stats_raises_on_invalid_csv(self) -> None:
        with self.assertRaises(validator.ValidationError):
            relay_stats.collect_stats(b"")

    def test_main_prints_stats_and_returns_zero(self) -> None:
        data = csv_bytes(["alpha.example.com,1,2", "beta.example.com,3,4"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "relays.csv"
            path.write_bytes(data)
            result = relay_stats.main(["--input", str(path)])
        self.assertEqual(result, 0)

    def test_main_returns_one_on_missing_file(self) -> None:
        result = relay_stats.main(["--input", "/nonexistent/path.csv"])
        self.assertEqual(result, 1)

    def test_main_defaults_to_shipped_csv_when_present(self) -> None:
        shipped = Path(__file__).resolve().parents[2] / "relays" / "online_relays_gps.csv"
        if not shipped.exists():
            self.skipTest("shipped georelay CSV not present in this checkout")
        result = relay_stats.main([])
        self.assertEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
