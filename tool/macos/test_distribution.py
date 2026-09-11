import base64
import tempfile
import unittest
from pathlib import Path

import distribution as dist


class DistributionTests(unittest.TestCase):
    def test_encodes_store_assignment(self):
        encoded = dist.encode_dart_define(dist.MACOS_APP_STORE_ASSIGNMENT)
        self.assertEqual(
            base64.b64decode(encoded).decode('utf-8'),
            dist.MACOS_APP_STORE_ASSIGNMENT,
        )

    def test_parses_store_and_unrelated_defines(self):
        store = dist.encode_dart_define(dist.MACOS_APP_STORE_ASSIGNMENT)
        other = dist.encode_dart_define('FLUTTER_VERSION=3.44.7')
        defines = dist.parse_dart_defines(f'{other},{store}')
        self.assertTrue(dist.macos_app_store_enabled(defines))
        self.assertEqual(defines['FLUTTER_VERSION'], '3.44.7')

    def test_website_defines_reject_store_flag(self):
        with self.assertRaisesRegex(dist.DistributionError, 'must not set'):
            dist.assert_website_distribution({dist.MACOS_APP_STORE_KEY: 'true'})
        with self.assertRaisesRegex(dist.DistributionError, 'require'):
            dist.assert_website_distribution({})
        with self.assertRaisesRegex(dist.DistributionError, 'require'):
            dist.assert_website_distribution({dist.MACOS_APP_STORE_KEY: '1'})
        dist.assert_website_distribution({dist.MACOS_APP_STORE_KEY: 'false'})

    def test_store_defines_require_exact_flag(self):
        with self.assertRaisesRegex(dist.DistributionError, 'must set'):
            dist.assert_app_store_distribution({})
        dist.assert_app_store_distribution({dist.MACOS_APP_STORE_KEY: 'true'})

    def test_command_detects_store_define(self):
        self.assertTrue(
            dist.command_has_macos_app_store_define(
                ['flutter', 'build', 'macos', dist.MACOS_APP_STORE_DART_DEFINE]
            )
        )
        self.assertFalse(
            dist.command_has_macos_app_store_define(
                ['flutter', 'build', 'macos', '--release']
            )
        )

    def test_reads_xcconfig_dart_defines(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'Flutter-Generated.xcconfig'
            encoded = dist.encode_dart_define(dist.MACOS_APP_STORE_ASSIGNMENT)
            path.write_text(f'DART_DEFINES={encoded}\n')
            defines = dist.dart_defines_from_xcconfig(path)
            self.assertTrue(dist.macos_app_store_enabled(defines))

    def test_finds_single_release_app(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / '开元阅读.app'
            app.mkdir()
            self.assertEqual(dist.find_release_app(root), app)
            (root / 'Extra.app').mkdir()
            with self.assertRaisesRegex(dist.DistributionError, 'exactly one'):
                dist.find_release_app(root)


if __name__ == '__main__':
    unittest.main()
