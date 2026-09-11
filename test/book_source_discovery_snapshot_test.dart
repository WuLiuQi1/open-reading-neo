import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/caching/book_source_discovery_cache.dart';
import 'package:xxread/book_sources/caching/book_source_response_cache.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';

void main() {
  late Directory directory;
  late DateTime now;
  late BookSourceResponseCache responses;
  late BookSourceDiscoveryCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('discovery-snapshots-');
    now = DateTime.utc(2026, 9, 10);
    responses = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
    );
    cache = BookSourceDiscoveryCache(responseCache: responses);
  });
  tearDown(() async {
    await responses.flushPendingWrites();
    await directory.delete(recursive: true);
  });

  for (final protocol in BookSourceProtocolKind.values) {
    test('publishes stale categories before refresh for $protocol', () async {
      final source = _source(protocol);
      await cache.getCategories(source, () async => _categories('old'));
      await responses.flushPendingWrites();
      if (protocol == BookSourceProtocolKind.orsp) responses.clearMemory();
      now = now.add(const Duration(hours: 2));
      final refresh = Completer<List<BookSourceCategory>>();
      final snapshotReady = Completer<void>();
      final snapshots = <String>[];
      final pending = cache.getCategories(
        source,
        () => refresh.future,
        onCached: (items) {
          snapshots.add(items.single.id);
          snapshotReady.complete();
        },
      );
      await snapshotReady.future;
      expect(snapshots, ['old']);
      refresh.complete(_categories('new'));
      expect((await pending).single.id, 'new');
      expect(
        (await cache.getCategories(
          source,
          () => throw StateError('cache miss'),
        )).single.id,
        'new',
      );
    });
  }

  test(
    'browse and recommendation snapshots refresh their decoded books',
    () async {
      final source = _source(BookSourceProtocolKind.orsp);
      BookSourceBook book(String id) => BookSourceBook(
        id: id,
        title: id,
        author: '',
        description: '',
        categories: const [],
      );
      BookSourceSearchPage page(String id) => BookSourceSearchPage(
        items: [book(id)],
        page: 1,
        pageSize: 20,
        hasMore: false,
      );
      BookSourceDiscoveryPage discovery(String id) => BookSourceDiscoveryPage(
        sections: [
          BookSourceDiscoverySection(
            id: 'shelf',
            title: 'Shelf',
            items: [book(id)],
          ),
        ],
      );
      await cache.browse(
        source,
        category: 'all',
        sort: 'popular',
        page: 1,
        pageSize: 20,
        loader: () async => page('old'),
      );
      await cache.getDiscovery(source, () async => discovery('old'));
      now = now.add(const Duration(hours: 2));
      final snapshots = <String>[];
      final freshPage = await cache.browse(
        source,
        category: 'all',
        sort: 'popular',
        page: 1,
        pageSize: 20,
        loader: () async => page('new'),
        onCached: (value) => snapshots.add(value.items.single.id),
      );
      final freshDiscovery = await cache.getDiscovery(
        source,
        () async => discovery('new'),
        onCached: (value) =>
            snapshots.add(value.sections.single.items.single.id),
      );
      expect(snapshots, ['old', 'old']);
      expect(freshPage.items.single.id, 'new');
      expect(freshDiscovery.sections.single.items.single.id, 'new');
    },
  );

  test('failed refresh retains snapshot without renewing its age', () async {
    final source = _source(BookSourceProtocolKind.readingSource);
    await cache.getCategories(source, () async => _categories('old'));
    now = now.add(const Duration(hours: 2));
    for (var i = 0; i < 2; i++) {
      final result = await cache.getCategories(
        source,
        () async => throw const BookSourceProtocolException('offline'),
        onCached: (_) {},
      );
      expect(result.single.id, 'old');
    }
    now = now.add(const Duration(days: 1));
    var published = false;
    await expectLater(
      cache.getCategories(
        source,
        () async => throw const BookSourceProtocolException('offline'),
        onCached: (_) => published = true,
      ),
      throwsA(isA<BookSourceProtocolException>()),
    );
    expect(published, isFalse);
  });

  test(
    'programming and decoding failures are not hidden by a snapshot',
    () async {
      final source = _source(BookSourceProtocolKind.readingSource);
      await cache.getCategories(source, () async => _categories('old'));
      now = now.add(const Duration(hours: 2));
      for (final failure in [
        StateError('bug'),
        const FormatException('bad json'),
      ]) {
        await expectLater(
          cache.getCategories(
            source,
            () async => throw failure,
            onCached: (_) {},
          ),
          throwsA(same(failure)),
        );
      }
    },
  );

  test('private browse snapshots never survive a new cache instance', () async {
    final source = _source(BookSourceProtocolKind.readingSource);
    final page = BookSourceSearchPage(
      items: [
        BookSourceBook(
          id: 'private',
          title: 'Private',
          author: '',
          description: '',
          categories: const [],
          sourceVariables: const {'token': 'secret'},
        ),
      ],
      page: 1,
      pageSize: 20,
      hasMore: false,
    );
    await cache.browse(
      source,
      category: null,
      sort: 'popular',
      page: 1,
      pageSize: 20,
      loader: () async => page,
      onCached: (_) {},
    );
    await responses.flushPendingWrites();
    expect(await directory.list(recursive: true).toList(), isEmpty);
    final restarted = BookSourceDiscoveryCache(
      responseCache: BookSourceResponseCache(
        cacheDirectory: directory,
        now: () => now,
      ),
    );
    var published = false;
    await expectLater(
      restarted.browse(
        source,
        category: null,
        sort: 'popular',
        page: 1,
        pageSize: 20,
        loader: () async => throw const BookSourceProtocolException('offline'),
        onCached: (_) => published = true,
      ),
      throwsA(isA<BookSourceProtocolException>()),
    );
    expect(published, isFalse);
  });

  test(
    'disk snapshot expiry survives failed refresh and process restart',
    () async {
      final source = _source(BookSourceProtocolKind.orsp);
      await cache.getCategories(source, () async => _categories('old'));
      await responses.flushPendingWrites();
      now = now.add(const Duration(hours: 23));
      for (var attempt = 0; attempt < 2; attempt++) {
        final restartedResponses = BookSourceResponseCache(
          cacheDirectory: directory,
          now: () => now,
        );
        final restarted = BookSourceDiscoveryCache(
          responseCache: restartedResponses,
        );
        final result = restarted.getCategories(
          source,
          () async => throw const BookSourceProtocolException('offline'),
          onCached: (_) {},
        );
        if (attempt == 0) {
          expect((await result).single.id, 'old');
        } else {
          await expectLater(
            result,
            throwsA(isA<BookSourceProtocolException>()),
          );
        }
        await restartedResponses.flushPendingWrites();
        now = now.add(const Duration(hours: 1));
      }
    },
  );

  test(
    'invalidation removes snapshots and blocks stale refresh cache writes',
    () async {
      final source = _source(BookSourceProtocolKind.readingSource);
      await cache.getCategories(source, () async => _categories('old'));
      now = now.add(const Duration(hours: 2));
      final refresh = Completer<List<BookSourceCategory>>();
      final started = Completer<void>();
      final pending = cache.getCategories(source, () {
        started.complete();
        return refresh.future;
      }, onCached: (_) {});
      await started.future;
      await cache.invalidateSource(source);
      var published = false;
      final fresh = await cache.getCategories(
        source,
        () async => _categories('fresh'),
        onCached: (_) => published = true,
      );
      expect(published, isFalse);
      expect(fresh.single.id, 'fresh');
      refresh.complete(_categories('superseded'));
      await pending;
      expect(
        (await cache.getCategories(
          source,
          () => throw StateError('cache miss'),
        )).single.id,
        'fresh',
      );
    },
  );

  test(
    'each concurrent consumer receives a snapshot with one refresh',
    () async {
      final source = _source(BookSourceProtocolKind.readingSource);
      await cache.getCategories(source, () async => _categories('old'));
      now = now.add(const Duration(hours: 2));
      final refresh = Completer<List<BookSourceCategory>>();
      var loads = 0;
      final snapshots = <String>[];
      final ready = Completer<void>();
      Future<List<BookSourceCategory>> request() => cache.getCategories(
        source,
        () {
          loads++;
          return refresh.future;
        },
        onCached: (items) {
          snapshots.add(items.single.id);
          if (snapshots.length == 2) ready.complete();
        },
      );
      final first = request();
      final second = request();
      await ready.future;
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      refresh.complete(_categories('new'));
      expect((await first).single.id, 'new');
      expect((await second).single.id, 'new');
    },
  );
}

List<BookSourceCategory> _categories(String id) => [
  BookSourceCategory(id: id, name: id),
];
RegisteredBookSource _source(BookSourceProtocolKind protocol) =>
    RegisteredBookSource(
      id: 'snapshot-source',
      name: 'Snapshot',
      description: '',
      manifestUrl: Uri.parse('https://example.org/source.json'),
      apiBaseUrl: Uri.parse('https://example.org/api/'),
      protocolVersion: '1.5',
      languages: const [],
      capabilities: const {'categories', 'browse'},
      enabled: true,
      addedAt: DateTime.utc(2026, 9, 10),
      sourceProtocol: protocol,
    );
