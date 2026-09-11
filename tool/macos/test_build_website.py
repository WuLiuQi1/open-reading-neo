import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_website as build
import distribution as dist


class BuildWebsiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        (self.root / 'macos/Runner.xcworkspace').mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 2.6.7+260908001\n')
        for context in [
            patch.object(build, 'ROOT', self.root),
            patch.object(dist, 'ROOT', self.root),
            patch.object(
                dist,
                'GENERATED_XCCONFIG',
                self.root / 'macos/Flutter/ephemeral/Flutter-Generated.xcconfig',
            ),
            patch.object(build.shutil, 'which', return_value='/fake/flutter'),
        ]:
            context.start()
            self.addCleanup(context.stop)

    def write_defines(self, *assignments):
        xcconfig = dist.GENERATED_XCCONFIG
        xcconfig.parent.mkdir(parents=True, exist_ok=True)
        encoded = ','.join(dist.encode_dart_define(item) for item in assignments)
        xcconfig.write_text(f'DART_DEFINES={encoded}\n')

    def test_flutter_command_is_website_distribution(self):
        command = build.flutter_build_command()
        self.assertEqual(command[:4], ['flutter', 'build', 'macos', '--release'])
        self.assertIn(dist.MACOS_WEBSITE_DART_DEFINE, command)
        self.assertFalse(dist.command_has_macos_app_store_define(command))

    def test_check_does_not_build(self):
        with patch.object(build, 'run_step') as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build.execute(build.parser().parse_args(['--check'])), 0)
            run.assert_not_called()

    def test_rejects_store_define_in_command(self):
        with self.assertRaisesRegex(build.BuildError, 'must not pass'):
            build.run_step(
                'bad',
                ['flutter', 'build', 'macos', dist.MACOS_APP_STORE_DART_DEFINE],
            )

    def test_build_verifies_website_defines_and_app(self):
        calls = []

        def fake_step(label, command, log=None, cwd=None):
            calls.append(command)
            if command[:3] == ['flutter', 'build', 'macos']:
                products = self.root / 'build/macos/Build/Products/Release'
                products.mkdir(parents=True)
                (products / '开元阅读.app').mkdir()
                self.write_defines('FLUTTER_VERSION=3.44.7', dist.MACOS_WEBSITE_ASSIGNMENT)

        with patch.object(build, 'run_step', side_effect=fake_step), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build.execute(build.parser().parse_args(['--no-pub'])), 0)
        self.assertEqual(calls, [build.flutter_build_command()])

    def test_missing_website_define_is_rejected(self):
        def fake_step(label, command, log=None, cwd=None):
            self.write_defines('FLUTTER_VERSION=3.44.7')
            products = self.root / 'build/macos/Build/Products/Release'
            products.mkdir(parents=True)
            (products / '开元阅读.app').mkdir()

        with patch.object(build, 'run_step', side_effect=fake_step):
            with self.assertRaisesRegex(build.BuildError, 'require'):
                build.execute(build.parser().parse_args(['--no-pub']))

    def test_store_define_in_generated_config_is_rejected(self):
        def fake_step(label, command, log=None, cwd=None):
            self.write_defines(dist.MACOS_APP_STORE_ASSIGNMENT)
            products = self.root / 'build/macos/Build/Products/Release'
            products.mkdir(parents=True)
            (products / '开元阅读.app').mkdir()

        with patch.object(build, 'run_step', side_effect=fake_step):
            with self.assertRaisesRegex(build.BuildError, 'must not set'):
                build.execute(build.parser().parse_args(['--no-pub']))


if __name__ == '__main__':
    unittest.main()
