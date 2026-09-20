#!/usr/bin/env python3
"""Check internal markdown links in the repository.

Scans .md files for ``[text](target)`` links where ``target`` is a relative
path (not http/https, not mailto, not an anchor-only link) and reports any
target that does not exist as a file. Exit code is 0 if all links resolve,
1 otherwise.

This is a contributor-facing lint; it is not wired into CI by default but can
be run locally before pushing doc changes.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]

# Match [text](target) where target is not a URL scheme and not an anchor.
# We intentionally keep this simple: it catches the common case of relative
# file links and ignores http/https/mailto/# anchors.
_LINK_PATTERN = re.compile(
    r"\[(?P<text>[^\]]*)\]\((?P<target>[^)#h][^)]*)\)"
)

# Schemes we treat as external and skip.
_EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "ftp://", "tel:")


class BrokenLink:
    __slots__ = ("source", "line", "target", "resolved")

    def __init__(self, source: Path, line: int, target: str, resolved: Path) -> None:
        self.source = source
        self.line = line
        self.target = target
        self.resolved = resolved

    def __str__(self) -> str:
        return f"{self.source}:{self.line}: broken link -> {self.target} (resolved to {self.resolved})"


def is_external(target: str) -> bool:
    return target.startswith(_EXTERNAL_SCHEMES)


def find_markdown_files(root: Path) -> list[Path]:
    files = sorted(root.rglob("*.md"))
    # Skip vendor / build / hidden directories.
    return [
        f for f in files
        if not any(part.startswith(".") and part not in (".", "..")
                   for part in f.relative_to(root).parts)
        and not str(f).startswith(str(root / "localPackages"))
    ]


def check_links(root: Path, files: list[Path] | None = None) -> list[BrokenLink]:
    """Return a list of BrokenLink entries for unresolved relative links."""
    if files is None:
        files = find_markdown_files(root)
    broken: list[BrokenLink] = []
    for source in files:
        try:
            text = source.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            for match in _LINK_PATTERN.finditer(line):
                target = match.group("target").strip()
                if not target or is_external(target):
                    continue
                # Strip any anchor fragment.
                path_part = target.split("#", 1)[0]
                if not path_part:
                    continue
                resolved = (source.parent / path_part).resolve()
                if not resolved.exists():
                    broken.append(BrokenLink(source, line_no, target, resolved))
    return broken


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check internal markdown links in the repository.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=REPOSITORY_ROOT,
        help=f"repository root (default: {REPOSITORY_ROOT})",
    )
    args = parser.parse_args(argv)

    broken = check_links(args.root)
    if not broken:
        print(f"check_links: all internal links resolve under {args.root}")
        return 0
    for link in broken:
        print(link, file=sys.stderr)
    print(f"check_links: {len(broken)} broken link(s)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
