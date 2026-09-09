import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from reading_source_lab.audit import audit_files, render_json, render_markdown
from reading_source_lab.cli import main


def source(url="https://books.test", timestamp=0, **fields):
    return {
        "bookSourceName": "Fixture",
        "bookSourceUrl": url,
        "lastUpdateTime": timestamp,
        "searchUrl": "/search",
        "ruleSearch": {"bookList": "li"},
        "ruleToc": {"chapterList": "li"},
        "ruleContent": {"content": "article@text"},
        **fields,
    }


class CorpusAuditTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name, payload):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_selects_newest_before_file_and_global_deduplication(self):
        a = self.write("a.json", [source(timestamp=20), source(timestamp=10, ruleContent={})])
        b = self.write("nested/b.json", [source(timestamp=15, ruleContent={})])
        forward = audit_files([a, b])
        self.assertEqual(forward, audit_files([b, a]))
        self.assertEqual(forward["totals"]["source_records"], 3)
        self.assertEqual(forward["totals"]["duplicate_records"], 2)
        self.assertEqual(forward["totals"]["unique_sources"], 1)
        self.assertEqual(forward["corpus"]["core_reading"], {"ready": 1})
        self.assertEqual(forward["files"][0]["core_reading"], {"ready": 1})

    def test_equal_versions_use_path_then_record_index_and_keep_fragments(self):
        self.write("a.json", [source(timestamp=10)])
        self.write("z.json", [source(timestamp=10), source(timestamp=10, ruleContent={})])
        self.write("variant.json", [source(url="https://books.test#variant")])
        report = audit_files([self.root])
        self.assertEqual(report["totals"]["unique_sources"], 2)
        self.assertEqual(report["corpus"]["core_reading"], {"incomplete": 1, "ready": 1})

    def test_directory_and_explicit_path_inventory_each_file_once(self):
        a = self.write("sources.json", [source()])
        unrelated = self.write("nested/replacement.JSON", [{"pattern": "advert"}])
        self.write("ignored.txt", [])
        report = audit_files([self.root, a])
        self.assertEqual(report, audit_files([self.root]))
        self.assertEqual(report["totals"]["input_files"], 2)
        self.assertEqual(report["totals"]["unrelated_files"], 1)
        self.assertEqual(report["totals"]["unrelated_records"], 1)
        item = next(item for item in report["files"] if item["file"].endswith(".JSON"))
        self.assertEqual(item["classification"], "unrelated")
        self.assertEqual(item["sha256"], hashlib.sha256(unrelated.read_bytes()).hexdigest())
        self.assertEqual(item["bytes"], unrelated.stat().st_size)
        self.assertEqual(report["totals"]["unique_sources"], 1)

    def test_invalid_names_urls_and_missing_urls_remain_accounted_for(self):
        self.write("sources.json", [
            source(bookSourceName=""), source(url="{{dynamicUrl}}"),
            source(url=""), source(url=""), source(url="https://[invalid"),
        ])
        report = audit_files([self.root])
        self.assertEqual(report["totals"]["source_records"], 5)
        self.assertEqual(report["totals"]["invalid_records"], 1)
        self.assertEqual(report["totals"]["unique_sources"], 4)
        self.assertEqual(report["totals"]["invalid_urls"], 4)
        self.assertEqual(report["totals"]["duplicate_records"], 0)

    def test_unrelated_wrappers_malformed_json_and_url_lists_are_distinct(self):
        self.write("other.json", {"data": [{"pattern": "advert"}]})
        self.write("links.json", {"sourceUrls": ["https://list.test/auth-secret"]})
        (self.root / "broken.json").write_text('{"auth-secret":', encoding="utf-8")
        report = audit_files([self.root, self.root / "missing.json"])
        self.assertEqual(report["totals"]["unrelated_files"], 1)
        self.assertEqual(report["totals"]["url_list_files"], 1)
        self.assertEqual(report["totals"]["invalid_files"], 2)
        self.assertEqual(report["totals"]["unresolved_source_urls"], 1)
        self.assertEqual(report["totals"]["unique_sources"], 0)
        self.assertNotIn("auth-secret", render_json(report))

    def test_reports_only_metadata_and_never_claims_execution_conformance(self):
        self.write("private.json", [source(
            bookSourceName="secret-title",
            header={"Authorization": "secret-token"},
            bookSourceComment="java.secretMetadata('hidden')",
            loginUrl="https://books.test/secret-login",
            cookie="secret-cookie",
            jsLib="function secretLibrary() {}",
            ruleContent={"content": "@js:java.get('secret-value')"},
        )])
        report = audit_files([self.root])
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["conformance"]["target_percent"], 80)
        self.assertEqual(report["conformance"]["status"], "not_verified")
        self.assertEqual(report["conformance"]["executed_sources"], 0)
        self.assertEqual(report["conformance"]["unknown_sources"], 1)
        for rendered in [render_json(report), render_markdown(report)]:
            self.assertNotIn("secret-", rendered)
            self.assertNotIn("secretLibrary", rendered)
            self.assertNotIn("secretMetadata", rendered)
            self.assertNotIn('"compatibility"', rendered)
            self.assertIn("not_verified", rendered)

    def test_cli_accepts_a_directory(self):
        self.write("sources.json", [source()])
        output = self.root / "report.md"
        self.assertEqual(main([str(self.root), "--output", str(output)]), 0)
        self.assertIn("not_verified", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
