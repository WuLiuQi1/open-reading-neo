import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/diagnose_source_samples.dart' as diagnostic;

void main() {
  test(
    'runs opt-in reading source samples through the complete chain',
    () async {
      final files = Platform.environment['SOURCE_SAMPLE_FILES']
          ?.split(Platform.isWindows ? ';' : ':')
          .where((path) => path.trim().isNotEmpty)
          .toList();
      if (files == null || files.isEmpty) return;

      // This opt-in diagnostic intentionally uses real HTTP. Initialize
      // channels so unavailable native WebView plugins report that boundary,
      // rather than an unrelated missing Flutter binding error.
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;

      final perKind = Platform.environment['SOURCE_SAMPLES_PER_KIND'] ?? '3';
      final stageSeconds =
          Platform.environment['SOURCE_SAMPLE_STAGE_SECONDS'] ?? '15';
      await diagnostic.main([
        if (Platform.environment['SOURCE_SAMPLE_STATIC_ONLY'] == 'true')
          '--static-only',
        '--per-kind=$perKind',
        '--stage-seconds=$stageSeconds',
        '--content-kind=${Platform.environment['SOURCE_SAMPLE_CONTENT_KIND'] ?? 'all'}',
        ...files,
      ]);
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
