import contextlib
import io
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import build_app_store as build
import distribution as dist


class BuildMacAppStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'repo'
        (self.root / 'macos/Runner.xcworkspace').mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 2.6.7+260908001\n')
        self.key = self.base / 'test.p8'
        self.key.touch(mode=0o600)
        for context in [
            patch.object(build, 'ROOT', self.root),
            patch.object(build, 'OUT', self.root / 'build/app-store-macos'),
            patch.object(dist, 'ROOT', self.root),
            patch.object(
                dist,
                'GENERATED_XCCONFIG',
                self.root / 'macos/Flutter/ephemeral/Flutter-Generated.xcconfig',
            ),
            patch.dict(os.environ, {'IOS_TEAM_ID': 'test-team'}, clear=True),
            patch.object(build.shutil, 'which', return_value='/fake/tool'),
            patch.object(build, 'read_command', side_effect=self.tool_output),
        ]:
            context.start()
            self.addCleanup(context.stop)

    def tool_output(self, command):
        return {
            'xcodebuild': 'Xcode 26.4\nBuild version 17E202',
            'xcode-select': '/Applications/Xcode.app/Contents/Developer',
            'xcrun': '15.4',
        }[command[0]]

    def args(self, *extra):
        result = build.parser().parse_args(['--build-number', '1', *extra])
        result.build_name = result.build_name or build.version_from_pubspec()
        return result

    def credentials(self):
        os.environ.update(
            ASC_KEY_ID='test-key',
            ASC_ISSUER_ID='test-issuer',
            ASC_KEY_PATH=str(self.key),
        )

    def write_store_defines(self):
        xcconfig = dist.GENERATED_XCCONFIG
        xcconfig.parent.mkdir(parents=True, exist_ok=True)
        xcconfig.write_text(
            'DART_DEFINES=' + dist.encode_dart_define(dist.MACOS_APP_STORE_ASSIGNMENT) + '\n'
        )

    def archive(self, archive, *, version='2.6.7', number='1', bundle=build.BUNDLE_ID):
        app = archive / 'Products/Applications/开元阅读.app'
        (app / 'Contents/_CodeSignature').mkdir(parents=True)
        (app / 'Contents/_CodeSignature/CodeResources').touch()
        (app / 'Contents/embedded.provisionprofile').touch()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle,
            'CFBundleShortVersionString': version,
            'CFBundleVersion': number,
        }))
        return app

    def test_flutter_config_includes_store_define(self):
        command = build.flutter_config_command(self.args())
        self.assertIn(dist.MACOS_APP_STORE_DART_DEFINE, command)
        self.assertIn('--config-only', command)

    def test_macos_team_id_overrides_ios_team(self):
        os.environ['MACOS_TEAM_ID'] = 'mac-team'
        self.assertEqual(build.team_id(), 'mac-team')

    def test_check_does_not_build(self):
        with patch.object(build, 'run_step') as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build.execute(self.args('--check')), 0)
            run.assert_not_called()
        self.assertFalse(build.OUT.exists())

    def test_upload_requires_credentials(self):
        with self.assertRaisesRegex(build.BuildError, 'credentials'):
            build.check_inputs(self.args('--upload'))

    def test_existing_output_is_not_overwritten(self):
        target = build.OUT / '2.6.7-1'
        target.mkdir(parents=True)
        sentinel = target / 'keep.txt'
        sentinel.write_text('owned archive')
        with self.assertRaisesRegex(build.BuildError, 'refusing overwrite'):
            build.execute(self.args())
        self.assertEqual(sentinel.read_text(), 'owned archive')

    def test_archive_identity_mismatch_is_rejected(self):
        archive = self.base / 'wrong'
        self.archive(archive, bundle='com.example.wrong')
        with self.assertRaisesRegex(build.BuildError, 'identity'):
            build.validate_archive(archive, '2.6.7', '1')

    def test_export_and_upload_use_expected_commands(self):
        self.credentials()
        for upload, number in [(False, '1'), (True, '2')]:
            calls = []

            def fake_step(label, command, log, cwd=None, upload=upload, number=number):
                calls.append((label, command, cwd))
                if command[:3] == ['flutter', 'build', 'macos']:
                    self.write_store_defines()
                if 'archive' in command:
                    self.archive(
                        Path(command[command.index('-archivePath') + 1]),
                        number=number,
                    )
                if '-exportArchive' in command and not upload:
                    dest = Path(command[command.index('-exportPath') + 1])
                    dest.mkdir()
                    (dest / 'OpenReading.pkg').write_bytes(b'fake-pkg')

            with patch.object(build, 'run_step', side_effect=fake_step), contextlib.redirect_stdout(io.StringIO()):
                extra = ['--upload'] if upload else []
                self.assertEqual(build.execute(self.args('--build-number', number, *extra)), 0)
            flutter = next(call[1] for call in calls if call[1][0] == 'flutter' and 'build' in call[1])
            self.assertIn(dist.MACOS_APP_STORE_DART_DEFINE, flutter)
            pod = next(call for call in calls if call[1][0] == 'pod')
            self.assertEqual(pod[2], self.root / 'macos')
            xcode = [call[1] for call in calls if call[1][0] == 'xcodebuild']
            self.assertEqual(len(xcode), 2)
            options = plistlib.loads(
                (build.OUT / f'2.6.7-{number}/ExportOptions.plist').read_bytes()
            )
            self.assertEqual(options['destination'], 'upload' if upload else 'export')
            self.assertEqual((build.OUT / f'2.6.7-{number}/SHA256SUMS').exists(), not upload)

    def test_missing_store_define_after_config_fails(self):
        def fake_step(label, command, log, cwd=None):
            xcconfig = dist.GENERATED_XCCONFIG
            xcconfig.parent.mkdir(parents=True, exist_ok=True)
            xcconfig.write_text('DART_DEFINES=\n')

        with patch.object(build, 'run_step', side_effect=fake_step):
            with self.assertRaisesRegex(build.BuildError, 'must set'):
                build.execute(self.args())


if __name__ == '__main__':
    unittest.main()
