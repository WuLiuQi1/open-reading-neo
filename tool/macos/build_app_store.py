#!/usr/bin/env python3
"""Build a signed Mac App Store archive; upload only when explicitly requested."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

import distribution as dist

ROOT = dist.ROOT
OUT = ROOT / 'build' / 'app-store-macos'
BUNDLE_ID = 'com.niki.xxread'


class BuildError(Exception):
    pass


def version_from_pubspec():
    match = re.search(r'^version:\s*([^+\s]+)', (ROOT / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise BuildError('pubspec.yaml has no version')
    return match[1]


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--build-name', default=None)
    result.add_argument('--build-number', required=True)
    result.add_argument('--check', action='store_true', help='Read-only local prerequisite check')
    result.add_argument('--upload', action='store_true', help='Upload archive to App Store Connect')
    result.add_argument('--allow-beta-xcode', action='store_true', help='Local export/check only')
    # Flutter's framework check runs `lipo <binary> -verify_arch <archs...>`, and the
    # lipo shipped with current Xcode reads every arch after the first as another input
    # file, so a universal macOS archive fails with "does not contain architectures".
    # Passing a single arch keeps that check to one argument. Drop this back to
    # "arm64 x86_64" once the toolchain accepts the multi-arch form.
    result.add_argument('--archs', default='arm64',
                        help='ARCHS for the archive (default: arm64; Intel needs "arm64 x86_64")')
    return result


def read_command(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        raise BuildError('Unable to inspect local Xcode/SDK installation') from None


def team_id():
    return os.environ.get('MACOS_TEAM_ID', '').strip() or os.environ.get('IOS_TEAM_ID', '').strip()


def signing_identity():
    return os.environ.get('MACOS_CODE_SIGN_IDENTITY', 'Apple Distribution').strip()


def provisioning_profile():
    # Xcode's automatic-signing engine fails to re-negotiate the Associated Domains
    # capability for a macOS archive from the command line (confirmed by bisecting
    # Release.entitlements: removing associated-domains alone makes Automatic signing
    # succeed). Manual signing against an explicit profile sidesteps that renegotiation.
    # The profile must be signed with an "Apple Distribution" certificate, not the
    # legacy "3rd Party Mac Developer Application" type Xcode no longer matches by name.
    default = 'Open Reading macOS App Store (Apple Distribution)'
    return os.environ.get('MACOS_PROVISIONING_PROFILE', default).strip()


def check_inputs(args):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.build_name):
        raise BuildError('--build-name must use major.minor.patch')
    if not re.fullmatch(r'[1-9][0-9]*(?:\.[0-9]+){0,2}', args.build_number):
        raise BuildError('--build-number must use 1-3 numeric components; first must be positive')
    if args.upload and args.allow_beta_xcode:
        raise BuildError('--allow-beta-xcode cannot be used with --upload')
    if not team_id():
        raise BuildError('IOS_TEAM_ID or MACOS_TEAM_ID is required for automatic signing')
    credentials = [os.environ.get(name, '').strip() for name in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH')]
    if any(credentials) and not all(credentials):
        raise BuildError('ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be provided together')
    if args.upload and not all(credentials):
        raise BuildError('ASC API credentials are required for --upload')
    if all(credentials):
        key = Path(credentials[2])
        if not key.is_absolute() or not key.is_file():
            raise BuildError('ASC_KEY_PATH must be an existing absolute private-key path')
        if ROOT.resolve() == key.resolve() or ROOT.resolve() in key.resolve().parents:
            raise BuildError('Store the ASC private key outside the repository')
        if key.stat().st_mode & 0o077:
            raise BuildError('ASC private key permissions must exclude group/other access (chmod 600)')
    for command in ('flutter', 'pod', 'xcodebuild', 'xcrun', 'codesign'):
        if shutil.which(command) is None:
            raise BuildError(f'Required tool is missing: {command}')
    if not (ROOT / 'macos/Runner.xcworkspace').is_dir():
        raise BuildError('macos/Runner.xcworkspace is missing')
    xcode = read_command(['xcodebuild', '-version'])
    match = re.search(r'Xcode (\d+)', xcode)
    if not match or int(match[1]) < 26:
        raise BuildError('Xcode 26 or newer is required')
    developer_dir = os.environ.get('DEVELOPER_DIR') or read_command(['xcode-select', '-p'])
    seed = re.search(r'beta|seed|release.?candidate', developer_dir + '\n' + xcode, re.I)
    if seed and not args.allow_beta_xcode:
        raise BuildError('Selected Xcode is a beta/seed; select a released Xcode for upload')
    sdk = read_command(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
    if not re.match(r'^\d+', sdk):
        raise BuildError('macOS SDK is required')


def auth_arguments():
    args = ['-allowProvisioningUpdates']
    if os.environ.get('ASC_KEY_PATH'):
        args += ['-authenticationKeyPath', os.environ['ASC_KEY_PATH'],
                 '-authenticationKeyID', os.environ['ASC_KEY_ID'],
                 '-authenticationKeyIssuerID', os.environ['ASC_ISSUER_ID']]
    return args


def run_step(label, command, log, cwd=ROOT):
    print(label, flush=True)
    with log.open('a') as stream:
        stream.write('\n' + label + '\n')
        stream.flush()
        try:
            subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, check=True)
        except (OSError, subprocess.CalledProcessError):
            raise BuildError(f'{label} failed; inspect private log: {log}') from None


def flutter_config_command(args):
    return ['flutter', 'build', 'macos', '--config-only', '--release', '--no-pub',
            dist.MACOS_APP_STORE_DART_DEFINE,
            '--build-name', args.build_name, '--build-number', args.build_number]


def verify_store_defines():
    try:
        dist.assert_app_store_distribution(dist.read_generated_dart_defines())
    except dist.DistributionError as error:
        raise BuildError(str(error)) from error


def validate_archive(archive, version, build):
    apps = list((archive / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        raise BuildError('Archive must contain exactly one application')
    app = apps[0]
    info_path = app / 'Contents/Info.plist'
    try:
        with info_path.open('rb') as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise BuildError('Archive is missing a valid Contents/Info.plist') from None
    expected = {'CFBundleIdentifier': BUNDLE_ID, 'CFBundleShortVersionString': version,
                'CFBundleVersion': build}
    if any(info.get(key) != value for key, value in expected.items()):
        raise BuildError('Archive bundle/version/build does not match requested identity')
    if not (app / 'Contents/_CodeSignature/CodeResources').is_file():
        raise BuildError('Archive is unsigned')
    if not (app / 'Contents/embedded.provisionprofile').is_file():
        raise BuildError('Archive is missing an embedded provisioning profile')
    return app


def export_options(upload):
    return {'method': 'app-store-connect', 'destination': 'upload' if upload else 'export',
            'signingStyle': 'automatic', 'teamID': team_id(),
            'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True}


def execute(args):
    args.build_name = args.build_name or version_from_pubspec()
    check_inputs(args)
    output = OUT / f'{args.build_name}-{args.build_number}'
    if output.exists():
        raise BuildError(f'Output exists; refusing overwrite: {output}')
    if args.check:
        print('Mac App Store prerequisites passed. Apple account, signing assets and upload acceptance are not verified.')
        print(f'Store billing define: {dist.MACOS_APP_STORE_DART_DEFINE}')
        return 0
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    log = output / 'build.log'
    log.touch(mode=0o600)
    config = flutter_config_command(args)
    if not dist.command_has_macos_app_store_define(config):
        raise BuildError('Mac App Store Flutter command is missing OPEN_READING_MACOS_APP_STORE')
    run_step('Core Flutter validation: locked dependencies',
             ['flutter', 'pub', 'get', '--enforce-lockfile'], log)
    run_step('Product build: configure Flutter macOS App Store', config, log)
    verify_store_defines()
    run_step('Product build: locked CocoaPods dependencies', ['pod', 'install', '--deployment'], log, ROOT / 'macos')
    archive = output / 'OpenReading.xcarchive'
    run_step('Product build: signed Mac App Store archive',
             ['xcodebuild', '-workspace', 'macos/Runner.xcworkspace', '-scheme', 'Runner',
              '-configuration', 'Release', '-destination', 'generic/platform=macOS',
              '-archivePath', str(archive), *auth_arguments(),
              'CODE_SIGN_STYLE=Manual',
              'CODE_SIGN_IDENTITY=' + signing_identity(),
              'PROVISIONING_PROFILE_SPECIFIER=' + provisioning_profile(),
              'DEVELOPMENT_TEAM=' + team_id(),
              'FLUTTER_BUILD_NAME=' + args.build_name, 'FLUTTER_BUILD_NUMBER=' + args.build_number,
              'ARCHS=' + args.archs, 'ONLY_ACTIVE_ARCH=NO',
              'archive'], log)
    verify_store_defines()
    app = validate_archive(archive, args.build_name, args.build_number)
    run_step('Product build: verify archive signature',
             ['codesign', '--verify', '--deep', '--strict', str(app)], log)
    options = output / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps(export_options(args.upload)))
    destination = output / 'export'
    label = 'App Store Connect upload' if args.upload else 'Product build: export signed Mac App Store package'
    run_step(label, ['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                    '-exportPath', str(destination), '-exportOptionsPlist', str(options), *auth_arguments()], log)
    if args.upload:
        print('Xcode upload completed. Use connect.mjs status to confirm Apple processing before reporting ready.')
    else:
        packages = list(destination.glob('*.pkg'))
        if len(packages) != 1:
            raise BuildError('Export did not produce exactly one Mac App Store .pkg')
        digest = hashlib.sha256()
        with packages[0].open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        (output / 'SHA256SUMS').write_text(f'{digest.hexdigest()}  export/{packages[0].name}\n')
        print(f'Signed Mac App Store package exported: {packages[0]}\nSHA256: {digest.hexdigest()}')
        print('Billing: App Store in-app purchase. Do not ship this binary on the website.')
    return 0


def main(argv=None):
    try:
        return execute(parser().parse_args(argv))
    except BuildError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
