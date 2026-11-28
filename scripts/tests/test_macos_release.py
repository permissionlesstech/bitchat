"""Synthetic packaging contract tests, without Apple services or signing keys."""

import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("macos_release", Path(__file__).parents[1] / "package-macos-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class MacOSReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "exported app.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {
            "CFBundleIdentifier": "chat.bitchat",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleSupportedPlatforms": ["MacOSX"],
        }
        self.write_info()
        self.output = self.root / "release assets"
        self.commands = []

    def write_info(self):
        with (self.app / "Contents" / "Info.plist").open("wb") as target:
            plistlib.dump(self.info, target)

    def command(self, *args):
        self.commands.append(args)
        if args[:2] == ("codesign", "--display"):
            return b"TeamIdentifier=ABC1234567\n"
        if args[:2] == ("hdiutil", "create"):
            Path(args[-1]).write_bytes(b"synthetic disk image")
        return b""

    def package(self, **changes):
        arguments = dict(app=self.app, destination=self.output, version="1.2.3",
                         team="ABC1234567", identity="A" * 40, notary_profile="synthetic-notary")
        arguments.update(changes)
        release.package(**arguments)

    def test_success_checks_final_stapled_bytes(self):
        with patch.object(release, "run", side_effect=self.command):
            self.package()
        image = self.output / "bitchat-macos-1.2.3.dmg"
        expected = hashlib.sha256(image.read_bytes()).hexdigest()
        self.assertEqual(f"{expected}  {image.name}\n", (self.output / "MACOS_SHA256SUMS").read_text())
        self.assertIn(("xcrun", "stapler", "validate", self.app), self.commands)
        self.assertTrue(any(command[:3] == ("xcrun", "notarytool", "submit") for command in self.commands))

    def test_each_security_and_packaging_failure_leaves_no_output(self):
        with patch.object(release, "run", side_effect=self.command):
            self.package()
        steps = len(self.commands)
        for failure in range(steps):
            destination = self.root / f"failed-{failure}"
            calls = 0

            def command(*args):
                nonlocal calls
                current = calls
                calls += 1
                if current == failure:
                    raise ValueError("synthetic step failure")
                return self.command(*args)

            with self.subTest(step=failure), patch.object(release, "run", side_effect=command):
                with self.assertRaises(ValueError):
                    self.package(destination=destination)
                self.assertFalse(destination.exists())

    def test_wrong_signing_team_is_rejected(self):
        with patch.object(release, "run", return_value=b"TeamIdentifier=OTHER12345\n"):
            with self.assertRaisesRegex(ValueError, "signing team"):
                self.package()
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        marker = self.output / "keep.txt"
        marker.write_text("synthetic existing output")
        with patch.object(release, "run") as runner:
            with self.assertRaisesRegex(ValueError, "output already exists"):
                self.package()
            runner.assert_not_called()
        self.assertEqual("synthetic existing output", marker.read_text())

    def test_mislabeled_app_is_rejected_before_packaging(self):
        for field, value in (("CFBundleShortVersionString", "9.9.9"),
                             ("CFBundleIdentifier", "test.invalid"),
                             ("CFBundleSupportedPlatforms", ["iPhoneOS"])):
            original = self.info[field]
            self.info[field] = value
            self.write_info()
            with self.subTest(field=field), patch.object(release, "run") as runner:
                with self.assertRaises(ValueError):
                    self.package()
                runner.assert_not_called()
            self.info[field] = original

    def test_invalid_parameters_are_rejected(self):
        for changes in ({"version": "../../image"}, {"team": "short"},
                        {"identity": "ad-hoc"}, {"notary_profile": ""}):
            with self.subTest(changes=changes), patch.object(release, "run") as runner:
                with self.assertRaises(ValueError):
                    self.package(**changes)
                runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
