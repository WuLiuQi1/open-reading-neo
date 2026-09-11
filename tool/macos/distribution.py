#!/usr/bin/env python3
"""Shared macOS website vs Mac App Store dart-define checks."""
from __future__ import annotations

import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATED_XCCONFIG = ROOT / 'macos/Flutter/ephemeral/Flutter-Generated.xcconfig'
MACOS_APP_STORE_KEY = 'OPEN_READING_MACOS_APP_STORE'
MACOS_APP_STORE_VALUE = 'true'
MACOS_APP_STORE_ASSIGNMENT = f'{MACOS_APP_STORE_KEY}={MACOS_APP_STORE_VALUE}'
MACOS_APP_STORE_DART_DEFINE = f'--dart-define={MACOS_APP_STORE_ASSIGNMENT}'
MACOS_WEBSITE_ASSIGNMENT = f'{MACOS_APP_STORE_KEY}=false'
MACOS_WEBSITE_DART_DEFINE = f'--dart-define={MACOS_WEBSITE_ASSIGNMENT}'


class DistributionError(Exception):
    pass


def encode_dart_define(assignment):
    return base64.b64encode(assignment.encode('utf-8')).decode('ascii')


def parse_dart_defines(raw):
    defines = {}
    for part in raw.split(','):
        token = part.strip()
        if not token:
            continue
        padding = '=' * (-len(token) % 4)
        try:
            decoded = base64.b64decode(token + padding, validate=True).decode('utf-8')
        except (ValueError, UnicodeDecodeError) as error:
            raise DistributionError('DART_DEFINES contains an invalid token') from error
        key, separator, value = decoded.partition('=')
        if not key or not separator:
            raise DistributionError(f'DART_DEFINES token is not KEY=VALUE: {decoded}')
        defines[key] = value
    return defines


def dart_defines_from_xcconfig(path):
    try:
        text = Path(path).read_text()
    except OSError as error:
        raise DistributionError(f'Unable to read Flutter generated xcconfig: {path}') from error
    for line in text.splitlines():
        if line.startswith('DART_DEFINES='):
            return parse_dart_defines(line.split('=', 1)[1])
    raise DistributionError(f'{path} does not contain DART_DEFINES')


def read_generated_dart_defines():
    return dart_defines_from_xcconfig(GENERATED_XCCONFIG)


def macos_app_store_enabled(defines):
    return defines.get(MACOS_APP_STORE_KEY) == MACOS_APP_STORE_VALUE


def command_has_macos_app_store_define(command):
    return any(
        argument == MACOS_APP_STORE_DART_DEFINE
        or argument == MACOS_APP_STORE_ASSIGNMENT
        or argument.endswith(MACOS_APP_STORE_ASSIGNMENT)
        for argument in command
    )


def assert_website_distribution(defines):
    if macos_app_store_enabled(defines):
        raise DistributionError(
            'Website / notarized macOS builds must not set '
            f'{MACOS_APP_STORE_ASSIGNMENT}; that define is only for Mac App Store'
        )
    if defines.get(MACOS_APP_STORE_KEY) != 'false':
        raise DistributionError(
            f'Website / notarized macOS builds require {MACOS_WEBSITE_ASSIGNMENT}'
        )


def assert_app_store_distribution(defines):
    if not macos_app_store_enabled(defines):
        raise DistributionError(
            'Mac App Store builds must set '
            f'{MACOS_APP_STORE_ASSIGNMENT} so StoreKit billing is compiled in'
        )


def find_release_app(products_dir=None):
    root = Path(products_dir) if products_dir else ROOT / 'build/macos/Build/Products/Release'
    apps = [path for path in root.glob('*.app') if path.is_dir()]
    if len(apps) != 1:
        raise DistributionError(f'Release directory must contain exactly one .app: {root}')
    return apps[0]
