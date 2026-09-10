import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/core/changelog_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled catalog has the same complete history in every locale',
    () async {
      final service = ChangelogService();
      const locales = [
        Locale('en'),
        Locale('zh'),
        Locale('zh', 'TW'),
        Locale('ja'),
      ];

      final catalogs = await Future.wait(locales.map(service.load));
      final versions = catalogs.first.map((entry) => entry.version).toList();

      final currentIdentity = File('pubspec.yaml')
          .readAsLinesSync()
          .firstWhere((line) => line.startsWith('version:'))
          .substring('version:'.length)
          .trim();
      expect(versions.length, greaterThanOrEqualTo(55));
      expect(catalogs.first.first.identity, currentIdentity);
      expect(
        catalogs.first.map((entry) => entry.identity),
        containsAll(['2.6.7+260908001', '2.6.7+260907001']),
      );
      expect(
        versions,
        containsAll([
          '2.6.2',
          '2.6.1',
          '2.5.7',
          '2.5.6',
          '2.5.5',
          '2.5.4',
          '2.2.8',
          '2.2.3',
        ]),
      );
      for (final catalog in catalogs) {
        expect(catalog.map((entry) => entry.version), versions);
        expect(
          catalog.map((entry) => entry.identity),
          catalogs.first.map((entry) => entry.identity),
        );
        expect(catalog.every((entry) => entry.items.isNotEmpty), isTrue);
      }
    },
  );

  test('selects the exact locale and falls back to English', () {
    final source = jsonEncode({
      'schemaVersion': 1,
      'entries': [
        {
          'version': '9.1.0',
          'notes': {
            'en': ['English note'],
            'zh-TW': ['繁體中文說明'],
          },
        },
      ],
    });

    final traditional = ChangelogService.parse(
      source,
      const Locale('zh', 'TW'),
    );
    final fallback = ChangelogService.parse(source, const Locale('fr'));

    expect(traditional.single.items, ['繁體中文說明']);
    expect(fallback.single.items, ['English note']);
  });

  test('rejects duplicate versions', () {
    final source = jsonEncode({
      'schemaVersion': 1,
      'entries': [
        {
          'version': '9.1.0',
          'notes': {
            'en': ['First'],
          },
        },
        {
          'version': '9.1.0',
          'notes': {
            'en': ['Duplicate'],
          },
        },
      ],
    });

    expect(
      () => ChangelogService.parse(source, const Locale('en')),
      throwsFormatException,
    );
  });

  test('allows the same version with distinct build numbers', () {
    final source = jsonEncode({
      'schemaVersion': 1,
      'entries': [
        {
          'version': '9.1.0',
          'buildNumber': '102',
          'notes': {
            'en': ['Newer build'],
          },
        },
        {
          'version': '9.1.0',
          'buildNumber': '101',
          'notes': {
            'en': ['Older build'],
          },
        },
        {
          'version': '9.0.0',
          'notes': {
            'en': ['Historical release'],
          },
        },
      ],
    });

    final entries = ChangelogService.parse(source, const Locale('en'));

    expect(entries.map((entry) => entry.buildNumber), ['102', '101', null]);
  });

  test('rejects duplicate version and build number pairs', () {
    final source = jsonEncode({
      'schemaVersion': 1,
      'entries': [
        {
          'version': '9.1.0',
          'buildNumber': 102,
          'notes': {
            'en': ['First'],
          },
        },
        {
          'version': '9.1.0',
          'buildNumber': '102',
          'notes': {
            'en': ['Duplicate'],
          },
        },
      ],
    });

    expect(
      () => ChangelogService.parse(source, const Locale('en')),
      throwsFormatException,
    );
  });
}
