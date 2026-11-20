"""Release notes come from the tag's CHANGELOG section.

Run with python3 -m unittest discover -s .github/scripts -p 'test_*.py'.
"""

import unittest

from release_notes import notes, previous_tag

CHANGELOG = """# Changelog

## [Unreleased]

- Not released yet.

## [0.0.2] - 2026-11-18

Second release.

### Added

- Device login.

## [0.0.1] - 2026-11-16

- First release.
"""

TAGS = ["cli-v0.0.1-alpha.2", "cli-v0.0.1-alpha.10", "cli-v0.0.1", "cli-v0.0.2",
        "cli-v0.0.10", "server-v0.0.2"]


class ReleaseNotesTest(unittest.TestCase):
    def test_body_is_header_section_and_compare_link(self):
        body = notes("cli-v0.0.2", "figitaki/reviews", CHANGELOG, TAGS)
        self.assertIn("pass `--version 0.0.2`", body)
        self.assertIn("`ghcr.io/figitaki/reviews-server:server-v0.0.2`", body)
        self.assertIn("Second release.\n\n### Added\n\n- Device login.", body)
        self.assertNotIn("Not released yet", body)
        self.assertNotIn("First release", body)
        self.assertNotIn("## [0.0.2]", body)
        self.assertTrue(body.endswith(
            "**Full changelog:** https://github.com/figitaki/reviews/compare/cli-v0.0.1...cli-v0.0.2\n"))

    def test_previous_tag_orders_versions_numerically(self):
        self.assertEqual(previous_tag("cli-v0.0.1", TAGS), "cli-v0.0.1-alpha.10")
        self.assertEqual(previous_tag("cli-v0.0.10", TAGS), "cli-v0.0.2")
        self.assertEqual(previous_tag("cli-v0.0.3-alpha.0", TAGS), "cli-v0.0.2")
        self.assertIsNone(previous_tag("cli-v0.0.1-alpha.2", TAGS))

    def test_no_server_line_or_compare_link_without_those_tags(self):
        body = notes("cli-v0.0.1", "figitaki/reviews", CHANGELOG, ["cli-v0.0.1"])
        self.assertNotIn("server image", body)
        self.assertNotIn("Full changelog", body)
        self.assertIn("- First release.", body)

    def test_missing_section_fails(self):
        with self.assertRaisesRegex(ValueError, r"no \[0.0.3\] section"):
            notes("cli-v0.0.3", "figitaki/reviews", CHANGELOG, TAGS)


if __name__ == "__main__":
    unittest.main()
