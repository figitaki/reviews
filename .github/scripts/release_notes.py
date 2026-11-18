#!/usr/bin/env python3
"""Write the GitHub release body for a cli-v* tag from CHANGELOG.md.

Usage: release_notes.py <tag> <owner/repo> [changelog]

The body is a short header, the CHANGELOG section for the tag's version, and
a compare link from the previous cli-v* tag. Exits 1 when the section is
missing, so a release cannot go out without its changelog entry.
"""

import re
import subprocess
import sys


def version_key(version):
    """Order versions like semver: 0.0.1-alpha.2 < 0.0.1 < 0.0.2."""
    core, _, pre = version.partition("-")
    nums = tuple(int(n) for n in core.split("."))
    if not pre:
        return nums, (1,)
    parts = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return nums, (0,) + parts


def previous_tag(tag, tags):
    version = tag.removeprefix("cli-v")
    older = [t for t in tags if t.startswith("cli-v") and t != tag
             and version_key(t.removeprefix("cli-v")) < version_key(version)]
    return max(older, key=lambda t: version_key(t.removeprefix("cli-v")), default=None)


def changelog_section(text, version):
    match = re.search(
        rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S
    )
    return match.group(1).strip() if match else None


def git_tags():
    out = subprocess.run(["git", "tag", "--list"], check=True, capture_output=True, text=True)
    return out.stdout.split()


def notes(tag, repo, changelog, tags):
    version = tag.removeprefix("cli-v")
    section = changelog_section(changelog, version)
    if section is None:
        raise ValueError(f"CHANGELOG.md has no [{version}] section for {tag}")

    owner = repo.split("/")[0]
    lines = [
        f"Archives of the `reviews` CLI {version} for Linux x64/arm64 and macOS "
        f"x64/arm64 are attached below, with `checksums.txt`. Install with "
        f"`install.sh`, or pass `--version {version}` to get this version.",
    ]
    if f"server-v{version}" in tags:
        lines.append(
            f"The matching server image is `ghcr.io/{owner}/reviews-server:server-v{version}`."
        )
    body = "\n\n".join([" ".join(lines), section])

    prev = previous_tag(tag, tags)
    if prev:
        body += f"\n\n**Full changelog:** https://github.com/{repo}/compare/{prev}...{tag}"
    return body + "\n"


def main(argv):
    tag, repo = argv[1], argv[2]
    path = argv[3] if len(argv) > 3 else "CHANGELOG.md"
    with open(path, encoding="utf-8") as f:
        changelog = f.read()
    try:
        sys.stdout.write(notes(tag, repo, changelog, git_tags()))
    except ValueError as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
