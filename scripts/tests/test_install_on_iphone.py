from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install-on-iphone.sh"
EXAMPLE_CONFIG = Path(__file__).resolve().parents[2] / "Configs" / "Local.xcconfig.example"


def run_function(snippet: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    """Source the installer (which must not run main when sourced) and run a snippet."""
    return subprocess.run(
        ["bash", "-c", f'source "{SCRIPT}" && {snippet}'],
        capture_output=True,
        text=True,
        cwd=cwd,
        check=False,
    )


def device(
    identifier: str,
    *,
    platform: str = "iOS",
    reality: str = "physical",
    udid: str | None = "00008140-000000000000001C",
    name: str = "Test iPhone",
    pairing: str = "paired",
    developer_mode: str | None = "enabled",
    transport: str | None = "wired",
) -> dict:
    hardware = {"platform": platform, "reality": reality, "marketingName": "iPhone 16e"}
    if udid is not None:
        hardware["udid"] = udid
    connection = {"pairingState": pairing}
    if transport is not None:
        connection["transportType"] = transport
    properties = {"name": name}
    if developer_mode is not None:
        properties["developerModeStatus"] = developer_mode
    return {
        "identifier": identifier,
        "hardwareProperties": hardware,
        "connectionProperties": connection,
        "deviceProperties": properties,
    }


class InstallOnIPhoneScriptTests(unittest.TestCase):
    def test_script_has_valid_bash_syntax(self) -> None:
        result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_exits_successfully_without_side_effects(self) -> None:
        result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage", result.stdout)

    def test_unknown_option_is_rejected(self) -> None:
        result = subprocess.run(["bash", str(SCRIPT), "--bogus"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_sourcing_does_not_run_installer(self) -> None:
        result = run_function("echo sourced-ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "sourced-ok")


class TeamIdParsingTests(unittest.TestCase):
    def test_parses_libressl_style_subject(self) -> None:
        subject = (
            "subject=UID=HC4W53P7Q3, CN=Apple Development: a@b.com (56SYW959G8), "
            "OU=6GZP5XRVZH, O=Jane Doe, C=US"
        )
        result = run_function(f"team_id_from_subject '{subject}'")
        self.assertEqual(result.stdout.strip(), "6GZP5XRVZH")

    def test_parses_slash_style_subject(self) -> None:
        subject = "subject= /UID=ABC/CN=Apple Development: x (Y)/OU=AB12CD34EF/O=Jane/C=US"
        result = run_function(f"team_id_from_subject '{subject}'")
        self.assertEqual(result.stdout.strip(), "AB12CD34EF")

    def test_rejects_subject_without_team(self) -> None:
        result = run_function("team_id_from_subject 'subject=CN=Something, O=Org'")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_validates_team_id_format(self) -> None:
        self.assertEqual(run_function("is_valid_team_id 6GZP5XRVZH").returncode, 0)
        self.assertNotEqual(run_function("is_valid_team_id abc").returncode, 0)
        self.assertNotEqual(run_function("is_valid_team_id '6GZP5XRVZH; rm -rf /'").returncode, 0)


class MenuChoiceTests(unittest.TestCase):
    def test_accepts_numbers_in_range_including_leading_zeros(self) -> None:
        for choice in ["1", "3", "08"]:
            with self.subTest(choice=choice):
                self.assertEqual(run_function(f"is_menu_choice {choice} 9").returncode, 0)

    def test_rejects_out_of_range_or_non_numeric(self) -> None:
        for choice in ["0", "10", "", "abc", "1;ls", "99999"]:
            with self.subTest(choice=choice):
                result = run_function(f"is_menu_choice '{choice}' 9")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "")


@unittest.skipUnless(shutil.which("plutil"), "plutil is only available on macOS")
class DeviceListingTests(unittest.TestCase):
    def list_iphones(self, devices: list[dict]) -> list[list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "devices.json"
            path.write_text(json.dumps({"result": {"devices": devices}}))
            result = run_function(f'list_iphones "{path}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.split("\t") for line in result.stdout.splitlines() if line]

    def test_lists_only_connected_physical_ios_devices(self) -> None:
        rows = self.list_iphones(
            [
                device("PHONE-1", name="Jane's iPhone"),
                device("MAC-1", platform="macOS"),
                device("SIM-1", reality="simulated"),
                device("OLD-PHONE", transport=None),
            ]
        )
        self.assertEqual(len(rows), 1)
        identifier, udid, name, model, pairing, developer_mode, transport = rows[0]
        self.assertEqual(identifier, "PHONE-1")
        self.assertEqual(udid, "00008140-000000000000001C")
        self.assertEqual(name, "Jane's iPhone")
        self.assertEqual(model, "iPhone 16e")
        self.assertEqual(pairing, "paired")
        self.assertEqual(developer_mode, "enabled")
        self.assertEqual(transport, "wired")

    def test_unpaired_device_with_missing_fields_still_listed(self) -> None:
        rows = self.list_iphones(
            [device("NEW-PHONE", udid=None, pairing="unpaired", developer_mode=None)]
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][0], "NEW-PHONE")
        self.assertEqual(rows[0][1], "")
        self.assertEqual(rows[0][4], "unpaired")
        self.assertEqual(rows[0][5], "unknown")

    def test_empty_device_list(self) -> None:
        self.assertEqual(self.list_iphones([]), [])


class LocalConfigTests(unittest.TestCase):
    def make_repo(self, tmp: str) -> Path:
        repo = Path(tmp)
        (repo / "Configs").mkdir()
        (repo / "Configs" / "Local.xcconfig.example").write_text(EXAMPLE_CONFIG.read_text())
        return repo

    def test_creates_config_with_team(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.make_repo(tmp)
            result = run_function(f'write_local_config "{repo}" AB12CD34EF')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "created")
            config = (repo / "Configs" / "Local.xcconfig").read_text()
            self.assertIn("DEVELOPMENT_TEAM = AB12CD34EF", config)
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = chat.bitchat.$(DEVELOPMENT_TEAM)", config)
            self.assertNotIn("ABC123", config)

    def test_leaves_matching_config_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.make_repo(tmp)
            run_function(f'write_local_config "{repo}" AB12CD34EF')
            config_path = repo / "Configs" / "Local.xcconfig"
            config_path.write_text(config_path.read_text() + "// my custom line\n")
            result = run_function(f'write_local_config "{repo}" AB12CD34EF')
            self.assertEqual(result.stdout.strip(), "unchanged")
            self.assertIn("// my custom line", config_path.read_text())

    def test_backs_up_config_for_a_different_team(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.make_repo(tmp)
            run_function(f'write_local_config "{repo}" AB12CD34EF')
            result = run_function(f'write_local_config "{repo}" ZZ99YY88XX')
            self.assertEqual(result.stdout.strip(), "updated")
            config = (repo / "Configs" / "Local.xcconfig").read_text()
            self.assertIn("DEVELOPMENT_TEAM = ZZ99YY88XX", config)
            backups = list((repo / "Configs").glob("Local.xcconfig.backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertIn("DEVELOPMENT_TEAM = AB12CD34EF", backups[0].read_text())


class BuildDiagnosisTests(unittest.TestCase):
    def diagnose(self, log: str) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "build.log"
            path.write_text(log)
            return run_function(f'diagnose_build_log "{path}"').stdout

    def test_missing_account_hint(self) -> None:
        output = self.diagnose('error: No Accounts: Add a new account in Accounts settings.')
        self.assertIn("Accounts", output)

    def test_app_id_limit_hint(self) -> None:
        output = self.diagnose(
            "error: Communication with Apple failed: Your maximum App ID limit has been reached."
        )
        self.assertIn("7 days", output)

    def test_unknown_error_has_no_specific_hint(self) -> None:
        self.assertEqual(self.diagnose("error: something odd").strip(), "")


if __name__ == "__main__":
    unittest.main()
