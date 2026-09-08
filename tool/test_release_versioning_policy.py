"""Execute the release workflow's actual version guards without publishing."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / '.github/workflows/release.yml').read_text(encoding='utf-8')


def workflow_fragment(start, end):
    return textwrap.dedent(WORKFLOW[WORKFLOW.index(start):WORKFLOW.index(end, WORKFLOW.index(start))])


class ReleaseVersioningPolicyTest(unittest.TestCase):
    def test_version_then_numeric_build_order(self):
        source = workflow_fragment('          SEMVER = re.compile(', '          metadata = json.loads(')
        namespace = {'re': re}
        exec('from __future__ import annotations\n' + source, namespace)
        compare = namespace['compare_semver']
        for left, right, expected in [
            ('v2.6.7+10', 'v2.6.7+9', 1),
            ('v2.6.7+9', 'v2.6.7+10', -1),
            ('v2.6.7+999', 'v2.6.8+1', -1),
            ('v2.6.7+1', 'v2.6.7', 1),
            ('v2.6.7', 'v2.6.7', 0),
            ('v2.6.7-beta.2+999', 'v2.6.7+1', -1),
        ]:
            with self.subTest(left=left, right=right):
                self.assertEqual(compare(left, right), expected)

    def test_tag_and_pubspec_matrix(self):
        script = workflow_fragment('          release_identity="${RELEASE_TAG#v}"', '      - name: Continue directly')
        self.run_guard(['bash', '-euo', 'pipefail', '-c', script])

    def test_manifest_uses_matching_build(self):
        source = workflow_fragment('          repository = os.environ["PUBLIC_RELEASE_REPOSITORY"]', '          bundle_dir = Path("official-site-bundle")')
        self.run_guard(['python3', '-c', 'import os, re\nfrom pathlib import Path\n' + source])

    def test_web_retention_recognizes_build_release_directories(self):
        wrapper = (ROOT / 'tool/web/deploy_web_release.sh').read_text()
        pattern = re.search(r'\[\[ "\$old_release" =~ (.+) \]\]', wrapper).group(1)
        for name, accepted in [
            ('v2.6.7-123-1-abcdef012345', True),
            ('v2.6.7+260908001-123-1-abcdef012345', True),
            ('../current', False), ('shared', False),
        ]:
            result = subprocess.run(['bash', '-c', '[[ "$DIRECTORY" =~ $PATTERN ]]'],
                env={**os.environ, 'DIRECTORY': name, 'PATTERN': pattern})
            self.assertEqual(result.returncode == 0, accepted, name)

    def test_github_release_url_accepts_encoded_build_separator(self):
        source = workflow_fragment('          from urllib.parse import unquote, urlsplit', '          published_at = metadata.get("publishedAt")')
        for suffix, accepted in [
            ('v2.6.7+260908001', True), ('v2.6.7%2B260908001', True),
            ('v2.6.7%2B260908002', False), ('v2.6.7+260908001?other=1', False),
        ]:
            namespace = {'repository': 'miloquinn/open-reading', 'tag': 'v2.6.7+260908001',
                'metadata': {'url': 'https://github.com/miloquinn/open-reading/releases/tag/' + suffix}}
            with self.subTest(suffix=suffix):
                if accepted:
                    exec(source, namespace)
                    self.assertEqual(namespace['expected_url'], 'https://github.com/miloquinn/open-reading/releases/tag/v2.6.7+260908001')
                else:
                    with self.assertRaises(SystemExit):
                        exec(source, namespace)

    def run_guard(self, command):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'pubspec.yaml').write_text('version: 2.6.7+260907001\n')
            for tag, accepted in [
                ('v2.6.7', True), ('v2.6.7+260907001', True),
                ('v2.6.6+260907001', False), ('v2.6.7+260907002', False),
                ('v2.6.7+0', False), ('v2.6.7+01', False), ('v2.6.7+bad', False),
            ]:
                with self.subTest(tag=tag):
                    result = subprocess.run(command, cwd=directory, capture_output=True, text=True,
                        env={**os.environ, 'RELEASE_TAG': tag, 'PUBLIC_RELEASE_REPOSITORY': 'miloquinn/open-reading'})
                    self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
