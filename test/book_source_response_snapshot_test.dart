import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/caching/book_source_response_cache_io.dart'
    as io;
import 'package:xxread/book_sources/caching/book_source_response_cache_stub.dart'
    as web;

void main() {
  for (final platform in ['io', 'web']) {
    test('$platform snapshot age and invalidation match', () async {
      var now = DateTime.utc(2026, 9, 10);
      final dynamic cache = platform == 'io'
          ? io.BookSourceResponseCache(now: () => now)
          : web.BookSourceResponseCache(now: () => now);
      await cache.getOrLoadJson(
        key: 'snapshot',
        ttl: const Duration(minutes: 1),
        persistToDisk: false,
        loader: () async => <String, dynamic>{'value': 1},
      );
      now = now.add(const Duration(minutes: 2));
      expect(
        await cache.readCachedJson(
          key: 'snapshot',
          maxAge: const Duration(hours: 24),
          persistToDisk: false,
        ),
        {'value': 1},
      );
      await expectLater(
        cache.getOrLoadJson(
          key: 'snapshot',
          ttl: const Duration(minutes: 1),
          persistToDisk: false,
          loader: () async => throw StateError('offline'),
        ),
        throwsStateError,
      );
      expect(
        await cache.readCachedJson(
          key: 'snapshot',
          maxAge: const Duration(hours: 24),
          persistToDisk: false,
        ),
        {'value': 1},
      );
      now = now.add(const Duration(days: 1));
      expect(
        await cache.readCachedJson(
          key: 'snapshot',
          maxAge: const Duration(hours: 24),
          persistToDisk: false,
        ),
        isNull,
      );
      await cache.clear();
      expect(
        await cache.readCachedJson(
          key: 'snapshot',
          maxAge: const Duration(days: 2),
          persistToDisk: false,
        ),
        isNull,
      );
    });
  }
}
