import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_csv_health  # type: ignore[import-not-found]
import validate_georelays as validator  # type: ignore[import-not-found]


def csv_bytes(rows: list[str]) -> bytes:
    return ("Relay URL,Latitude,Longitude\n" + "\n".join(rows) + "\n").encode()


class CheckCsvHealthTests(unittest.TestCase):
    def test_main_returns_zero_on_valid_csv(self) -> None:
        # The validator enforces a default minimum of 50 unique relays, so a
        # passing fixture needs at least that many rows.
        rows = [f"r-{i:02d}.example.com,{i % 80},{i % 170}" for i in range(60)]
        data = csv_bytes(rows)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "relays.csv"
            path.write_bytes(data)
            result = check_csv_health.main(["--input", str(path)])
        self.assertEqual(result, 0)

    def test_main_returns_one_on_invalid_csv(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "relays.csv"
            path.write_bytes(b"not a csv")
            result = check_csv_health.main(["--input", str(path)])
        self.assertEqual(result, 1)

    def test_main_returns_one_on_missing_file(self) -> None:
        result = check_csv_health.main(["--input", "/nonexistent/relays.csv"])
        self.assertEqual(result, 1)

    def test_main_defaults_to_shipped_csv_when_present(self) -> None:
        shipped = Path(__file__).resolve().parents[2] / "relays" / "online_relays_gps.csv"
        if not shipped.exists():
            self.skipTest("shipped georelay CSV not present in this checkout")
        self.assertEqual(check_csv_health.main([]), 0)


if __name__ == "__main__":
    unittest.main()
