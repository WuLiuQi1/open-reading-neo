from __future__ import annotations

from collections import Counter
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Any, Iterable

from .parser import ReadingSource, parse_payload


FEATURES: dict[str, re.Pattern[str]] = {
    "javascript": re.compile(r"@js:|<js>", re.I),
    "webview": re.compile(
        r"java\.webview\s*\(|['\"]?webview['\"]?\s*:\s*true|"
        r"['\"]?webjs['\"]?\s*:\s*['\"][^'\"]+",
        re.I,
    ),
    "xpath": re.compile(r"@xpath:|(?<!:)//(?:[a-z*]|\*)", re.I),
    "jsonpath": re.compile(r"@json:|\$\. |\$\[|\$\.\.|\$\.", re.I | re.X),
    "css": re.compile(r"@css:|(?:^|[@\n])(?:[.#\[]|class\.|id\.|tag\.)", re.I),
    "regex": re.compile(r"##|(?:^|\n):[^/]"),
    "interleave": re.compile(r"%%"),
    "state": re.compile(r"@put:|@get:|java\.(?:put|get)\s*\(", re.I),
    "post": re.compile(r"['\"]?method['\"]?\s*:\s*['\"]?post|java\.post\s*\(", re.I),
    "cookie": re.compile(r"enabledcookiejar|cookie\.|getcookie|setcookie", re.I),
    "login": re.compile(
        r"source\.(?:get|put|remove)login|login(?:info|header)", re.I
    ),
    "crypto": re.compile(r"\b(?:md5|sha\d*|aes|des|rsa|hmac|base64)\b", re.I),
    "java_dom": re.compile(r"java\.(?:getelements|getelement|getstring|getstringlist)\s*\(", re.I),
    "browser_interaction": re.compile(r"startbrowser|verification|captcha|验证码|验证", re.I),
    "head": re.compile(r"java\.head\s*\(|['\"]?method['\"]?\s*:\s*['\"]?head", re.I),
    "cache_api": re.compile(r"\bcache\.[A-Za-z_][A-Za-z0-9_]*\s*\("),
    "shared_script": re.compile(r"['\"]jsLib['\"]\s*:"),
}

SCRIPT_API = re.compile(
    r"\b(java|cookie|source)\.([A-Za-z_][A-Za-z0-9_]*)\b"
)
JAVA_COLLECTION_API = re.compile(r"\.(size|get|isEmpty|toArray)\s*\(")

CAPABILITY_SCOPE = {
    "javascript": "native runtime; unavailable on Web",
    "webview": "requires a native browser host",
    "xpath": "selector subset",
    "jsonpath": "JSONPath evaluator",
    "css": "HTML selector evaluator",
    "regex": "regular-expression evaluator",
    "interleave": "list interleaving",
    "state": "source and book variable subset",
    "post": "HTTP request transport",
    "cookie": "source session storage",
    "login": "requires session or user interaction",
    "crypto": "cryptographic helper subset",
    "java_dom": "Java-style DOM helper subset",
    "browser_interaction": "requires a user interaction host",
    "head": "HTTP request transport",
    "cache_api": "source session cache subset",
    "shared_script": "shared script loading; execution unverified",
}


@dataclass(frozen=True)
class FileAudit:
    file: str
    parsed: int
    duplicates: int
    errors: int
    invalid_urls: int
    source_types: dict[str, int]
    features: dict[str, int]
    capabilities: dict[str, int]
    core_reading: dict[str, int]
    capability_readiness: dict[str, int]
    script_apis: dict[str, int]
    java_collection_apis: dict[str, int]


def audit_files(paths: Iterable[str | Path]) -> dict[str, Any]:
    files = _input_files(paths)
    root = Path(os.path.commonpath([path.parent for path in files])) if files else Path(".")
    audits = []
    candidates = []
    totals = Counter(dict.fromkeys((
        "input_files", "source_files", "unrelated_files", "unrelated_records",
        "url_list_files", "invalid_files", "source_records", "valid_records",
        "invalid_records", "unresolved_source_urls",
    ), 0))
    for path in files:
        label = path.relative_to(root).as_posix()
        item = asdict(_audit(Path(label), [], 0, 0))
        item.update(file=label, sha256=None, bytes=None, classification="invalid", records=0)
        totals["input_files"] += 1
        try:
            raw = path.read_bytes()
            item.update(sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw))
            payload = json.loads(raw.decode("utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            # JSON parser errors may include input text: report only a count.
            item["errors"] = 1
            totals["invalid_files"] += 1
            audits.append(item)
            continue
        parsed = parse_payload(payload, origin=label, deduplicate=False)
        item.update(classification=parsed.classification, records=parsed.record_count)
        totals["unresolved_source_urls"] += len(parsed.source_urls)
        if parsed.classification == "sources":
            selected = _newest_sources(parsed.sources)
            item.update(asdict(_audit(
                Path(label), selected, len(parsed.sources) - len(selected), len(parsed.errors)
            )))
            item["file"] = label
            totals.update(source_files=1, source_records=parsed.record_count,
                          valid_records=len(parsed.sources), invalid_records=len(parsed.errors))
            candidates.extend(parsed.sources)
        elif parsed.classification == "url_list":
            totals["url_list_files"] += 1
        else:
            totals.update(unrelated_files=1, unrelated_records=parsed.record_count)
        audits.append(item)
    selected = _newest_sources(candidates)
    corpus = asdict(_audit(
        Path("corpus"), selected, len(candidates) - len(selected), totals["invalid_records"]
    ))
    corpus.pop("file")
    totals.update(unique_sources=len(selected), duplicate_records=corpus["duplicates"],
                  invalid_urls=corpus["invalid_urls"])
    manifest = "".join(f"{item['file']}\t{item['sha256'] or '-'}\n" for item in audits)
    return {
        "schema_version": 2,
        "files": audits,
        "totals": dict(totals),
        "selection": {
            "identity": "full bookSourceUrl including fragment; missing URL retains its record",
            "version": "maximum integer lastUpdateTime, then relative path, then zero-based record index",
            "manifest_sha256": hashlib.sha256(manifest.encode("utf-8")).hexdigest(),
            "manifest_encoding": "UTF-8 sorted relative path, tab, SHA-256 (or -), newline",
        },
        "corpus": corpus,
        "feature_totals": corpus["features"],
        "script_api_totals": corpus["script_apis"],
        "java_collection_api_totals": corpus["java_collection_apis"],
        "capability_scope": CAPABILITY_SCOPE,
        "conformance": {
            "target_percent": 80,
            "status": "not_verified",
            "executed_sources": 0,
            "unknown_sources": len(selected),
            "pass_rate_percent": None,
            "network_requests_performed": False,
            "reason": "Structural readiness and detected APIs do not establish rule execution or live-site success.",
        },
    }


def _input_files(paths: Iterable[str | Path]) -> list[Path]:
    files = set()
    for value in paths:
        path = Path(value).expanduser().resolve()
        if path.is_dir():
            files.update(
                item.resolve() for item in path.rglob("*")
                if item.is_file() and item.suffix.lower() == ".json"
            )
        else:
            files.add(path)
    return sorted(files)


def _newest_sources(sources: list[ReadingSource]) -> list[ReadingSource]:
    def rank(source: ReadingSource) -> tuple[int, str, int]:
        try:
            updated = int(source.raw.get("lastUpdateTime") or 0)
        except (TypeError, ValueError, OverflowError):
            updated = 0
        return updated, source.origin, source.index

    selected = {}
    for source in sources:
        previous = selected.get(source.stable_key)
        if previous is None or rank(source) > rank(previous):
            selected[source.stable_key] = source
    return [selected[key] for key in sorted(selected)]


def render_markdown(report: dict[str, Any]) -> str:
    totals = report["totals"]
    corpus = report["corpus"]
    count = totals["unique_sources"]
    ready = corpus["core_reading"].get("ready", 0)
    rate = 100 * ready / count if count else 0
    lines = [
        "# Reading source corpus audit",
        "",
        "> Offline structural audit; no scripts or network requests were executed. Configuration values are omitted.",
        "",
        f"**80% execution compatibility target: `{report['conformance']['status']}`.** "
        f"Executed sources: **0**; unknown: **{count}**. No execution pass rate is available.",
        "",
        f"Inventoried **{totals['input_files']}** JSON files: **{totals['source_files']}** source files, "
        f"**{totals['unrelated_files']}** unrelated files, **{totals['url_list_files']}** URL lists, "
        f"**{totals['invalid_files']}** unreadable or malformed files.",
        "",
        f"Source records: **{totals['source_records']}**; valid records: **{totals['valid_records']}**; "
        f"invalid records: **{totals['invalid_records']}**; duplicates: **{totals['duplicate_records']}**; "
        f"unique sources: **{count}**; invalid/empty URLs among unique sources: **{totals['invalid_urls']}**.",
        "",
        f"Unrelated records: **{totals['unrelated_records']}**; unfetched source-list URLs: "
        f"**{totals['unresolved_source_urls']}**. These are retained separately from the source denominator.",
        "",
        "## Selection and manifest",
        "",
        report["selection"]["identity"] + ".",
        report["selection"]["version"] + ". Selection occurs before any per-file deduplication.",
        "",
        f"Manifest SHA-256: `{report['selection']['manifest_sha256']}`.",
        report["selection"]["manifest_encoding"] + ". Paths are relative to the common input-file parent.",
        "",
        "## Files",
        "",
        "| File | Classification | Records | Selected in file | Errors | SHA-256 |",
        "|---|---|---:|---:|---:|---|",
    ]
    for item in report["files"]:
        label = item["file"].replace("|", "\\|").replace("\n", " ")
        lines.append(
            f"| {label} | {item['classification']} | {item['records']} | {item['parsed']} | "
            f"{item['errors']} | `{item['sha256'] or 'unavailable'}` |"
        )
    lines.extend(
        [
            "",
            "## Structural readiness",
            "",
            f"**{ready} / {count} ({rate:.2f}%)** unique sources have a text type, "
            "valid HTTP(S) URL, search entry, catalog rules, and content rules. This is an "
            "offline structural readiness rate, not an execution compatibility or live-site success rate.",
            "",
            "Content types: " + ", ".join(f"`{key}`={value}" for key, value in corpus["source_types"].items()) + ".",
            "",
            "Capability readiness: " + ", ".join(
                f"`{key}`={value}" for key, value in corpus["capability_readiness"].items()
            ) + ". All execution outcomes remain unknown, including sources without detected extended requirements.",
            "",
            "## Feature dependency totals",
            "",
            "Counts use globally selected sources. Pattern detection is heuristic and implementation scope is descriptive, not a test verdict.",
            "",
            "| Feature | Sources | Implementation scope |",
            "|---|---:|---|",
        ]
    )
    for feature, count in sorted(
        report["feature_totals"].items(), key=lambda item: (-item[1], item[0])
    ):
        lines.append(f"| `{feature}` | {count} | {report['capability_scope'][feature]} |")
    lines.extend(
        [
            "",
            "## Script API occurrences",
            "",
            "| API | Occurrences |",
            "|---|---:|",
        ]
    )
    for api, count in sorted(
        report["script_api_totals"].items(), key=lambda item: (-item[1], item[0])
    ):
        lines.append(f"| `{api}` | {count} |")
    lines.extend(
        [
            "",
            "## Java collection compatibility occurrences",
            "",
            "| Method | Occurrences |",
            "|---|---:|",
        ]
    )
    for api, count in sorted(
        report["java_collection_api_totals"].items(),
        key=lambda item: (-item[1], item[0]),
    ):
        lines.append(f"| `{api}()` | {count} |")
    return "\n".join(lines) + "\n"


def render_json(report: dict[str, Any]) -> str:
    return json.dumps(report, ensure_ascii=False, indent=2) + "\n"


def _audit(
    path: Path, sources: list[ReadingSource], duplicates: int, errors: int
) -> FileAudit:
    source_types = Counter(str(source.source_type) for source in sources)
    features = Counter()
    capabilities = Counter()
    core_reading = Counter()
    readiness = Counter()
    script_apis = Counter()
    java_collection_apis = Counter()
    invalid_urls = 0
    for source in sources:
        if not source.is_http_url:
            invalid_urls += 1
        text = _execution_text(source.raw)
        script_apis.update(
            f"{match.group(1)}.{match.group(2)}" for match in SCRIPT_API.finditer(text)
        )
        java_collection_apis.update(
            match.group(1) for match in JAVA_COLLECTION_API.finditer(text)
        )
        matched = _features_for_source(source)
        features.update(matched)
        for capability, keys in {
            "search": ("searchUrl", "ruleSearch"),
            "explore": ("exploreUrl", "ruleExplore"),
            "detail": ("ruleBookInfo",),
            "toc": ("ruleToc",),
            "content": ("ruleContent",),
        }.items():
            if any(source.raw.get(key) for key in keys):
                capabilities[capability] += 1
        core_reading[_core_reading_status(source)] += 1
        readiness[_capability_readiness(source, matched)] += 1
    return FileAudit(
        file=path.name,
        parsed=len(sources),
        duplicates=duplicates,
        errors=errors,
        invalid_urls=invalid_urls,
        source_types=dict(sorted(source_types.items())),
        features=dict(sorted(features.items())),
        capabilities=dict(sorted(capabilities.items())),
        core_reading=dict(sorted(core_reading.items())),
        capability_readiness=dict(sorted(readiness.items())),
        script_apis=dict(sorted(script_apis.items())),
        java_collection_apis=dict(sorted(java_collection_apis.items())),
    )


def _capability_readiness(source: ReadingSource, features: set[str]) -> str:
    if source.source_type != 0:
        return "outside_text_chain"
    if not source.is_http_url or not source.raw.get("ruleContent"):
        return "incomplete_structure"
    if features & {
        "javascript", "browser_interaction", "login", "webview", "state", "xpath",
        "crypto", "java_dom", "shared_script", "cache_api",
    }:
        return "needs_runtime_validation"
    return "no_detected_extended_requirements"


def _core_reading_status(source: ReadingSource) -> str:
    raw = source.raw
    ready = (
        source.source_type == 0
        and source.is_http_url
        and bool(raw.get("searchUrl"))
        and bool(raw.get("ruleSearch"))
        and bool(raw.get("ruleToc"))
        and bool(raw.get("ruleContent"))
    )
    return "ready" if ready else "incomplete"


def _features_for_source(source: ReadingSource) -> set[str]:
    """Find capability dependencies without counting empty template fields."""
    raw = source.raw
    text = _safe_serialized(raw)
    matched = set()

    def values(*keys: str) -> list[str]:
        result: list[str] = []
        for key in keys:
            value = raw.get(key)
            if isinstance(value, str) and value.strip():
                result.append(value)
            elif isinstance(value, dict):
                result.append(_safe_serialized(value))
        return result

    nonempty_text = "\n".join(
        values(
            "searchUrl",
            "exploreUrl",
            "loginUrl",
            "loginUi",
            "loginCheckJs",
            "webJs",
            "jsLib",
            "header",
            "cookie",
            "ruleSearch",
            "ruleExplore",
            "ruleBookInfo",
            "ruleToc",
            "ruleContent",
        )
    )
    for name, pattern in FEATURES.items():
        haystack = nonempty_text if name in {
            "login",
            "webview",
            "shared_script",
            "cookie",
            "javascript",
            "xpath",
            "jsonpath",
            "css",
            "regex",
            "interleave",
            "state",
            "post",
            "crypto",
            "java_dom",
            "browser_interaction",
            "head",
            "cache_api",
        } else text
        if pattern.search(haystack):
            matched.add(name)

    if values("loginUrl", "loginUi", "loginCheckJs"):
        matched.add("login")
    if values("webJs"):
        matched.add("webview")
    if values("jsLib"):
        matched.add("shared_script")
    if raw.get("enabledCookieJar") is True:
        matched.add("cookie")
    elif "cookie." not in nonempty_text.lower():
        matched.discard("cookie")
    return matched


def _safe_serialized(raw: dict[str, Any]) -> str:
    # Values are scanned only in memory and never returned by the auditor.
    return json.dumps(raw, ensure_ascii=False, separators=(",", ":"))


def _execution_text(raw: dict[str, Any]) -> str:
    fields = (
        "searchUrl", "exploreUrl", "loginUrl", "loginCheckJs", "webJs", "jsLib",
        "ruleSearch", "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent",
    )
    values = [raw[key] for key in fields if raw.get(key)]
    header = raw.get("header")
    if isinstance(header, str) and re.match(r"\s*(?:@js:|<js>)", header, re.I):
        values.append(header)
    return "\n".join(
        value if isinstance(value, str) else _safe_serialized(value)
        for value in values
    )
