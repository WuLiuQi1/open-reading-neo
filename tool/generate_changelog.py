#!/usr/bin/env python3
"""Build the in-app changelog catalog from GitHub release-note Markdown files.

Existing localized notes are preserved so translations can be maintained by
hand. Release-note files may use ``vX.Y.Z.md`` or ``vX.Y.Z+BUILD.md``. Legacy
filenames can also declare an explicit build number in their version metadata.
New entries use the release-note bullets as the source-language notes; the
Flutter service falls back to those notes until translations are added.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
RELEASE_NOTE_NAME_RE = re.compile(r"^v(\d+\.\d+\.\d+)(?:\+(\d+))?\.md$")
BUILD_NUMBER_RE = re.compile(r"^[1-9][0-9]*$")
INLINE_MARKUP_RE = re.compile(r"\*\*(.*?)\*\*|__(.*?)__|`([^`]*)`")
LINK_RE = re.compile(r"\[([^]]+)\]\([^)]*\)")
METADATA_VERSION_RE = re.compile(
    r"^(?:正式)?版本(?:号)?\s*[:：]\s*(\d+\.\d+\.\d+)$|^version\s*[:：]\s*(\d+\.\d+\.\d+)$",
    re.IGNORECASE,
)
METADATA_BUILD_RE = re.compile(
    r"^(?:基础|正式)?构建号\s*[:：]\s*(\d+)$|^build(?:\s+number|number)?\s*[:：]\s*(\d+)$",
    re.IGNORECASE,
)
META_HEADINGS = {
    "版本",
    "版本信息",
    "版本資訊",
    "version",
    "versions",
    "验证",
    "驗證",
    "verification",
}


def version_key(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(version)
    if not match:
        raise ValueError(f"Invalid release-note version: {version}")
    return tuple(int(part) for part in match.groups())


def clean_item(item: str) -> str:
    item = LINK_RE.sub(r"\1", item)
    item = INLINE_MARKUP_RE.sub(
        lambda match: next(group for group in match.groups() if group is not None),
        item,
    )
    return " ".join(item.split()).strip()


def parse_release_notes(path: Path) -> list[str]:
    """Extract user-facing bullets, excluding version metadata and validation."""
    items: list[str] = []
    skip_section = False
    for line in path.read_text(encoding="utf-8").splitlines():
        heading = re.match(r"^#{2,6}\s+(.+?)\s*$", line)
        if heading:
            title = clean_item(heading.group(1)).rstrip(":").lower()
            skip_section = title in META_HEADINGS
            continue
        if skip_section:
            continue
        bullet = re.match(r"^\s*[-*+]\s+(.+?)\s*$", line)
        if bullet:
            item = clean_item(bullet.group(1))
            if item:
                items.append(item)
    if not items:
        raise ValueError(f"No release-note bullets found in {path}")
    return items


def parse_release_metadata(path: Path) -> tuple[str | None, str | None]:
    """Read explicit generic version/build metadata from a release note."""
    version: str | None = None
    build_number: str | None = None
    in_metadata = False
    for line in path.read_text(encoding="utf-8").splitlines():
        heading = re.match(r"^#{2,6}\s+(.+?)\s*$", line)
        if heading:
            title = clean_item(heading.group(1)).rstrip(":").lower()
            in_metadata = title in META_HEADINGS
            continue
        if not in_metadata:
            continue
        bullet = re.match(r"^\s*[-*+]\s+(.+?)\s*$", line)
        if not bullet:
            continue
        item = clean_item(bullet.group(1))
        version_match = METADATA_VERSION_RE.fullmatch(item)
        if version_match:
            parsed = next(group for group in version_match.groups() if group)
            if version is not None and version != parsed:
                raise ValueError(f"Conflicting version metadata in {path}")
            version = parsed
            continue
        build_match = METADATA_BUILD_RE.fullmatch(item)
        if build_match:
            parsed = next(group for group in build_match.groups() if group)
            validate_build_number(parsed, str(path))
            if build_number is not None and build_number != parsed:
                raise ValueError(f"Conflicting build metadata in {path}")
            build_number = parsed
    return version, build_number


def validate_build_number(build_number: str, source: str) -> None:
    if not BUILD_NUMBER_RE.fullmatch(build_number):
        raise ValueError(
            f"Invalid build number {build_number!r} in {source}; "
            "expected a canonical positive integer"
        )


def load_catalog(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schemaVersion": 1, "entries": []}
    catalog = json.loads(path.read_text(encoding="utf-8"))
    if catalog.get("schemaVersion") != 1 or not isinstance(catalog.get("entries"), list):
        raise ValueError(f"Unsupported changelog catalog: {path}")
    return catalog


def entry_identity(entry: dict[str, Any]) -> tuple[str, str | None]:
    version = entry.get("version")
    if not isinstance(version, str):
        raise ValueError("Changelog entry is missing a string version")
    version_key(version)
    build_number = entry.get("buildNumber")
    if build_number is not None and not isinstance(build_number, str):
        raise ValueError(
            f"Invalid buildNumber for changelog version {version}: {build_number!r}"
        )
    if build_number is not None:
        validate_build_number(build_number, f"catalog version {version}")
    return version, build_number


def release_sort_key(identity: tuple[str, str | None]) -> tuple[int, int, int, int, int]:
    version, build_number = identity
    return (*version_key(version), int(build_number is not None), int(build_number or 0))


def build_catalog(notes_dir: Path, existing: dict[str, Any]) -> dict[str, Any]:
    existing_entries: dict[tuple[str, str | None], dict[str, Any]] = {}
    for entry in existing["entries"]:
        if not isinstance(entry, dict):
            continue
        identity = entry_identity(entry)
        if identity in existing_entries:
            raise ValueError(f"Duplicate existing changelog identity: {identity}")
        existing_entries[identity] = entry

    markdown_entries: dict[tuple[str, str | None], dict[str, Any]] = {}
    for path in notes_dir.glob("v*.md"):
        filename_match = RELEASE_NOTE_NAME_RE.fullmatch(path.name)
        if not filename_match:
            raise ValueError(f"Invalid release-note filename: {path.name}")
        version, filename_build = filename_match.groups()
        version_key(version)
        if filename_build is not None:
            validate_build_number(filename_build, path.name)
        metadata_version, metadata_build = parse_release_metadata(path)
        if metadata_version is not None and metadata_version != version:
            raise ValueError(
                f"Filename version {version} does not match metadata version "
                f"{metadata_version} in {path}"
            )
        if (
            filename_build is not None
            and metadata_build is not None
            and filename_build != metadata_build
        ):
            raise ValueError(
                f"Filename build {filename_build} does not match metadata build "
                f"{metadata_build} in {path}"
            )
        build_number = filename_build or metadata_build
        identity = (version, build_number)
        if identity in markdown_entries:
            raise ValueError(f"Duplicate release identity {identity}: {path}")
        entry: dict[str, Any] = {"version": version}
        if build_number is not None:
            entry["buildNumber"] = build_number
        entry["notes"] = {"zh": parse_release_notes(path)}
        markdown_entries[identity] = entry

    # A catalog created before build-aware entries can be upgraded without
    # losing hand-maintained translations when exactly one Markdown release
    # supplies the build identity for that version.
    for legacy_identity in list(existing_entries):
        version, build_number = legacy_identity
        if build_number is not None or legacy_identity in markdown_entries:
            continue
        candidates = [
            identity
            for identity in markdown_entries
            if identity[0] == version and identity[1] is not None
        ]
        if len(candidates) == 1 and candidates[0] not in existing_entries:
            entry = existing_entries.pop(legacy_identity)
            entry = dict(entry)
            entry["buildNumber"] = candidates[0][1]
            existing_entries[candidates[0]] = entry

    # Markdown releases are authoritative for coverage, while legacy catalog
    # entries without a corresponding file remain available for old versions.
    identities = sorted(
        set(existing_entries) | set(markdown_entries),
        key=release_sort_key,
        reverse=True,
    )
    entries: list[dict[str, Any]] = []
    for identity in identities:
        if identity in existing_entries:
            entry = existing_entries[identity]
            if identity in markdown_entries:
                notes = dict(entry.get("notes", {}))
                notes.setdefault("zh", markdown_entries[identity]["notes"]["zh"])
                entry = {"version": identity[0]}
                if identity[1] is not None:
                    entry["buildNumber"] = identity[1]
                entry["notes"] = notes
            entries.append(entry)
        else:
            entries.append(markdown_entries[identity])
    return {"schemaVersion": 1, "entries": entries}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the catalog is stale")
    parser.add_argument("--notes-dir", type=Path, default=Path(".github/release-notes"))
    parser.add_argument("--output", type=Path, default=Path("assets/changelog/changelog.json"))
    args = parser.parse_args()

    generated = build_catalog(args.notes_dir, load_catalog(args.output))
    rendered = json.dumps(generated, ensure_ascii=False, indent=4) + "\n"
    current = args.output.read_text(encoding="utf-8") if args.output.exists() else ""
    if args.check:
        if current != rendered:
            print(f"{args.output} is stale; run tool/generate_changelog.py", file=sys.stderr)
            return 1
        return 0
    args.output.write_text(rendered, encoding="utf-8")
    print(f"Wrote {len(generated['entries'])} changelog entries to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
