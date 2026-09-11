#!/usr/bin/env python3
"""Build the GitHub / website Developer ID macOS app (redemption codes, no Apple tax)."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys

import distribution as dist

ROOT = dist.ROOT


class BuildError(Exception):
    pass


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--check', action='store_true', help='Read-only local prerequisite check')
    result.add_argument('--no-pub', action='store_true', help='Skip flutter pub get; CI already resolved deps')
    return result


def check_inputs():
    if shutil.which('flutter') is None:
        raise BuildError('Required tool is missing: flutter')
    if not (ROOT / 'macos/Runner.xcworkspace').is_dir():
        raise BuildError('macos/Runner.xcworkspace is missing')


def run_step(label, command, log=None, cwd=ROOT):
    print(label, flush=True)
    if dist.command_has_macos_app_store_define(command):
        raise BuildError('Website macOS build command must not pass OPEN_READING_MACOS_APP_STORE')
    if log is None:
        try:
            subprocess.run(command, cwd=cwd, check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise BuildError(f'{label} failed') from error
        return
    with log.open('a') as stream:
        stream.write('\n' + label + '\n')
        stream.flush()
        try:
            subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, check=True)
        except (OSError, subprocess.CalledProcessError):
            raise BuildError(f'{label} failed; inspect private log: {log}') from None


def flutter_build_command():
    return [
        'flutter',
        'build',
        'macos',
        '--release',
        '--no-pub',
        dist.MACOS_WEBSITE_DART_DEFINE,
    ]


def verify_website_defines():
    try:
        dist.assert_website_distribution(dist.read_generated_dart_defines())
    except dist.DistributionError as error:
        raise BuildError(str(error)) from error


def execute(args):
    check_inputs()
    if args.check:
        print(
            'Website macOS prerequisites passed. This path sets '
            f'{dist.MACOS_WEBSITE_DART_DEFINE} and rejects the App Store define.'
        )
        return 0
    if not args.no_pub:
        run_step('Core Flutter validation: locked dependencies',
                 ['flutter', 'pub', 'get', '--enforce-lockfile'])
    run_step('Product build: website / notarized macOS', flutter_build_command())
    verify_website_defines()
    try:
        app = dist.find_release_app()
    except dist.DistributionError as error:
        raise BuildError(str(error)) from error
    print(f'Website macOS app: {app}')
    print('Billing: website redemption codes. Do not submit this binary to Mac App Store.')
    return 0


def main(argv=None):
    try:
        return execute(parser().parse_args(argv))
    except BuildError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
