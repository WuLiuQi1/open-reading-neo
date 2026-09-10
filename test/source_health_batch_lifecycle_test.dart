import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

void main() {
  test(
    'batch health checks release interleaved script engines',
    () async {
      await BookSourceRegistry.resetForTesting();
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = null;
        await BookSourceRegistry.resetForTesting();
      });
      const count = int.fromEnvironment(
        'SOURCE_HEALTH_STRESS_COUNT',
        defaultValue: 30,
      );
      final sources = List.generate(
        count,
        (index) => ReadingSourceConfig.fromJson({
          'bookSourceName': 'Lifecycle $index',
          'bookSourceUrl': 'https://source-$index.test',
          'searchUrl': "@js:cache.put('owner', source.getKey()); '/search'",
          'ruleSearch': {
            'bookList': 'class.book',
            // This runs after other engines have started or finished. A host
            // callback routed to a different engine cannot produce a candidate.
            'name': "@js:cache.get('owner') === source.getKey() ? 'Book' : ''",
            'bookUrl': 'tag.a@href',
          },
          'ruleBookInfo': {'name': 'h1@text', 'tocUrl': 'a@href'},
          'ruleToc': {
            'chapterList': 'li',
            'chapterName': 'a@text',
            'chapterUrl': 'a@href',
          },
          'ruleContent': {'content': 'article@text'},
        }).toRegisteredSource(enabled: true),
      );
      final registry = BookSourceRegistry(storage: _MemoryStorage());
      await registry.upsertAll(sources);
      final transport = _InterleavedTransport();
      final service = BookSourceHealthCheckService(
        registry: registry,
        checker: SourceHealthChecker(transport: transport),
      );
      var completed = 0;
      final results = await service.checkAllForCleanup(
        sources,
        onProgress: (value, total) {
          expect(value, greaterThanOrEqualTo(completed));
          expect(total, count);
          completed = value;
        },
      );
      expect(completed, count);
      expect(results, hasLength(count));
      expect(transport.requests, count * 4);
      for (final result in results) {
        expect(
          sourceHealthCheckResultOf(result)?.healthy,
          isTrue,
          reason: result.id,
        );
        expect(
          sourceHealthCheckResultOf(result)?.checked,
          containsAll([
            SourceHealthCapability.search,
            SourceHealthCapability.info,
            SourceHealthCapability.catalog,
            SourceHealthCapability.content,
          ]),
        );
      }
      expect(
        (await registry.load()).where(
          (source) => sourceHealthCheckResultOf(source)?.healthy == true,
        ),
        hasLength(count),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

class _InterleavedTransport implements SourceTransport {
  int requests = 0;

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests++;
    await Future<void>.delayed(Duration.zero);
    cancellation?.throwIfCancelled();
    final body = switch (request.url.path) {
      '/search' => '<div class="book"><a href="/book">Book</a></div>',
      '/book' => '<h1>Book</h1><a href="/toc">Catalog</a>',
      '/toc' => '<li><a href="/chapter">Chapter</a></li>',
      '/chapter' => '<article>Chapter content</article>',
      _ => throw StateError('Unexpected URL: ${request.url}'),
    };
    return SourceResponse(body: body, finalUri: request.url);
  }
}

class _MemoryStorage implements BookSourceRegistryStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<bool> write(String value) async {
    this.value = value;
    return true;
  }
}
