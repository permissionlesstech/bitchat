import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_links  # type: ignore[import-not-found]


class CheckLinksTests(unittest.TestCase):
    def _repo_with(self, files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp())
        for rel, content in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return root

    def test_no_broken_links_when_target_exists(self) -> None:
        root = self._repo_with(
            {
                "README.md": "See [the guide](docs/guide.md).\n",
                "docs/guide.md": "# Guide\n",
            }
        )
        broken = check_links.check_links(root)
        self.assertEqual(broken, [])

    def test_reports_broken_relative_link(self) -> None:
        root = self._repo_with(
            {
                "README.md": "See [missing](docs/does-not-exist.md).\n",
            }
        )
        broken = check_links.check_links(root)
        self.assertEqual(len(broken), 1)
        self.assertIn("does-not-exist.md", str(broken[0]))
        self.assertEqual(broken[0].line, 1)

    def test_ignores_external_links(self) -> None:
        root = self._repo_with(
            {
                "README.md": "External: [github](https://github.com).\n",
            }
        )
        broken = check_links.check_links(root)
        self.assertEqual(broken, [])

    def test_ignores_anchor_only_links(self) -> None:
        root = self._repo_with(
            {
                "README.md": "Jump: [section](#section).\n",
            }
        )
        broken = check_links.check_links(root)
        self.assertEqual(broken, [])

    def test_resolves_links_with_anchor_fragment(self) -> None:
        root = self._repo_with(
            {
                "README.md": "See [guide](docs/guide.md#section).\n",
                "docs/guide.md": "# Guide\n",
            }
        )
        broken = check_links.check_links(root)
        self.assertEqual(broken, [])

    def test_main_returns_zero_when_clean(self) -> None:
        root = self._repo_with(
            {
                "README.md": "See [guide](guide.md).\n",
                "guide.md": "# Guide\n",
            }
        )
        self.assertEqual(check_links.main(["--root", str(root)]), 0)

    def test_main_returns_one_when_broken(self) -> None:
        root = self._repo_with({"README.md": "See [missing](nope.md).\n"})
        self.assertEqual(check_links.main(["--root", str(root)]), 1)

    def test_finds_markdown_files_recursively(self) -> None:
        root = self._repo_with(
            {
                "README.md": "[a](docs/a.md)\n[b](docs/sub/b.md)\n",
                "docs/a.md": "# A\n",
                "docs/sub/b.md": "# B\n",
            }
        )
        files = check_links.find_markdown_files(root)
        names = {f.relative_to(root).as_posix() for f in files}
        self.assertIn("README.md", names)
        self.assertIn("docs/a.md", names)
        self.assertIn("docs/sub/b.md", names)


if __name__ == "__main__":
    unittest.main()
