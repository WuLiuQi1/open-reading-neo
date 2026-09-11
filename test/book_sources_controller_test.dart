import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/services/core/advanced_feature_access.dart';

void main() {
  test(
    'membership restoration refreshes sources without registry edits',
    () async {
      AdvancedFeatureAccess.premiumUnlocked = false;
      final orsp = _source('orsp');
      final reading = _source(
        'reading',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final registry = _FakeRegistry([
        Future.value([orsp]),
        Future.value([orsp, reading]),
        Future.value([orsp]),
      ]);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: registry,
      );
      addTearDown(() async {
        await controller.close();
        gateway.close();
        AdvancedFeatureAccess.premiumUnlocked = false;
      });
      controller.setListLayout(true);
      await controller.load();
      expect(controller.state.sources.map((s) => s.id), ['orsp']);

      Future<void> expectSources(List<String> ids) async {
        final refreshed = Completer<void>();
        void listener() {
          if (!controller.state.loadingSources && !refreshed.isCompleted) {
            refreshed.complete();
          }
        }

        controller.addListener(listener);
        await refreshed.future.timeout(const Duration(seconds: 2));
        controller.removeListener(listener);
        expect(controller.state.sources.map((s) => s.id), ids);
      }

      AdvancedFeatureAccess.premiumUnlocked = true;
      await expectSources(['orsp', 'reading']);
      AdvancedFeatureAccess.premiumUnlocked = true;
      expect(registry._loadIndex, 2);
      AdvancedFeatureAccess.premiumUnlocked = false;
      await expectSources(['orsp']);
      await controller.close();
      AdvancedFeatureAccess.premiumUnlocked = true;
      expect(registry._loadIndex, 3);
    },
  );

  test(
    'late startup load cannot overwrite restored membership sources',
    () async {
      AdvancedFeatureAccess.premiumUnlocked = false;
      final stale = Completer<List<RegisteredBookSource>>();
      final orsp = _source('orsp');
      final reading = _source(
        'reading',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final registry = _FakeRegistry([
        stale.future,
        Future.value([orsp, reading]),
      ]);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: registry,
      );
      addTearDown(() async {
        await controller.close();
        gateway.close();
        AdvancedFeatureAccess.premiumUnlocked = false;
      });
      controller.setListLayout(true);
      final pending = controller.load();
      final restored = Completer<void>();
      controller.addListener(() {
        if (!controller.state.loadingSources && !restored.isCompleted) {
          restored.complete();
        }
      });
      AdvancedFeatureAccess.premiumUnlocked = true;
      await restored.future.timeout(const Duration(seconds: 2));
      stale.complete([orsp]);
      await pending;
      expect(controller.state.sources.map((s) => s.id), ['orsp', 'reading']);
    },
  );

  test(
    'large library metadata comparisons preserve the current source',
    () async {
      final sources = List.generate(41, (index) => _source('source-$index'));
      final registry = _FakeRegistry([
        Future.value(sources),
        Future.value([
          sources.first.copyWith(isFavorite: true),
          ...sources.skip(1),
        ]),
      ]);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: registry,
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      await controller.load();
      final cache = controller.state.caches[controller.state.section];
      await controller.refreshSourceMetadata();
      expect(controller.state.sources.first.isFavorite, isTrue);
      expect(controller.state.selectedSourceId, 'source-0');
      expect(controller.state.caches[controller.state.section], same(cache));
      expect(gateway.discoveryIds, ['source-0']);
    },
  );

  test('deleting the active group returns to all sources', () async {
    final source = _source('source').copyWith(groups: ['My sources']);
    final registry = _FakeRegistry([
      Future.value([source]),
      Future.value([source.copyWith(groups: [])]),
    ]);
    final gateway = _ControllerGateway();
    final controller = BookSourcesController(
      gateway: gateway,
      registry: registry,
    );
    addTearDown(controller.close);
    addTearDown(gateway.close);
    await controller.load();
    await controller.changeOrganizationScope(group: 'My sources');
    await controller.refreshSourceMetadata();
    expect(controller.state.selectedGroup, isNull);
    expect(controller.state.organizedDiscoverySources.single.id, 'source');
  });

  test(
    'organizing a source in another section preserves the active cache',
    () async {
      final source = _source('orsp').copyWith(isFavorite: true);
      final reading = _source(
        'reading',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final registry = _FakeRegistry([
        Future.value([source, reading]),
        Future.value([source, reading.copyWith(isFavorite: true)]),
      ]);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: registry,
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      await controller.load();
      await controller.changeOrganizationScope(favoritesOnly: true);
      await controller.changeSection(BookSourcesSection.latest);
      final cache = controller.state.caches[BookSourcesSection.latest];
      final requests = gateway.browseIds.length;
      await controller.refreshSourceMetadata();
      expect(controller.state.caches[BookSourcesSection.latest], same(cache));
      expect(gateway.browseIds.length, requests);
      expect(
        controller.state.sourcesFor(BookSourcesSection.categories),
        hasLength(2),
      );
    },
  );

  test(
    'removing another favorite preserves the active category without fetching',
    () async {
      final a = _source('a').copyWith(isFavorite: true);
      final b = _source('b').copyWith(isFavorite: true);
      final registry = _FakeRegistry([
        Future.value([a, b]),
        Future.value([a, b.copyWith(isFavorite: false)]),
      ]);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: registry,
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      await controller.load();
      await controller.changeOrganizationScope(favoritesOnly: true);
      await controller.changeSection(BookSourcesSection.categories);
      await Future<void>.delayed(Duration.zero);
      final category = controller.state.selectedCategory;
      final cache = controller.state.caches[BookSourcesSection.categories];
      final requests = gateway.browseIds.length;
      await controller.refreshSourceMetadata();
      expect(controller.state.selectedCategory, category);
      expect(
        controller.state.caches[BookSourcesSection.categories],
        same(cache),
      );
      expect(gateway.browseIds.length, requests);
      expect(controller.state.organizedDiscoverySources.single.id, 'a');
    },
  );

  test(
    'organization scopes filter every section and survive layout changes',
    () async {
      final favorite = _source(
        'favorite',
      ).copyWith(isFavorite: true, groups: ['漫画']);
      final other = _source('other').copyWith(groups: ['备用']);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([favorite, other]),
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      await controller.load();
      await controller.changeOrganizationScope(favoritesOnly: true);
      for (final section in BookSourcesSection.values) {
        expect(controller.state.scopedSourcesFor(section), [favorite]);
      }
      await controller.changeSection(BookSourcesSection.latest);
      expect(
        controller.state.caches[BookSourcesSection.latest]!.books!.map(
          (book) => book.source.id,
        ),
        everyElement('favorite'),
      );
      controller.setListLayout(true);
      expect(
        controller.state.listSourceGroups.map((group) => group.source.id),
        ['favorite'],
      );
      await controller.changeOrganizationScope(group: '备用');
      expect(controller.state.favoritesOnly, isFalse);
      expect(controller.state.listSourceGroups.single.source.id, 'other');
      controller.setListLayout(false);
      expect(controller.state.selectedGroup, '备用');
      await controller.changeOrganizationScope(group: '空分组');
      expect(controller.state.organizedDiscoverySources, isEmpty);
      expect(controller.state.availableSections, isEmpty);
      expect(
        controller.state.caches[controller.state.section]!.categories,
        isEmpty,
      );
    },
  );

  test(
    'favorite and group metadata updates preserve selected category and cached content',
    () async {
      final source = _source('source');
      final updated = source.copyWith(isFavorite: true, groups: ['常用']);
      final registry = _FakeRegistry([
        Future.value([source]),
        Future.value([updated]),
      ]);
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: registry,
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      await controller.load();
      await controller.changeSourceScope(source.id);
      await controller.changeSection(BookSourcesSection.categories);
      await Future<void>.delayed(Duration.zero);
      final category = controller.state.selectedCategory;
      final books = controller.state.categoryBooks;
      final cache = controller.state.caches[BookSourcesSection.categories];
      final requests = gateway.browseIds.length;
      await controller.refreshSourceMetadata();
      expect(controller.state.sources.single.isFavorite, isTrue);
      expect(controller.state.sources.single.groups, ['常用']);
      expect(controller.state.selectedSourceId, source.id);
      expect(controller.state.selectedCategory, category);
      expect(controller.state.categoryBooks, books);
      expect(
        controller.state.caches[BookSourcesSection.categories],
        same(cache),
      );
      expect(gateway.browseIds.length, requests);
      expect(controller.state.loadingSources, isFalse);
    },
  );

  test('metadata updates do not cancel an in-flight channel request', () async {
    final source = _source('source');
    final response = Completer<BookSourceSearchPage>();
    final registry = _FakeRegistry([
      Future.value([source]),
      Future.value([source.copyWith(isFavorite: true)]),
    ]);
    final gateway = _ControllerGateway(browseResults: [response.future]);
    final controller = BookSourcesController(
      gateway: gateway,
      registry: registry,
    );
    addTearDown(controller.close);
    addTearDown(gateway.close);
    await controller.load();
    await controller.changeSection(BookSourcesSection.categories);
    expect(controller.state.loadingCategoryBooks, isTrue);
    await controller.refreshSourceMetadata();
    response.complete(_page([_book('loaded')]));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.categoryBooks.single.book.id, 'loaded');
    expect(controller.state.sources.single.isFavorite, isTrue);
  });

  test('state freezes nested source and channel collections', () {
    final source = _source('source');
    final category = SourcedBookCategory(
      source: source,
      id: 'category',
      name: 'Category',
    );
    final sectionSources = <BookSourcesSection, List<RegisteredBookSource>>{
      BookSourcesSection.categories: [source],
    };
    final channels = <String, List<SourcedBookCategory>>{
      source.id: [category],
    };

    final state = BookSourcesState(
      sectionSources: sectionSources,
      listChannelsBySource: channels,
    );
    sectionSources[BookSourcesSection.categories]!.clear();
    channels[source.id]!.clear();

    expect(state.sourcesFor(BookSourcesSection.categories), [source]);
    expect(state.listChannelsBySource[source.id], [category]);
    expect(
      () => state.sourcesFor(BookSourcesSection.categories).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => state.listChannelsBySource[source.id]!.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'indexes capabilities and scopes large libraries before fetching',
    () async {
      final sources = List.generate(
        41,
        (index) => _source('source-$index'),
        growable: false,
      );
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
      );

      await controller.load();

      expect(controller.state.discoverySources, hasLength(41));
      expect(controller.state.selectedSourceId, 'source-0');
      expect(gateway.discoveryIds, ['source-0']);
      expect(controller.state.sourcesFor(BookSourcesSection.latest), sources);
      await controller.close();
    },
  );

  test(
    'reading sources expose their channels instead of ORSP sections',
    () async {
      final comic = _source(
        'comic',
        protocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {'bookSourceType': 2},
      );
      final text = _source(
        'text',
        protocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {'bookSourceType': 0},
      );
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([comic, text]),
      );

      await controller.load();

      expect(controller.state.sourcesFor(BookSourcesSection.latest), isEmpty);
      expect(
        controller.state.sourcesFor(BookSourcesSection.recommended),
        isEmpty,
      );
      expect(controller.state.sourcesFor(BookSourcesSection.categories), [
        comic,
        text,
      ]);
      expect(controller.state.availableSections, [
        BookSourcesSection.categories,
      ]);
      expect(controller.state.section, BookSourcesSection.categories);
      expect(gateway.discoveryIds, isEmpty);
      expect(gateway.browseCategories, ['category']);
      await controller.changeSection(BookSourcesSection.latest);
      expect(controller.state.section, BookSourcesSection.categories);
      await controller.changeSourceScope('text');
      expect(controller.state.selectedCategory?.source.id, 'text');
      expect(gateway.browseIds, ['comic', 'text']);
      expect(gateway.browseCategories, everyElement(isNotNull));
      await controller.close();
    },
  );

  test(
    'mixed libraries reserve recommended and latest for ORSP sources',
    () async {
      final orsp = _source('orsp');
      final reading = _source(
        'reading',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([orsp, reading]),
      );
      await controller.load();
      expect(controller.state.discoverySources, [orsp, reading]);
      expect(controller.state.availableSections, BookSourcesSection.values);
      expect(gateway.discoveryIds, ['orsp']);
      await controller.changeSection(BookSourcesSection.latest);
      expect(gateway.browseIds, ['orsp']);
      expect(gateway.browseCategories, [null]);
      await controller.changeSourceScope('reading');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.availableSections, [
        BookSourcesSection.categories,
      ]);
      expect(controller.state.categoryBooks.single.source.id, 'reading');
      expect(gateway.browseCategories.last, 'category');
      await controller.changeSourceScope('orsp');
      expect(controller.state.availableSections, BookSourcesSection.values);
      await controller.changeSection(BookSourcesSection.latest);
      expect(gateway.browseIds.last, 'orsp');
      await controller.close();
    },
  );

  test(
    'listGroupsRevision bumps only on a real load or channel fetch, not on unrelated updates',
    () async {
      final sources = [_source('a'), _source('b')];
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
      );

      await controller.load();
      final afterLoad = controller.state.listGroupsRevision;
      expect(afterLoad, greaterThan(0));

      // Memoized callers (the discover list view) key their cache on this
      // revision, so an unrelated state change — like typing into the
      // source search box — must leave it untouched, or the whole point of
      // memoizing is defeated.
      controller.setListSourceQuery('a');
      expect(controller.state.listGroupsRevision, afterLoad);

      final group = BookSourceListChannels(
        source: sources.first,
        channels: const [],
      );
      await controller.expandListSource(group);
      expect(controller.state.listGroupsRevision, greaterThan(afterLoad));

      await controller.close();
    },
  );

  test(
    'bounds concurrent source requests and preserves partial results',
    () async {
      final sources = List.generate(
        20,
        (index) => _source('source-$index'),
        growable: false,
      );
      final gateway = _ControllerGateway(failingIds: {'source-3'});
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
        largeSourceLibraryThreshold: 100,
      );

      await controller.load();

      final cache = controller.state.caches[BookSourcesSection.recommended]!;
      expect(cache.error, isNull);
      expect(cache.shelves, hasLength(19));
      expect(gateway.maxActive, lessThanOrEqualTo(8));
      await controller.close();
    },
  );

  test(
    'publishes a fast discovery source before a slow source finishes',
    () async {
      final slow = Completer<BookSourceDiscoveryPage>();
      final fast = Completer<BookSourceDiscoveryPage>();
      final gateway = _ControllerGateway(
        discoveryResults: [slow.future, fast.future],
      );
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([_source('slow'), _source('fast')]),
        largeSourceLibraryThreshold: 100,
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);

      final load = controller.load();
      while (gateway.discoveryIds.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
      fast.complete(_discoveryPage('fast'));
      await Future<void>.delayed(Duration.zero);

      var cache = controller.state.caches[BookSourcesSection.recommended]!;
      expect(cache.complete, isFalse);
      expect(cache.shelves!.map((item) => item.source.id), ['fast']);

      slow.complete(_discoveryPage('slow'));
      await load;

      cache = controller.state.caches[BookSourcesSection.recommended]!;
      expect(cache.complete, isTrue);
      expect(cache.shelves!.map((item) => item.source.id), ['fast', 'slow']);
    },
  );

  test(
    'leaving list layout loads channels from sources not yet expanded',
    () async {
      final sources = [_source('a'), _source('b')];
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      controller.setListLayout(true);
      await controller.load();
      await controller.expandListSource(
        BookSourceListChannels(source: sources.first, channels: const []),
      );
      expect(
        controller.state.caches[BookSourcesSection.categories]!.categories!.map(
          (item) => item.source.id,
        ),
        ['a'],
      );
      controller.setListLayout(false);
      await Future<void>.delayed(Duration.zero);
      final cache = controller.state.caches[BookSourcesSection.categories]!;
      expect(cache.complete, isTrue);
      expect(cache.categories!.map((item) => item.source.id), ['a', 'b']);
    },
  );

  test(
    'latest keeps visible source order and caps each contribution',
    () async {
      final slow = Completer<BookSourceSearchPage>();
      final fast = Completer<BookSourceSearchPage>();
      final gateway = _ControllerGateway(
        browseResults: [slow.future, fast.future],
      );
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([_source('slow'), _source('fast')]),
        maxLatestItemsPerSource: 1,
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);
      await controller.load();
      final load = controller.changeSection(BookSourcesSection.latest);
      expect(gateway.browseIds, ['slow', 'fast']);
      fast.complete(_page([_book('fast-1'), _book('fast-2')]));
      await Future<void>.delayed(Duration.zero);
      final partial = controller.state.caches[BookSourcesSection.latest]!;
      expect(partial.complete, isFalse);
      expect(partial.books!.map((item) => item.book.id), ['fast-1']);
      slow.complete(_page([_book('slow-1'), _book('slow-2')]));
      await load;
      final complete = controller.state.caches[BookSourcesSection.latest]!;
      expect(complete.complete, isTrue);
      expect(complete.books!.map((item) => item.book.id), ['fast-1', 'slow-1']);
    },
  );

  test(
    'a failed refresh preserves the previously visible discovery content',
    () async {
      final failedRefresh = Completer<BookSourceDiscoveryPage>();
      final gateway = _ControllerGateway(
        discoveryResults: [
          Future.value(_discoveryPage('visible')),
          failedRefresh.future,
        ],
      );
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([_source('source')]),
      );
      addTearDown(controller.close);
      addTearDown(gateway.close);

      await controller.load();
      final refresh = controller.refresh();
      while (gateway.discoveryIds.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
      failedRefresh.completeError(StateError('offline'));
      await refresh;

      final cache = controller.state.caches[BookSourcesSection.recommended]!;
      expect(cache.error, isNull);
      expect(cache.shelves!.single.items.single.id, 'visible');
    },
  );

  test(
    'cached category books render before refresh and cannot page early',
    () async {
      final fresh = Completer<BookSourceSearchPage>();
      final gateway = _ControllerGateway(
        browseResults: [fresh.future],
        cachedBrowseResults: [
          _page([_book('cached')], hasMore: true),
        ],
      );
      final controller = BookSourcesController(gateway: gateway);
      addTearDown(controller.close);
      addTearDown(gateway.close);
      final category = SourcedBookCategory(
        source: _source('source'),
        id: 'category',
        name: 'Category',
      );

      final pending = controller.selectCategory(category);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.loadingCategoryBooks, isFalse);
      expect(controller.state.categoryBooks.single.book.id, 'cached');
      expect(controller.state.categoryHasMore, isFalse);

      await controller.loadMoreCategory();
      expect(gateway.browseIds, hasLength(1));

      fresh.complete(_page([_book('fresh')], hasMore: true));
      await pending;
      expect(controller.state.categoryBooks.single.book.id, 'fresh');
      expect(controller.state.categoryHasMore, isTrue);
    },
  );

  test(
    'registry load failure leaves discovery in a retryable error state',
    () async {
      final controller = BookSourcesController(
        gateway: _ControllerGateway(),
        registry: _FakeRegistry([Future.error(StateError('invalid registry'))]),
      );

      await controller.load();

      expect(controller.state.loadingSources, isFalse);
      expect(
        controller.state.caches[BookSourcesSection.recommended]!.error,
        isA<StateError>(),
      );
      await controller.close();
    },
  );

  test('stale registry loads cannot replace a newer reload', () async {
    final first = Completer<List<RegisteredBookSource>>();
    final second = Completer<List<RegisteredBookSource>>();
    final registry = _FakeRegistry([first.future, second.future]);
    final controller = BookSourcesController(
      gateway: _ControllerGateway(),
      registry: registry,
    );

    final initialLoad = controller.load();
    final reload = controller.reload();
    second.complete([_source('new')]);
    await reload;
    first.complete([_source('old')]);
    await initialLoad;

    expect(controller.state.sources.single.id, 'new');
    await controller.close();
  });

  test('stale section completion cannot replace the active section', () async {
    final source = _source('source');
    final discovery = Completer<BookSourceDiscoveryPage>();
    final gateway = _ControllerGateway(discoveryResults: [discovery.future]);
    final controller = BookSourcesController(
      gateway: gateway,
      registry: _FakeRegistry.completed([source]),
    );

    final initialLoad = controller.load();
    while (gateway.discoveryIds.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.changeSection(BookSourcesSection.categories);
    discovery.complete(
      BookSourceDiscoveryPage(
        sections: [
          BookSourceDiscoverySection(
            id: 'late',
            title: 'Late',
            items: [_book('late')],
          ),
        ],
      ),
    );
    await initialLoad;

    expect(controller.state.section, BookSourcesSection.categories);
    expect(controller.state.caches[BookSourcesSection.recommended], isNull);
    await controller.close();
  });

  test('stale category completion is ignored', () async {
    final source = _source('source');
    final first = Completer<BookSourceSearchPage>();
    final second = Completer<BookSourceSearchPage>();
    final gateway = _ControllerGateway(
      browseResults: [first.future, second.future],
    );
    final controller = BookSourcesController(gateway: gateway);
    final categoryA = SourcedBookCategory(source: source, id: 'a', name: 'A');
    final categoryB = SourcedBookCategory(source: source, id: 'b', name: 'B');

    final loadA = controller.selectCategory(categoryA);
    final loadB = controller.selectCategory(categoryB);
    second.complete(_page([_book('b')]));
    await loadB;
    first.complete(_page([_book('a')]));
    await loadA;

    expect(controller.state.selectedCategory, categoryB);
    expect(controller.state.categoryBooks.single.book.id, 'b');
    await controller.close();
  });

  test(
    'selecting the active categories section preserves its loaded books',
    () async {
      final source = _source('source');
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([source]),
      );

      await controller.load();
      await controller.changeSection(BookSourcesSection.categories);
      await Future<void>.delayed(Duration.zero);
      final selected = controller.state.selectedCategory;
      final books = controller.state.categoryBooks;
      final browseRequestCount = gateway.browseCategories.length;

      await controller.changeSection(BookSourcesSection.categories);

      expect(controller.state.selectedCategory, selected);
      expect(controller.state.categoryBooks, books);
      expect(gateway.browseCategories, hasLength(browseRequestCount));

      controller.setListLayout(true);
      await controller.changeSection(BookSourcesSection.categories);
      expect(gateway.browseCategories, hasLength(browseRequestCount));
      await controller.close();
      await controller.changeSection(BookSourcesSection.latest);
      expect(gateway.browseCategories, hasLength(browseRequestCount));
    },
  );

  test(
    'returning to cached categories reloads its first category after stale work',
    () async {
      final source = _source('source');
      final staleCategory = Completer<BookSourceSearchPage>();
      final gateway = _ControllerGateway(
        browseResults: [
          staleCategory.future,
          Future.value(_page([_book('latest')])),
          Future.value(_page([_book('restored-category')])),
        ],
      );
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed([source]),
      );

      await controller.load();
      await controller.changeSection(BookSourcesSection.categories);
      expect(controller.state.loadingCategoryBooks, isTrue);

      await controller.changeSection(BookSourcesSection.latest);
      await controller.changeSection(BookSourcesSection.categories);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.selectedCategory?.id, 'category');
      expect(
        controller.state.categoryBooks.single.book.id,
        'restored-category',
      );
      expect(gateway.browseCategories, ['category', null, 'category']);

      staleCategory.complete(_page([_book('stale-category')]));
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.state.categoryBooks.single.book.id,
        'restored-category',
      );
      await controller.close();
    },
  );

  test('category paging retries and deduplicates appended books', () async {
    final source = _source('source');
    final gateway = _ControllerGateway(
      browseResults: [
        Future.value(_page([_book('a')], hasMore: true)),
        Future.error(StateError('temporary')),
        Future.value(_page([_book('a'), _book('b')], page: 2)),
      ],
    );
    final controller = BookSourcesController(gateway: gateway);
    final category = SourcedBookCategory(
      source: source,
      id: 'category',
      name: 'Category',
    );

    await controller.selectCategory(category);
    await controller.loadMoreCategory();
    expect(controller.state.categoryLoadMoreFailed, isTrue);
    await controller.loadMoreCategory();

    expect(controller.state.categoryBooks.map((item) => item.book.id), [
      'a',
      'b',
    ]);
    expect(controller.state.categoryLoadMoreFailed, isFalse);
    await controller.close();
  });

  test(
    'close cancels registry changes and suppresses late load completion',
    () async {
      final load = Completer<List<RegisteredBookSource>>();
      final registry = _FakeRegistry([load.future]);
      final controller = BookSourcesController(
        gateway: _ControllerGateway(),
        registry: registry,
      );

      final pending = controller.load();
      await controller.close();
      await controller.close();
      load.complete([_source('late')]);
      await pending;

      expect(registry.cancelCount, 1);
      expect(controller.state.sources, isEmpty);
    },
  );
}

class _FakeRegistry extends BookSourceRegistry {
  _FakeRegistry(this.loads) {
    _changes = StreamController<void>.broadcast(onCancel: () => cancelCount++);
  }

  _FakeRegistry.completed(List<RegisteredBookSource> sources)
    : this([Future.value(sources)]);

  final List<Future<List<RegisteredBookSource>>> loads;
  late final StreamController<void> _changes;
  int _loadIndex = 0;
  int cancelCount = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<String>> loadGroups() async => const [];

  @override
  Future<List<RegisteredBookSource>> loadRunnableInBackground() =>
      loads[_loadIndex++];
}

class _ControllerGateway extends BookSourceClient {
  _ControllerGateway({
    this.failingIds = const {},
    this.discoveryResults = const [],
    this.browseResults = const [],
    this.cachedBrowseResults = const [],
  });

  final Set<String> failingIds;
  final List<Future<BookSourceDiscoveryPage>> discoveryResults;
  final List<Future<BookSourceSearchPage>> browseResults;
  final List<BookSourceSearchPage> cachedBrowseResults;
  final List<String> discoveryIds = [];
  final List<String> browseIds = [];
  final List<String?> browseCategories = [];
  int _browseIndex = 0;
  int _cachedBrowseIndex = 0;
  int _discoveryIndex = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source, {
    void Function(BookSourceDiscoveryPage)? onCached,
  }) async {
    discoveryIds.add(source.id);
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
    if (failingIds.contains(source.id)) throw StateError('failed');
    if (discoveryResults.isNotEmpty) {
      return discoveryResults[_discoveryIndex++];
    }
    return BookSourceDiscoveryPage(
      sections: [
        BookSourceDiscoverySection(
          id: source.id,
          title: source.id,
          items: [_book(source.id)],
        ),
      ],
    );
  }

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source, {
    void Function(List<BookSourceCategory>)? onCached,
  }) async => [const BookSourceCategory(id: 'category', name: 'Category')];

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
    void Function(BookSourceSearchPage)? onCached,
  }) {
    browseIds.add(source.id);
    browseCategories.add(category);
    if (_cachedBrowseIndex < cachedBrowseResults.length) {
      onCached?.call(cachedBrowseResults[_cachedBrowseIndex++]);
    }
    if (browseResults.isNotEmpty) return browseResults[_browseIndex++];
    return Future.value(_page([_book('${source.id}-$page')]));
  }
}

BookSourceDiscoveryPage _discoveryPage(String id) => BookSourceDiscoveryPage(
  sections: [
    BookSourceDiscoverySection(id: id, title: id, items: [_book(id)]),
  ],
);

RegisteredBookSource _source(
  String id, {
  BookSourceProtocolKind protocol = BookSourceProtocolKind.orsp,
  Map<String, dynamic>? sourceConfig,
}) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://example.org/$id/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/$id/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'discover', 'categories', 'browse'},
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 9),
  sourceProtocol: protocol,
  sourceConfig: sourceConfig,
);

BookSourceBook _book(String id) => BookSourceBook(
  id: id,
  title: id,
  author: 'Author',
  description: '',
  categories: const [],
);

BookSourceSearchPage _page(
  List<BookSourceBook> items, {
  int page = 1,
  bool hasMore = false,
}) => BookSourceSearchPage(
  items: items,
  page: page,
  pageSize: items.length,
  total: items.length,
  hasMore: hasMore,
);
