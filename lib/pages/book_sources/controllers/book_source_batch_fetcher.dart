import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';

/// Concurrent per-source fetch with a bounded worker pool.
///
/// Successful batches keep source order. Failed sources are dropped when any
/// other source returned items; if every batch is empty and at least one
/// source failed, the joined errors are thrown as [BookSourceProtocolException].
class BookSourceBatchFetcher {
  const BookSourceBatchFetcher({required this.maxConcurrent});

  final int maxConcurrent;

  Future<List<List<T>>> fetch<T>(
    List<RegisteredBookSource> sources,
    Future<List<T>> Function(RegisteredBookSource source) fetch,
  ) => fetchProgressively(
    sources,
    (source, _) => fetch(source),
    onProgress: (_, _) {},
  );

  Future<List<List<T>>> fetchProgressively<T>(
    List<RegisteredBookSource> sources,
    Future<List<T>> Function(
      RegisteredBookSource source,
      void Function(List<T> items) publish,
    )
    fetch, {
    required void Function(RegisteredBookSource source, List<T> items)
    onProgress,
  }) async {
    if (sources.isEmpty) return const [];
    final results = List<_SourceFetchResult<T>?>.filled(sources.length, null);
    final publishedItems = <int, List<T>>{};
    var nextIndex = 0;

    void publish(int sourceIndex, List<T> items) {
      final frozenItems = List<T>.unmodifiable(items);
      publishedItems[sourceIndex] = frozenItems;
      onProgress(sources[sourceIndex], frozenItems);
    }

    Future<void> worker() async {
      while (nextIndex < sources.length) {
        final index = nextIndex++;
        final source = sources[index];
        try {
          final items = await fetch(source, (items) => publish(index, items));
          results[index] = _SourceFetchResult.success(source, items);
          publish(index, items);
        } catch (error) {
          final cachedItems = publishedItems[index];
          results[index] = cachedItems != null && cachedItems.isNotEmpty
              ? _SourceFetchResult.success(source, cachedItems)
              : _SourceFetchResult.failure(source, error);
        }
      }
    }

    await Future.wait(
      List.generate(sources.length.clamp(1, maxConcurrent), (_) => worker()),
    );
    final completed = results.whereType<_SourceFetchResult<T>>().toList(
      growable: false,
    );
    final batches = completed
        .where((result) => result.error == null)
        .map((result) => result.items)
        .toList(growable: false);
    final failures = completed.where((result) => result.error != null).toList();
    if (!batches.any((items) => items.isNotEmpty) && failures.isNotEmpty) {
      throw BookSourceProtocolException(
        failures
            .map((failure) => '${failure.source.name}: ${failure.error}')
            .join('\n'),
      );
    }
    return batches;
  }
}

/// Replaces one source's visible batch while retaining the order in which
/// sources first became visible.
class SourceBatchAccumulator<T> {
  SourceBatchAccumulator(Iterable<T> initial, this.sourceIdOf) {
    for (final item in initial) {
      final sourceId = sourceIdOf(item);
      if (!_itemsBySource.containsKey(sourceId)) _sourceOrder.add(sourceId);
      (_itemsBySource[sourceId] ??= <T>[]).add(item);
    }
  }

  final String Function(T item) sourceIdOf;
  final List<String> _sourceOrder = [];
  final Map<String, List<T>> _itemsBySource = {};

  void replace(String sourceId, List<T> items) {
    if (!_sourceOrder.contains(sourceId) && items.isNotEmpty) {
      _sourceOrder.add(sourceId);
    }
    _itemsBySource[sourceId] = List.unmodifiable(items);
  }

  List<T> get items => List.unmodifiable(
    _sourceOrder.expand((sourceId) => _itemsBySource[sourceId] ?? <T>[]),
  );
}

class _SourceFetchResult<T> {
  final RegisteredBookSource source;
  final List<T> items;
  final Object? error;

  const _SourceFetchResult.success(this.source, this.items) : error = null;

  const _SourceFetchResult.failure(this.source, this.error) : items = const [];
}
