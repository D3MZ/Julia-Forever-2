#!/usr/bin/env python3
"""Point the README chart at an immutable commit without changing other text."""

import argparse
from pathlib import Path
import re

RAW_PREFIX = b"https://raw.githubusercontent.com/D3MZ/Julia-Forever-2/"
IMAGE_PATH = b"assets/hercules-history.png"
TARGET = (
    rb"(?:assets/hercules-history\.png|"
    rb"https://raw\.githubusercontent\.com/D3MZ/Julia-Forever-2/"
    rb"[0-9a-f]{40}/assets/hercules-history\.png)"
)
MARKDOWN_IMAGE = re.compile(
    rb'!\[[^\]\r\n]*\]\(\s*<?(?P<url>' + TARGET + rb')>?(?:\s+"[^"\r\n]*")?\s*\)',
    re.IGNORECASE,
)
HTML_IMAGE = re.compile(
    rb'<img\b[^>\r\n]*?\bsrc\s*=\s*["\'](?P<url>' + TARGET + rb')["\']',
    re.IGNORECASE,
)


def update_readme(path, commit):
    """Replace exactly one recognized image URL and keep all other bytes."""
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected a full lowercase 40-character Git commit ID")
    path = Path(path)
    if path.is_symlink():
        raise ValueError("README must be a regular file, not a symlink")
    original = path.read_bytes()
    matches = [match for pattern in (MARKDOWN_IMAGE, HTML_IMAGE) for match in pattern.finditer(original)]
    if len(matches) != 1:
        raise ValueError(f"Expected one recognizable Hercules image in README; found {len(matches)}")
    start, end = matches[0].span("url")
    target = RAW_PREFIX + commit.encode("ascii") + b"/" + IMAGE_PATH
    updated = original[:start] + target + original[end:]
    if updated == original:
        return False
    path.write_bytes(updated)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--readme", required=True, help="README to update")
    parser.add_argument("--commit", required=True, help="Commit containing the chart image")
    args = parser.parse_args()
    if update_readme(args.readme, args.commit):
        print(f"Updated only the Hercules image URL to commit {args.commit}.")
    else:
        print("The Hercules image URL already points to the current chart commit.")


if __name__ == "__main__":
    main()
