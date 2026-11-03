import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "changelog", pathlib.Path(__file__).resolve().parent.parent / "changelog.py"
)
changelog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(changelog)

REPO = "michaelrigart/hulder"
BASE = f"https://github.com/{REPO}"

WITH_EARLIER = f"""# Changelog

All notable changes are recorded here.

## [Unreleased]

### Added

- X

## [20261101-1430] - 2026-11-01

### Fixed

- Y

[Unreleased]: {BASE}/compare/20261101-1430...HEAD
[20261101-1430]: {BASE}/releases/tag/20261101-1430
"""

FIRST = f"""# Changelog

## [Unreleased]

### Added

- X

[Unreleased]: {BASE}/commits/main
"""


class ReleaseTests(unittest.TestCase):
    def test_release_moves_unreleased_entries(self):
        out = changelog.release(WITH_EARLIER, "20261102-0905", REPO)
        self.assertEqual(
            out,
            "# Changelog\n\nAll notable changes are recorded here.\n\n"
            "## [Unreleased]\n\n"
            "## [20261102-0905] - 2026-11-02\n\n### Added\n\n- X\n\n"
            "## [20261101-1430] - 2026-11-01\n\n### Fixed\n\n- Y\n\n"
            f"[Unreleased]: {BASE}/compare/20261102-0905...HEAD\n"
            f"[20261102-0905]: {BASE}/compare/20261101-1430...20261102-0905\n"
            f"[20261101-1430]: {BASE}/releases/tag/20261101-1430\n",
        )

    def test_first_release_links_to_its_release(self):
        out = changelog.release(FIRST, "20261102-0905", REPO)
        self.assertIn(f"[Unreleased]: {BASE}/compare/20261102-0905...HEAD\n", out)
        self.assertIn(f"[20261102-0905]: {BASE}/releases/tag/20261102-0905\n", out)
        self.assertNotIn("commits/main", out)

    def test_date_comes_from_version(self):
        out = changelog.release(FIRST, "20261231-2359", REPO)
        self.assertIn("## [20261231-2359] - 2026-12-31", out)

    def test_release_refuses_empty_unreleased(self):
        empty = FIRST.replace("### Added\n\n- X\n\n", "")
        with self.assertRaisesRegex(ValueError, r"^nothing under \[Unreleased\]$"):
            changelog.release(empty, "20261102-0905", REPO)

    def test_release_refuses_existing_version(self):
        with self.assertRaisesRegex(ValueError, r"^20261101-1430 already released$"):
            changelog.release(WITH_EARLIER, "20261101-1430", REPO)

    def test_rejects_malformed_version(self):
        for bad in ("2026-11-02", "v20261102-0905", "20261102-905"):
            with self.subTest(version=bad):
                with self.assertRaises(ValueError):
                    changelog.release(FIRST, bad, REPO)
                with self.assertRaises(ValueError):
                    changelog.notes(WITH_EARLIER, bad)


class NotesTests(unittest.TestCase):
    def test_notes_returns_section_body(self):
        self.assertEqual(changelog.notes(WITH_EARLIER, "20261101-1430"), "### Fixed\n\n- Y")

    def test_notes_refuses_unknown_version(self):
        with self.assertRaisesRegex(ValueError, r"^20260101-0000 not found$"):
            changelog.notes(WITH_EARLIER, "20260101-0000")


class HasUnreleasedTests(unittest.TestCase):
    def test_detects_entries(self):
        self.assertTrue(changelog.has_unreleased(FIRST))
        self.assertFalse(changelog.has_unreleased(FIRST.replace("- X", "")))


if __name__ == "__main__":
    unittest.main()
