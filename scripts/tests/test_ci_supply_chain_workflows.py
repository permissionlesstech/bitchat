import re
from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SOURCE_MANIFEST_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/source-manifest.yml"
ARTI_PROVENANCE_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/arti-provenance.yml"
SWIFT_TESTS_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/swift-tests.yml"
BUILD_IOS_SCRIPT = REPOSITORY_ROOT / "localPackages/Arti/build-ios.sh"
ROOT_PACKAGE_RESOLVED = REPOSITORY_ROOT / "Package.resolved"
XCODE_PACKAGE_RESOLVED = (
    REPOSITORY_ROOT
    / "bitchat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

SHA_PINNED_USES = re.compile(r"uses:\s*[\w.-]+/[\w.-]+(?:/[\w.-]+)*@[0-9a-f]{40}\b")
ANY_USES = re.compile(r"uses:\s*([^\s#]+)")


def strip_comments(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def extract_run_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        match = re.match(r"^(\s*)run:\s*(.*)$", line)
        if not match:
            i += 1
            continue
        indent = len(match.group(1))
        rest = match.group(2).strip()
        if rest in ("|", ">", "|-", ">-"):
            block_lines: list[str] = []
            i += 1
            while i < len(lines):
                current = lines[i]
                if current.strip() == "":
                    block_lines.append("")
                    i += 1
                    continue
                current_indent = len(current) - len(current.lstrip(" "))
                if current_indent <= indent:
                    break
                block_lines.append(current)
                i += 1
            blocks.append("\n".join(block_lines))
        else:
            blocks.append(rest)
            i += 1
    return blocks


class SourceManifestWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = SOURCE_MANIFEST_WORKFLOW.read_text(encoding="utf-8")
        cls.directives = strip_comments(cls.workflow)

    def test_no_expression_interpolation_in_run_blocks(self) -> None:
        for block in extract_run_blocks(self.directives):
            self.assertNotIn(
                "${{",
                block,
                "source-manifest.yml must pass untrusted inputs via env vars, never inline ${{ }} in run:",
            )

    def test_all_actions_are_pinned_by_commit_sha(self) -> None:
        uses_matches = ANY_USES.findall(self.directives)
        self.assertGreaterEqual(len(uses_matches), 3)
        for line in self.directives.splitlines():
            if "uses:" in line:
                self.assertRegex(line, SHA_PINNED_USES)

    def test_checkout_disables_persisted_credentials(self) -> None:
        self.assertIn("persist-credentials: false", self.directives)


class ArtiProvenanceWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = ARTI_PROVENANCE_WORKFLOW.read_text(encoding="utf-8")
        cls.directives = strip_comments(cls.workflow)

    def test_workflow_declares_read_only_permissions(self) -> None:
        self.assertIn("permissions:\n  contents: read", self.directives)

    def test_workflow_triggers_on_self_modification(self) -> None:
        self.assertEqual(
            2,
            self.directives.count(".github/workflows/arti-provenance.yml"),
            "Both push and pull_request path filters must include arti-provenance.yml",
        )

    def test_hashes_entire_xcframework_tree_without_maxdepth(self) -> None:
        self.assertNotIn("-maxdepth", self.directives)
        self.assertIn(
            "find localPackages/Arti/Frameworks/arti.xcframework -type f -print0",
            self.directives,
        )

    def test_binary_change_requires_build_input_not_doc_only(self) -> None:
        self.assertIn(
            "grep -Eq '^localPackages/Arti/(Cargo\\.(toml|lock)|build-ios\\.sh|arti-bitchat/)'",
            self.directives,
        )
        self.assertNotIn(
            "|docs/ARTI-BINARY-PROVENANCE\\.md)",
            self.directives,
        )

    def test_no_expression_interpolation_in_run_blocks(self) -> None:
        for block in extract_run_blocks(self.directives):
            self.assertNotIn("${{", block)

    def test_all_actions_are_pinned_by_commit_sha(self) -> None:
        for line in self.directives.splitlines():
            if "uses:" in line:
                self.assertRegex(line, SHA_PINNED_USES)


class BuildIosAndSwiftTestsHardeningTests(unittest.TestCase):
    def test_build_ios_uses_locked_exact_target_match_and_no_eval(self) -> None:
        script = strip_comments(BUILD_IOS_SCRIPT.read_text(encoding="utf-8"))
        self.assertIn("grep -qx \"$target\"", script)
        self.assertIn("cargo build --release --locked", script)
        self.assertNotRegex(script, r"\beval\b")

    def test_xcode_package_resolved_matches_root_package_resolved(self) -> None:
        pbxproj = (REPOSITORY_ROOT / "bitchat.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        package_swift = (REPOSITORY_ROOT / "Package.swift").read_text(encoding="utf-8")
        has_remote_packages = (
            "XCRemoteSwiftPackageReference" in pbxproj
            or ".package(url:" in package_swift
        )
        if not has_remote_packages:
            self.assertFalse(
                ROOT_PACKAGE_RESOLVED.exists(),
                "Stale root Package.resolved should not remain when all packages are local",
            )
            self.assertFalse(
                XCODE_PACKAGE_RESOLVED.exists(),
                "Stale Xcode Package.resolved should not remain when all packages are local",
            )
            return

        self.assertTrue(
            XCODE_PACKAGE_RESOLVED.exists(),
            "Xcode SwiftPM Package.resolved must be committed to pin remote package revisions",
        )
        self.assertEqual(
            ROOT_PACKAGE_RESOLVED.read_text(encoding="utf-8"),
            XCODE_PACKAGE_RESOLVED.read_text(encoding="utf-8"),
        )

    def test_swift_tests_workflow_checks_ios_device_and_pins_actions(self) -> None:
        directives = strip_comments(SWIFT_TESTS_WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("permissions:\n  contents: read", directives)
        self.assertIn("-sdk iphoneos", directives)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", directives)
        for line in directives.splitlines():
            if "uses:" in line:
                self.assertRegex(line, SHA_PINNED_USES)


if __name__ == "__main__":
    unittest.main()
