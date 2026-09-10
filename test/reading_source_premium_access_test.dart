import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/protocol/reading_source/reading_source_backend.dart';
import 'package:xxread/book_sources/source_engine/source_login_ui.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/services/core/advanced_feature_access.dart';

void main() {
  test(
    'runtime checks membership on every operation despite saved opt-in',
    () async {
      SharedPreferences.setMockInitialValues({
        additionalSourceProtocolsPreferenceKey: true,
      });
      AdvancedFeatureAccess.premiumUnlocked = false;
      addTearDown(() => AdvancedFeatureAccess.premiumUnlocked = false);
      final runtime = _LoginRuntime();
      final backend = ReadingSourceBackend(() => runtime);
      final source = RegisteredBookSource(
        id: 'reading',
        name: 'Reading source',
        description: '',
        manifestUrl: Uri.parse('https://example.test/source.json'),
        apiBaseUrl: Uri.parse('https://example.test'),
        protocolVersion: '1.0',
        languages: const [],
        capabilities: const {'search'},
        enabled: true,
        addedAt: DateTime(2026),
        sourceProtocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {},
      );

      await expectLater(
        backend.loadLoginFields(source),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect(runtime.calls, 0);
      AdvancedFeatureAccess.premiumUnlocked = true;
      expect(await backend.loadLoginFields(source), isEmpty);
      expect(runtime.calls, 1);
      AdvancedFeatureAccess.premiumUnlocked = false;
      await expectLater(
        backend.loadLoginFields(source),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect(runtime.calls, 1);
    },
  );
}

class _LoginRuntime extends SourceRuntime {
  int calls = 0;

  @override
  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource source,
  ) async {
    calls++;
    return const [];
  }
}
