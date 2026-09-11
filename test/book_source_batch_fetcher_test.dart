import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_batch_fetcher.dart';

void main() {
  test('returns an empty list when there are no sources', () async {
    final fetcher = BookSourceBatchFetcher(maxConcurrent: 8);

    expect(await fetcher.fetch(const [], (_) async => ['item']), isEmpty);
  });

  test(
    'keeps source order and drops a failed source when others succeed',
    () async {
      final sources = [_source('a'), _source('b'), _source('c')];
      final fetcher = BookSourceBatchFetcher(maxConcurrent: 8);

      final batches = await fetcher.fetch(sources, (source) async {
        if (source.id == 'b') throw StateError('offline');
        return [source.id];
      });

      expect(batches, [
        ['a'],
        ['c'],
      ]);
    },
  );

  test('throws joined protocol errors when every source fails', () async {
    final sources = [_source('alpha'), _source('beta')];
    final fetcher = BookSourceBatchFetcher(maxConcurrent: 2);

    expect(
      () => fetcher.fetch(sources, (source) async {
        throw StateError('${source.id} down');
      }),
      throwsA(
        isA<BookSourceProtocolException>().having(
          (error) => error.message,
          'message',
          'alpha: Bad state: alpha down\nbeta: Bad state: beta down',
        ),
      ),
    );
  });

  test(
    'throws when every successful batch is empty and another source failed',
    () async {
      final sources = [_source('empty'), _source('broken')];
      final fetcher = BookSourceBatchFetcher(maxConcurrent: 2);

      expect(
        () => fetcher.fetch(sources, (source) async {
          if (source.id == 'broken') throw StateError('timeout');
          return const <String>[];
        }),
        throwsA(isA<BookSourceProtocolException>()),
      );
    },
  );

  test('bounds concurrent source requests', () async {
    final sources = List.generate(12, (index) => _source('source-$index'));
    final fetcher = BookSourceBatchFetcher(maxConcurrent: 3);
    var active = 0;
    var maxActive = 0;

    await fetcher.fetch(sources, (source) async {
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 8));
      active--;
      return [source.id];
    });

    expect(maxActive, lessThanOrEqualTo(3));
  });

  test(
    'publishes completed sources immediately and keeps their visible order stable',
    () async {
      final sources = [_source('slow'), _source('fast')];
      final slow = Completer<List<String>>();
      final fast = Completer<List<String>>();
      final updates = <List<List<String>>>[];
      final visibleOrder = <String>[];
      final visibleItems = <String, List<String>>{};
      final fetcher = BookSourceBatchFetcher(maxConcurrent: 2);

      final pending = fetcher.fetchProgressively<String>(
        sources,
        (source, publish) => source.id == 'slow' ? slow.future : fast.future,
        onProgress: (source, items) {
          if (!visibleItems.containsKey(source.id) && items.isNotEmpty) {
            visibleOrder.add(source.id);
          }
          visibleItems[source.id] = items;
          updates.add([
            for (final id in visibleOrder)
              if (visibleItems[id]!.isNotEmpty) List.of(visibleItems[id]!),
          ]);
        },
      );
      fast.complete(['fast']);
      await Future<void>.delayed(Duration.zero);

      expect(updates, [
        [
          ['fast'],
        ],
      ]);

      slow.complete(['slow']);
      await pending;

      expect(updates.last, [
        ['fast'],
        ['slow'],
      ]);
    },
  );

  test(
    'replaces one source snapshot without moving other source slots',
    () async {
      final sources = [_source('cached'), _source('other')];
      final cachedFresh = Completer<List<String>>();
      final otherFresh = Completer<List<String>>();
      final updates = <List<List<String>>>[];
      final visibleOrder = <String>[];
      final visibleItems = <String, List<String>>{};
      final fetcher = BookSourceBatchFetcher(maxConcurrent: 2);

      final pending = fetcher.fetchProgressively<String>(
        sources,
        (source, publish) {
          if (source.id == 'cached') {
            publish(['cached-old']);
            return cachedFresh.future;
          }
          publish(['other-old']);
          return otherFresh.future;
        },
        onProgress: (source, items) {
          if (!visibleItems.containsKey(source.id) && items.isNotEmpty) {
            visibleOrder.add(source.id);
          }
          visibleItems[source.id] = items;
          updates.add([
            for (final id in visibleOrder)
              if (visibleItems[id]!.isNotEmpty) List.of(visibleItems[id]!),
          ]);
        },
      );
      await Future<void>.delayed(Duration.zero);
      otherFresh.complete(['other-new']);
      await Future<void>.delayed(Duration.zero);
      cachedFresh.complete(['cached-new']);
      await pending;

      expect(updates.last, [
        ['cached-new'],
        ['other-new'],
      ]);
    },
  );

  test('an empty snapshot does not hide a later non-empty result', () {
    final accumulator = SourceBatchAccumulator<String>(
      const [],
      (_) => 'source',
    );

    accumulator.replace('source', const []);
    accumulator.replace('source', ['fresh']);

    expect(accumulator.items, ['fresh']);
  });
}

RegisteredBookSource _source(String id, {String? name}) => RegisteredBookSource(
  id: id,
  name: name ?? id,
  description: '',
  manifestUrl: Uri.parse('https://example.org/$id/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/$id/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'discover', 'categories', 'browse'},
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 9),
);
