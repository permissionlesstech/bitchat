#!/usr/bin/env python3
"""Package an exported, notarized Developer ID app for direct macOS distribution."""

import argparse
import hashlib
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


def run(*command):
    result = subprocess.run(list(map(str, command)), capture_output=True)
    if result.returncode:
        # Do not expose signing identities, local paths, or notary credentials.
        raise ValueError(f"{command[0]} verification/packaging step failed")
    return result.stdout + result.stderr


def check_team(bundle, team):
    details = run("codesign", "--display", "--verbose=4", bundle).decode()
    if f"TeamIdentifier={team}" not in details.splitlines():
        raise ValueError("signing team does not match the expected release team")


def package(app, destination, version, team, identity, notary_profile):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?", version):
        raise ValueError("version must look like X.Y.Z")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("a complete ten-character release team ID is required")
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
        raise ValueError("a complete signing-certificate SHA-1 is required")
    if not notary_profile:
        raise ValueError("a stored notarytool keychain profile is required")
    if app.is_symlink() or app.suffix != ".app" or not app.is_dir():
        raise ValueError("an exported app bundle is required")
    if destination.exists() or destination.is_symlink():
        raise ValueError("output already exists; refusing to overwrite it")
    with (app / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleShortVersionString") != version:
        raise ValueError("requested version differs from the app's version")
    if info.get("CFBundleIdentifier") != "chat.bitchat":
        raise ValueError("unexpected app bundle identifier")
    if "MacOSX" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("the app is not a macOS build")

    run("codesign", "--verify", "--deep", "--strict", app)
    check_team(app, team)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", app)

    # Only expose a complete, notarized artifact directory. A failed signing,
    # notary, or checksum step leaves no publishable output at the destination.
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bitchat-macos-", dir=destination.parent) as work:
        working = Path(work)
        image_source = working / "image"
        image_source.mkdir()
        packaged_app = image_source / "bitchat.app"
        run("ditto", app, packaged_app)
        (image_source / "Applications").symlink_to("/Applications")
        output = working / "release"
        output.mkdir()
        image = output / f"bitchat-macos-{version}.dmg"
        run("hdiutil", "create", "-volname", "bitchat", "-srcfolder", image_source,
            "-format", "UDZO", image)
        run("codesign", "--sign", identity, "--timestamp", image)
        run("codesign", "--verify", "--strict", image)
        check_team(image, team)
        run("xcrun", "notarytool", "submit", image, "--keychain-profile", notary_profile,
            "--wait")
        # Rejected notarization cannot reach publication, even if submit exits 0:
        # a ticket must be available, stapled, and independently validated.
        run("xcrun", "stapler", "staple", image)
        run("xcrun", "stapler", "validate", image)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", image)
        hasher = hashlib.sha256()
        with image.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(block)
        (output / "MACOS_SHA256SUMS").write_text(f"{hasher.hexdigest()}  {image.name}\n")
        output.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("version")
    parser.add_argument("team_id")
    parser.add_argument("certificate_sha1")
    parser.add_argument("notary_profile")
    args = parser.parse_args()
    try:
        package(args.app.absolute(), args.output_directory.absolute(), args.version,
                args.team_id, args.certificate_sha1, args.notary_profile)
    except (OSError, ValueError, plistlib.InvalidFileException):
        parser.exit(1, "error: macOS release validation or packaging failed; no release was published\n")
    print("Signed, notarized DMG and SHA-256 manifest prepared for release review.")


if __name__ == "__main__":
    main()
