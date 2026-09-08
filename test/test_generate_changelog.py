import tempfile
import unittest
from pathlib import Path

from tool.generate_changelog import (
    build_catalog,
    parse_release_metadata,
    parse_release_notes,
)


class GenerateChangelogTest(unittest.TestCase):
    def test_extracts_bullets_and_ignores_version_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v9.1.0.md"
            path.write_text(
                "# Open Reading v9.1.0\n\n"
                "## Changes\n\n"
                "- **Fast** reading with [details](https://example.com).\n"
                "\n## Version\n\n- Version: `9.1.0`\n",
                encoding="utf-8",
            )

            self.assertEqual(
                parse_release_notes(path),
                ["Fast reading with details."],
            )

    def test_adds_markdown_versions_and_preserves_existing_localizations(self):
        with tempfile.TemporaryDirectory() as directory:
            notes_dir = Path(directory) / "release-notes"
            notes_dir.mkdir()
            (notes_dir / "v9.1.0.md").write_text(
                "# Open Reading v9.1.0\n\n## Changes\n\n- New feature\n",
                encoding="utf-8",
            )
            existing = {
                "schemaVersion": 1,
                "entries": [
                    {
                        "version": "9.0.0",
                        "notes": {
                            "en": ["Existing translation"],
                            "zh": ["已有翻译"],
                        },
                    }
                ],
            }

            catalog = build_catalog(notes_dir, existing)

            self.assertEqual(
                [entry["version"] for entry in catalog["entries"]],
                ["9.1.0", "9.0.0"],
            )
            self.assertEqual(catalog["entries"][0]["notes"]["zh"], ["New feature"])
            self.assertEqual(
                catalog["entries"][1]["notes"]["en"],
                ["Existing translation"],
            )

    def test_supports_build_specific_filenames_and_numeric_build_sorting(self):
        with tempfile.TemporaryDirectory() as directory:
            notes_dir = Path(directory) / "release-notes"
            notes_dir.mkdir()
            for filename in (
                "v9.1.0+9.md",
                "v9.1.0+10.md",
                "v9.0.9+999.md",
                "v9.1.0.md",
            ):
                (notes_dir / filename).write_text(
                    f"# {filename}\n\n## Changes\n\n- {filename}\n",
                    encoding="utf-8",
                )

            catalog = build_catalog(
                notes_dir,
                {"schemaVersion": 1, "entries": []},
            )

            self.assertEqual(
                [
                    (entry["version"], entry.get("buildNumber"))
                    for entry in catalog["entries"]
                ],
                [
                    ("9.1.0", "10"),
                    ("9.1.0", "9"),
                    ("9.1.0", None),
                    ("9.0.9", "999"),
                ],
            )

    def test_extracts_explicit_build_metadata_from_legacy_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v2.6.7.md"
            path.write_text(
                "# Open Reading v2.6.7\n\n"
                "## Changes\n\n- Fix\n\n"
                "## 版本信息\n\n"
                "- 版本：`2.6.7`\n"
                "- 基础构建号：`260907001`\n",
                encoding="utf-8",
            )

            self.assertEqual(
                parse_release_metadata(path),
                ("2.6.7", "260907001"),
            )

    def test_migrates_version_only_entry_to_explicit_build_without_losing_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            notes_dir = Path(directory) / "release-notes"
            notes_dir.mkdir()
            (notes_dir / "v9.1.0.md").write_text(
                "# Open Reading v9.1.0\n\n"
                "## Changes\n\n- New feature\n\n"
                "## Version\n\n"
                "- Version: `9.1.0`\n"
                "- Build number: `123`\n",
                encoding="utf-8",
            )
            existing = {
                "schemaVersion": 1,
                "entries": [
                    {
                        "version": "9.1.0",
                        "notes": {
                            "en": ["Existing translation"],
                            "zh": ["已有翻译"],
                        },
                    }
                ],
            }

            catalog = build_catalog(notes_dir, existing)

            self.assertEqual(len(catalog["entries"]), 1)
            self.assertEqual(catalog["entries"][0]["buildNumber"], "123")
            self.assertEqual(
                catalog["entries"][0]["notes"],
                existing["entries"][0]["notes"],
            )

    def test_rejects_duplicate_release_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            notes_dir = Path(directory) / "release-notes"
            notes_dir.mkdir()
            (notes_dir / "v9.1.0.md").write_text(
                "# Open Reading v9.1.0\n\n"
                "## Changes\n\n- Legacy filename\n\n"
                "## Version\n\n- Version: `9.1.0`\n- Build number: `123`\n",
                encoding="utf-8",
            )
            (notes_dir / "v9.1.0+123.md").write_text(
                "# Open Reading v9.1.0\n\n## Changes\n\n- New filename\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "Duplicate release identity"):
                build_catalog(notes_dir, {"schemaVersion": 1, "entries": []})

    def test_rejects_filename_and_metadata_build_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            notes_dir = Path(directory) / "release-notes"
            notes_dir.mkdir()
            (notes_dir / "v9.1.0+124.md").write_text(
                "# Open Reading v9.1.0\n\n"
                "## Changes\n\n- Fix\n\n"
                "## Version\n\n- Version: `9.1.0`\n- Build number: `123`\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "does not match metadata build"):
                build_catalog(notes_dir, {"schemaVersion": 1, "entries": []})

    def test_rejects_zero_and_leading_zero_build_numbers(self):
        for build_number in ("0", "001"):
            with self.subTest(build_number=build_number):
                with tempfile.TemporaryDirectory() as directory:
                    notes_dir = Path(directory) / "release-notes"
                    notes_dir.mkdir()
                    (notes_dir / f"v9.1.0+{build_number}.md").write_text(
                        "# Open Reading v9.1.0\n\n## Changes\n\n- Fix\n",
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(ValueError, "Invalid build number"):
                        build_catalog(
                            notes_dir,
                            {"schemaVersion": 1, "entries": []},
                        )

    def test_rejects_duplicate_existing_identity(self):
        existing = {
            "schemaVersion": 1,
            "entries": [
                {"version": "9.1.0", "buildNumber": "123", "notes": {}},
                {"version": "9.1.0", "buildNumber": "123", "notes": {}},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(
                ValueError,
                "Duplicate existing changelog identity",
            ):
                build_catalog(Path(directory), existing)


if __name__ == "__main__":
    unittest.main()
