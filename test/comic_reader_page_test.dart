import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/paged_image_reader_settings.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reader/comic/continuous_image_reader.dart';
import 'package:xxread/pages/reader/comic/comic_reader_page.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/pages/reader/comic/online_comic_kind.dart';
import 'package:xxread/pages/reader/image/image_reader_chrome.dart';
import 'package:xxread/pages/reader/image/paged_image_reader.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

/// 1x1 transparent PNG that Image.memory can decode.
final Uint8List _tinyPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 1x8 portrait PNG: at fit-width it expands well beyond the 320px loader.
final Uint8List _tallPng = Uint8List.fromList(const <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  8,
  8,
  6,
  0,
  0,
  0,
  56,
  26,
  149,
  65,
  0,
  0,
  0,
  20,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  255,
  255,
  255,
  127,
  38,
  6,
  6,
  6,
  6,
  252,
  4,
  0,
  150,
  170,
  4,
  11,
  62,
  22,
  161,
  219,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

/// 1x100 PNG, beyond the old 50:1 layout limit.
final Uint8List _longStripPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAABkCAYAAABHLFpgAAAAEElEQVR4nGP4DwQMo8RIIgAyH46AmqFmEAAAAABJRU5ErkJggg==',
);

/// 8x1 landscape PNG: at fit-width it is shorter than the square loader.
final Uint8List _widePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAABCAYAAADjAO9DAAAAC0lEQVR4nGNgIAAAACEAAcdv3ZQAAAAASUVORK5CYII=',
);

class _FakeImageSource extends ImageReaderSource {
  _FakeImageSource({
    required this.chapters,
    required this.pagesByChapter,
    this.initialChapterIndex = 0,
    this.initialPageIndex = 0,
    this.failingChapters = const {},
    this.documentFailures = 0,
    this.delayedPages = const {},
    this.queuedPageLoads = const {},
    this.delayedChapterCounts = const {},
    this.pageBytes,
  });

  final List<ImageReaderChapter> chapters;
  final Map<int, int> pagesByChapter;
  final int initialChapterIndex;
  final int initialPageIndex;
  final Set<int> failingChapters;
  final int documentFailures;
  final Uint8List? pageBytes;
  final Map<({int chapterIndex, int pageIndex}), Completer<Uint8List>>
  delayedPages;
  final Map<({int chapterIndex, int pageIndex}), List<Completer<Uint8List>>>
  queuedPageLoads;
  final Map<int, Completer<int>> delayedChapterCounts;
  final Map<({int chapterIndex, int pageIndex}), int> _queuedPageLoadIndexes =
      {};

  final List<({int chapterIndex, int pageIndex, int pageCount})> saved = [];
  final List<int> invalidated = [];
  final List<int> chapterCountLoads = [];
  final List<({int chapterIndex, int pageIndex, bool preload})> pageLoads = [];
  final List<({int first, int last})> retainedWindows = [];
  int documentLoads = 0;
  int pageCountLoads = 0;

  @override
  String get bookTitle => 'Host book';

  @override
  ReaderThemePalette get theme => ReaderThemes.day;

  @override
  String get settingsId => 'fake-settings';

  @override
  ImageReaderDirection get defaultDirection => ImageReaderDirection.vertical;

  @override
  Future<ImageReaderDocument> loadDocument() async {
    documentLoads++;
    if (documentLoads <= documentFailures) {
      throw StateError('document failed');
    }
    return ImageReaderDocument(
      chapters: chapters,
      initialChapterIndex: initialChapterIndex,
      initialPageIndex: initialPageIndex,
    );
  }

  @override
  Future<int> loadChapterPageCount(int chapterIndex) async {
    pageCountLoads++;
    chapterCountLoads.add(chapterIndex);
    if (failingChapters.contains(chapterIndex)) {
      throw StateError('chapter $chapterIndex failed');
    }
    final delayed = delayedChapterCounts[chapterIndex];
    if (delayed != null) return delayed.future;
    return pagesByChapter[chapterIndex] ?? 0;
  }

  @override
  Future<Uint8List> loadPage(
    int chapterIndex,
    int pageIndex, {
    bool preload = false,
  }) async {
    pageLoads.add((
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      preload: preload,
    ));
    final delayed =
        delayedPages[(chapterIndex: chapterIndex, pageIndex: pageIndex)];
    if (delayed != null && !preload) return delayed.future;
    final key = (chapterIndex: chapterIndex, pageIndex: pageIndex);
    final queued = queuedPageLoads[key];
    if (queued != null && queued.isNotEmpty && !preload) {
      final index = _queuedPageLoadIndexes.update(
        key,
        (current) => current + 1,
        ifAbsent: () => 0,
      );
      final selected = index < queued.length ? index : queued.length - 1;
      return queued[selected].future;
    }
    return pageBytes ?? _tinyPng;
  }

  @override
  Future<void> saveProgress({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  }) async {
    saved.add((
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      pageCount: pageCount,
    ));
  }

  @override
  void retainChapterWindow(int firstChapterIndex, int lastChapterIndex) {
    retainedWindows.add((first: firstChapterIndex, last: lastChapterIndex));
  }

  @override
  void invalidateChapter(int chapterIndex) => invalidated.add(chapterIndex);

  @override
  String emptyPagesMessage(AppLocalizations l10n) => l10n.readerComicNoPages;

  @override
  String describeError(Object error, AppLocalizations l10n) =>
      l10n.readerOpenFailed(error.toString());
}

Future<void> _pumpHost(WidgetTester tester, ImageReaderSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ComicReaderPage(source: source),
    ),
  );
  await _settleReaderImages(tester);
}

Future<void> _settleReaderImages(WidgetTester tester) async {
  if (!kIsWeb) {
    await tester.pumpAndSettle();
    return;
  }
  // Advance animations and browser image decoding together. A fake-clock-only
  // settle can mount another image and starve the JS events needed to load it.
  for (var attempt = 0; attempt < 500; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final loading = find
        .byType(CircularProgressIndicator)
        .evaluate()
        .isNotEmpty;
    final decoding = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .any((image) => image.image == null);
    if (!loading && !decoding && !tester.binding.hasScheduledFrame) return;
  }
  fail('Reader images did not finish loading in the browser.');
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Finder _continuousPage(int chapterIndex, int pageIndex) => find.byKey(
  ValueKey('${ContinuousImageReader.pageKeyPrefix}$chapterIndex-$pageIndex'),
);

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var frame = 0; frame < count; frame++) {
    if (kIsWeb) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _waitForContinuousScrollIdle(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byType(ContinuousImageReader),
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsOneWidget);
  final position = tester.state<ScrollableState>(scrollable).position;
  for (var frame = 0; frame < 100; frame++) {
    if (!position.isScrollingNotifier.value) break;
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(position.isScrollingNotifier.value, isFalse);
}

Future<void> _pumpContinuousHost(
  WidgetTester tester, {
  required _FakeImageSource source,
  required ImageReaderDocument document,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ContinuousImageReader(
        document: document,
        source: source,
        initialChapterIndex: document.initialChapterIndex,
        initialPageIndex: document.initialPageIndex,
        onTableOfContents: null,
        onSettings: () {},
        onChangeReadingMode: () {},
      ),
    ),
  );
  await _pumpFrames(tester);
}

void main() {
  const fullscreenChannel = MethodChannel('com.niki.xxread/fullscreen');
  const readerKeysChannel = MethodChannel('com.niki.xxread/reader_keys');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ReaderThemes.resetSavedPaletteCacheForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fullscreenChannel, (_) async => null);
    messenger.setMockMethodCallHandler(readerKeysChannel, (_) async => null);
  });

  tearDown(() {
    ReaderThemes.resetSavedPaletteCacheForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fullscreenChannel, null);
    messenger.setMockMethodCallHandler(readerKeysChannel, null);
  });

  test('image sources are classified by source type or book type', () {
    final imageSource = RegisteredBookSource(
      id: 'src',
      name: 'Images',
      description: '',
      manifestUrl: Uri.parse('https://example.test/'),
      apiBaseUrl: Uri.parse('https://example.test/'),
      protocolVersion: 'reading-source-1',
      languages: const [],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      addedAt: DateTime.utc(2026, 1, 1),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: const {'bookSourceType': 2},
    );
    const imageBook = BookSourceBook(
      id: 'book',
      title: 'Comic',
      author: '',
      description: '',
      categories: [],
      type: 64,
    );
    const textBook = BookSourceBook(
      id: 'book',
      title: 'Novel',
      author: '',
      description: '',
      categories: [],
    );

    expect(isOnlineComicSource(imageSource, textBook), isTrue);
    expect(
      isOnlineComicSource(imageSource.copyWith(sourceConfig: {}), imageBook),
      isTrue,
    );
    expect(
      isOnlineComicSource(imageSource.copyWith(sourceConfig: {}), textBook),
      isFalse,
    );
  });

  testWidgets('host restores the saved chapter and page on one reading line', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PagedImageReaderSettingsStore.directionOverridesKey:
          '{"fake-settings":"ltr"}',
    });
    final source = _FakeImageSource(
      chapters: const [
        ImageReaderChapter(id: 'c1', title: 'One'),
        ImageReaderChapter(id: 'c2', title: 'Two'),
      ],
      pagesByChapter: const {0: 2, 1: 4},
      initialChapterIndex: 1,
      initialPageIndex: 2,
    );

    await _pumpHost(tester, source);

    expect(find.byType(PagedImageReader), findsOneWidget);
    expect(find.text('Host book · Two'), findsOneWidget);
    expect(find.text('3 / 4'), findsOneWidget);
    expect(source.pageCountLoads, 1);
    await _unmount(tester);
  });

  testWidgets(
    'memory pressure keeps only the active chapter on the same page',
    (tester) async {
      final source = _FakeImageSource(
        chapters: const [
          ImageReaderChapter(id: 'c1', title: 'One'),
          ImageReaderChapter(id: 'c2', title: 'Two'),
          ImageReaderChapter(id: 'c3', title: 'Three'),
        ],
        pagesByChapter: const {0: 1, 1: 2, 2: 1},
        initialChapterIndex: 1,
      );

      await _pumpHost(tester, source);
      tester.binding.handleMemoryPressure();
      await tester.pump();

      expect(source.retainedWindows.last, (first: 1, last: 1));
      expect(find.byType(ComicReaderPage), findsOneWidget);
      expect(find.byType(ContinuousImageReader), findsOneWidget);
      await _unmount(tester);
    },
  );

  testWidgets(
    'vertical reading keeps a three chapter data window and preloads neighbors',
    (tester) async {
      final source = _FakeImageSource(
        chapters: const [
          ImageReaderChapter(id: 'c1', title: 'One'),
          ImageReaderChapter(id: 'c2', title: 'Two'),
          ImageReaderChapter(id: 'c3', title: 'Three'),
        ],
        pagesByChapter: const {0: 1, 1: 2, 2: 1},
        initialChapterIndex: 1,
      );

      await _pumpHost(tester, source);

      expect(find.byType(ContinuousImageReader), findsOneWidget);
      expect(source.pageCountLoads, 3);
      expect(source.retainedWindows.last, (first: 0, last: 2));
      expect(
        source.pageLoads
            .where((load) => load.preload)
            .map((load) => load.chapterIndex),
        containsAll(<int>[0, 2]),
      );
      await _unmount(tester);
    },
  );

  for (final sample in [
    (name: 'portrait PNG', bytes: _tallPng, height: 3200.0),
    (name: 'long-strip PNG', bytes: _longStripPng, height: 40000.0),
    // Native Flutter supports WBMP; its web decoder does not.
    // This format was absent from the old hand-written header parser.
    if (!kIsWeb)
      (
        name: 'WBMP',
        bytes: Uint8List.fromList([0, 0, 1, 8, ...List.filled(8, 0)]),
        height: 3200.0,
      ),
  ]) {
    testWidgets(
      'continuous images preserve full height and chapter boundary: ${sample.name}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 900);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final source = _FakeImageSource(
          chapters: const [
            ImageReaderChapter(id: 'c1', title: 'One'),
            ImageReaderChapter(id: 'c2', title: 'Two'),
          ],
          pagesByChapter: const {0: 1, 1: 1},
          pageBytes: sample.bytes,
        );

        await _pumpHost(tester, source);

        final content = find.byKey(
          const ValueKey('${ContinuousImageReader.pageContentKeyPrefix}0-0'),
        );
        expect(tester.getSize(content), Size(400, sample.height));
        await tester.drag(
          find.byType(ContinuousImageReader),
          const Offset(0, -1000),
        );
        await _settleReaderImages(tester);
        expect(tester.getSize(content), Size(400, sample.height));

        await tester.drag(
          find.byType(ContinuousImageReader),
          Offset(0, -(sample.height - 1400)),
        );
        await _settleReaderImages(tester);
        final boundary = find.byKey(
          const ValueKey('${ContinuousImageReader.chapterBoundaryKeyPrefix}1'),
        );
        final nextPage = find.byKey(
          const ValueKey('${ContinuousImageReader.pageContentKeyPrefix}1-0'),
        );
        expect(tester.getBottomLeft(content).dy, inExclusiveRange(0, 900));
        expect(
          tester.getTopLeft(boundary).dy,
          tester.getBottomLeft(content).dy,
        );
        expect(
          tester.getTopLeft(nextPage).dy,
          tester.getBottomLeft(boundary).dy,
        );
        expect(tester.getSize(nextPage), Size(400, sample.height));
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      },
    );
  }

  testWidgets('a delayed image above the viewport preserves an active drag', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final delayed = Completer<Uint8List>();
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 3},
      initialPageIndex: 0,
      delayedPages: {(chapterIndex: 0, pageIndex: 0): delayed},
    );

    await _pumpContinuousHost(
      tester,
      source: source,
      document: const ImageReaderDocument(
        chapters: [ImageReaderChapter(id: 'c1', title: 'One')],
        initialChapterIndex: 0,
        initialPageIndex: 0,
      ),
    );
    expect(find.text('1 / 3'), findsWidgets);
    final pageOne = _continuousPage(0, 1);
    await tester.timedDrag(
      find.byType(ContinuousImageReader),
      const Offset(0, -600),
      const Duration(seconds: 1),
    );
    await _pumpFrames(tester, 5);

    final gesture = await tester.startGesture(const Offset(400, 500));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final beforeCompletion = tester.getTopLeft(pageOne).dy;

    delayed.complete(_tallPng);
    await _pumpFrames(tester, 10);
    expect(tester.getTopLeft(pageOne).dy, closeTo(beforeCompletion, 0.5));

    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    final afterSecondMove = tester.getTopLeft(pageOne).dy;
    expect(afterSecondMove, closeTo(beforeCompletion - 120, 0.5));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await _pumpFrames(tester, 10);
    expect(tester.getTopLeft(pageOne).dy, closeTo(afterSecondMove, 0.5));

    expect(
      find.byKey(
        const ValueKey('${ContinuousImageReader.pageContentKeyPrefix}0-0'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('a delayed image above an idle viewport preserves its anchor', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final delayed = Completer<Uint8List>();
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 3},
      delayedPages: {(chapterIndex: 0, pageIndex: 0): delayed},
    );

    await _pumpContinuousHost(
      tester,
      source: source,
      document: const ImageReaderDocument(
        chapters: [ImageReaderChapter(id: 'c1', title: 'One')],
        initialChapterIndex: 0,
        initialPageIndex: 0,
      ),
    );
    final pageOne = _continuousPage(0, 1);
    await tester.timedDrag(
      find.byType(ContinuousImageReader),
      const Offset(0, -600),
      const Duration(seconds: 1),
    );
    await _waitForContinuousScrollIdle(tester);
    final beforeCompletion = tester.getTopLeft(pageOne).dy;

    delayed.complete(_tallPng);
    await _pumpFrames(tester, 20);

    expect(tester.getTopLeft(pageOne).dy, closeTo(beforeCompletion, 0.5));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('a delayed image above the viewport does not reverse a fling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final delayed = Completer<Uint8List>();
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 4},
      delayedPages: {(chapterIndex: 0, pageIndex: 0): delayed},
    );

    await _pumpContinuousHost(
      tester,
      source: source,
      document: const ImageReaderDocument(
        chapters: [ImageReaderChapter(id: 'c1', title: 'One')],
        initialChapterIndex: 0,
        initialPageIndex: 0,
      ),
    );
    final pageOne = _continuousPage(0, 1);
    await tester.timedDrag(
      find.byType(ContinuousImageReader),
      const Offset(0, -500),
      const Duration(seconds: 1),
    );
    await _pumpFrames(tester, 5);
    await tester.fling(
      find.byType(ContinuousImageReader),
      const Offset(0, -500),
      3000,
    );
    final observedTops = <double>[tester.getTopLeft(pageOne).dy];

    delayed.complete(_tallPng);
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (pageOne.evaluate().isNotEmpty) {
        observedTops.add(tester.getTopLeft(pageOne).dy);
      }
    }

    expect(observedTops.length, greaterThan(2));
    for (var index = 1; index < observedTops.length; index++) {
      expect(
        observedTops[index],
        lessThanOrEqualTo(observedTops[index - 1] + 1),
      );
    }
    expect(observedTops.last, lessThan(observedTops.first - 5));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'multiple image extents above the viewport preserve one active anchor',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final growingPage = Completer<Uint8List>();
      final shrinkingPage = Completer<Uint8List>();
      final source = _FakeImageSource(
        chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
        pagesByChapter: const {0: 4},
        delayedPages: {
          (chapterIndex: 0, pageIndex: 0): growingPage,
          (chapterIndex: 0, pageIndex: 1): shrinkingPage,
        },
      );

      await _pumpContinuousHost(
        tester,
        source: source,
        document: const ImageReaderDocument(
          chapters: [ImageReaderChapter(id: 'c1', title: 'One')],
          initialChapterIndex: 0,
          initialPageIndex: 0,
        ),
      );
      final anchor = _continuousPage(0, 2);
      final gesture = await tester.startGesture(const Offset(400, 500));
      await gesture.moveBy(const Offset(0, -950));
      await tester.pump(const Duration(seconds: 1));
      expect(_continuousPage(0, 0), findsOneWidget);
      expect(_continuousPage(0, 1), findsOneWidget);
      expect(anchor, findsOneWidget);
      final beforeCompletion = tester.getTopLeft(anchor).dy;
      growingPage.complete(_tallPng);
      shrinkingPage.complete(_widePng);
      await _pumpFrames(tester, 20);

      final grownContent = find.byKey(
        const ValueKey('${ContinuousImageReader.pageContentKeyPrefix}0-0'),
      );
      final shrunkContent = find.byKey(
        const ValueKey('${ContinuousImageReader.pageContentKeyPrefix}0-1'),
      );
      expect(grownContent, findsOneWidget);
      expect(shrunkContent, findsOneWidget);
      expect(tester.getSize(grownContent), const Size(800, 6400));
      expect(tester.getSize(shrunkContent), const Size(800, 100));
      expect(tester.getTopLeft(anchor).dy, closeTo(beforeCompletion, 0.5));
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(
        tester.getTopLeft(anchor).dy,
        closeTo(beforeCompletion - 100, 0.5),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets('a failed page retry preserves its extent and current anchor', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final failedLoad = Completer<Uint8List>();
    final retriedLoad = Completer<Uint8List>();
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 3},
      queuedPageLoads: {
        (chapterIndex: 0, pageIndex: 0): [failedLoad, retriedLoad],
      },
    );

    await _pumpContinuousHost(
      tester,
      source: source,
      document: const ImageReaderDocument(
        chapters: [ImageReaderChapter(id: 'c1', title: 'One')],
        initialChapterIndex: 0,
        initialPageIndex: 0,
      ),
    );
    final failedPage = _continuousPage(0, 0);
    final anchor = _continuousPage(0, 1);
    await tester.timedDrag(
      find.byType(ContinuousImageReader),
      const Offset(0, -300),
      const Duration(seconds: 1),
    );
    await _waitForContinuousScrollIdle(tester);
    final initialExtent = tester.getSize(failedPage).height;
    final initialAnchor = tester.getTopLeft(anchor).dy;

    failedLoad.completeError(StateError('page failed'));
    await _pumpFrames(tester, 5);
    expect(tester.getSize(failedPage).height, initialExtent);
    expect(tester.getTopLeft(anchor).dy, closeTo(initialAnchor, 0.5));

    await tester.tap(find.text('Retry'));
    await _pumpFrames(tester, 5);
    expect(tester.getSize(failedPage).height, initialExtent);
    expect(tester.getTopLeft(anchor).dy, closeTo(initialAnchor, 0.5));

    retriedLoad.complete(_tinyPng);
    await _pumpFrames(tester, 10);
    expect(tester.getSize(failedPage).height, initialExtent);
    expect(tester.getTopLeft(anchor).dy, closeTo(initialAnchor, 0.5));
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'a chapter window update preserves the visible page during a drag',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final delayedChapter = Completer<int>();
      final chapters = const [
        ImageReaderChapter(id: 'c1', title: 'One'),
        ImageReaderChapter(id: 'c2', title: 'Two'),
        ImageReaderChapter(id: 'c3', title: 'Three'),
        ImageReaderChapter(id: 'c4', title: 'Four'),
      ];
      final source = _FakeImageSource(
        chapters: chapters,
        pagesByChapter: const {0: 1, 1: 1, 2: 1, 3: 1},
        initialChapterIndex: 1,
        delayedChapterCounts: {3: delayedChapter},
      );

      await _pumpContinuousHost(
        tester,
        source: source,
        document: ImageReaderDocument(
          chapters: chapters,
          initialChapterIndex: 1,
          initialPageIndex: 0,
        ),
      );
      final page = _continuousPage(2, 0);
      await tester.timedDrag(
        find.byType(ContinuousImageReader),
        const Offset(0, -650),
        const Duration(seconds: 1),
      );
      await _pumpFrames(tester, 10);
      expect(page, findsOneWidget);
      expect(source.pageCountLoads, 4);
      final pageState = tester.state(page);

      final gesture = await tester.startGesture(const Offset(400, 500));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(seconds: 1));
      final beforeWindowUpdate = tester.getTopLeft(page).dy;
      delayedChapter.complete(1);
      await _pumpFrames(tester, 10);

      expect(tester.state(page), same(pageState));
      expect(tester.getTopLeft(page).dy, closeTo(beforeWindowUpdate, 0.5));
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(
        tester.getTopLeft(page).dy,
        closeTo(beforeWindowUpdate - 100, 0.5),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await _pumpFrames(tester, 5);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets(
    'reversing chapter window loads preserves the visible page and older chapters',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final delayedFirstChapter = Completer<int>();
      final chapters = [
        for (var chapter = 0; chapter < 6; chapter++)
          ImageReaderChapter(id: 'c$chapter', title: 'Chapter $chapter'),
      ];
      final source = _FakeImageSource(
        chapters: chapters,
        pagesByChapter: const {0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1},
        initialChapterIndex: 2,
        delayedChapterCounts: {0: delayedFirstChapter},
      );

      await _pumpContinuousHost(
        tester,
        source: source,
        document: ImageReaderDocument(
          chapters: chapters,
          initialChapterIndex: 2,
          initialPageIndex: 0,
        ),
      );
      final readerState = tester.state(find.byType(ContinuousImageReader));
      await tester.timedDrag(
        find.byType(ContinuousImageReader),
        const Offset(0, -700),
        const Duration(seconds: 1),
      );
      for (
        var frame = 0;
        frame < 50 && !source.retainedWindows.any((window) => window.last >= 4);
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(source.retainedWindows.any((window) => window.last >= 4), isTrue);
      expect(_continuousPage(1, 0), findsOneWidget);

      await tester.timedDrag(
        find.byType(ContinuousImageReader),
        const Offset(0, 2000),
        const Duration(seconds: 1),
      );
      for (
        var frame = 0;
        frame < 50 && !source.chapterCountLoads.contains(0);
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(source.chapterCountLoads, contains(0));

      await tester.timedDrag(
        find.byType(ContinuousImageReader),
        const Offset(0, -1700),
        const Duration(seconds: 1),
      );
      await _waitForContinuousScrollIdle(tester);
      final visiblePage = _continuousPage(3, 0);
      expect(visiblePage, findsOneWidget);
      final visiblePageState = tester.state(visiblePage);
      final beforeCompletion = tester.getTopLeft(visiblePage).dy;
      expect(beforeCompletion, inExclusiveRange(-800, 1000));

      delayedFirstChapter.complete(1);
      await _pumpFrames(tester, 20);

      expect(tester.state(visiblePage), same(visiblePageState));
      expect(tester.getTopLeft(visiblePage).dy, closeTo(beforeCompletion, 0.5));

      await tester.timedDrag(
        find.byType(ContinuousImageReader),
        const Offset(0, 3000),
        const Duration(seconds: 1),
      );
      await _waitForContinuousScrollIdle(tester);
      await _pumpFrames(tester, 10);
      expect(_continuousPage(1, 0), findsOneWidget);
      expect(
        tester.state(find.byType(ContinuousImageReader)),
        same(readerState),
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets(
    'all directions use one chrome and switch through the unified reader',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final source = _FakeImageSource(
        chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
        pagesByChapter: const {0: 1},
      );

      await _pumpHost(tester, source);
      expect(find.byType(ContinuousImageReader), findsOneWidget);
      expect(find.byType(ImageReaderChrome), findsOneWidget);
      final controlBars = tester.widgetList<ReaderControlBar>(
        find.descendant(
          of: find.byType(ImageReaderChrome),
          matching: find.byType(ReaderControlBar),
        ),
      );
      expect(controlBars, hasLength(2));
      expect(controlBars.last.borderRadius, BorderRadius.circular(24));
      expect(find.byType(Slider), findsOneWidget);

      await tester.tapAt(const Offset(400, 450));
      await tester.pump(const Duration(milliseconds: 300));
      final button = tester.widget<Widget>(
        find.byKey(ContinuousImageReader.settingsButtonKey),
      );
      expect(button, isNotNull);
      final settingsTap = tester.widget<InkResponse>(
        find.descendant(
          of: find.byKey(ContinuousImageReader.settingsButtonKey),
          matching: find.byType(InkResponse),
        ),
      );
      settingsTap.onTap!.call();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('continuous-reader-settings-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('comic-reader-settings-tab-bar')),
        findsOneWidget,
      );
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Paging'), findsOneWidget);
      expect(find.text('Follow system'), findsOneWidget);
      expect(find.text('Light Mode'), findsOneWidget);
      expect(find.text('Dark Mode'), findsOneWidget);
      expect(find.byType(ContinuousImageReader), findsOneWidget);
      expect(find.byType(PagedImageReader), findsNothing);
      var prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PagedImageReaderSettingsStore.directionOverridesKey),
        isNull,
      );

      await tester.tap(find.text('Dark Mode'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ImageReaderChrome>(find.byType(ImageReaderChrome))
            .palette,
        ReaderThemes.pureBlack,
      );
      prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(ReaderSettingsStore.themeKey),
        ReaderThemes.pureBlack.id,
      );
      expect(
        prefs.getString(PagedImageReaderSettingsStore.backgroundKey),
        ImageReaderBackground.black.name,
      );

      await tester.tap(find.text('Follow system'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ImageReaderChrome>(find.byType(ImageReaderChrome))
            .palette
            .id,
        ReaderThemes.systemId,
      );
      prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(ReaderSettingsStore.themeKey),
        ReaderThemes.systemId,
      );

      await tester.tap(find.text('Paging'));
      await tester.pumpAndSettle();
      expect(find.text('Reading direction'), findsOneWidget);
      expect(find.text('Right to left (manga)'), findsOneWidget);

      await tester.tap(find.text('Left to right'));
      await tester.pumpAndSettle();
      expect(find.byType(ContinuousImageReader), findsNothing);
      expect(find.byType(PagedImageReader), findsOneWidget);
      expect(find.byType(ImageReaderChrome), findsOneWidget);
      prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PagedImageReaderSettingsStore.directionOverridesKey),
        contains('"fake-settings":"ltr"'),
      );

      final directionTap = tester.widget<InkResponse>(
        find.ancestor(
          of: find.text('Left to right'),
          matching: find.byType(InkResponse),
        ),
      );
      directionTap.onTap!.call();
      await tester.pumpAndSettle();
      expect(find.byType(PagedImageReader), findsNothing);
      expect(find.byType(ContinuousImageReader), findsOneWidget);
      expect(find.byType(ImageReaderChrome), findsOneWidget);
      await _unmount(tester);
    },
  );

  testWidgets('catalog sheet keeps its handle on-screen and can close', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });
    final source = _FakeImageSource(
      chapters: const [
        ImageReaderChapter(id: 'c1', title: 'One'),
        ImageReaderChapter(id: 'c2', title: 'Two'),
        ImageReaderChapter(id: 'c3', title: 'Three'),
      ],
      pagesByChapter: const {0: 1, 1: 1, 2: 1},
    );

    await _pumpHost(tester, source);
    await tester.tapAt(const Offset(400, 450));
    await tester.pump(const Duration(milliseconds: 300));
    tester
        .widget<InkResponse>(
          find.ancestor(
            of: find.text('Table of Contents'),
            matching: find.byType(InkResponse),
          ),
        )
        .onTap!
        .call();
    await tester.pumpAndSettle();

    final sheet = tester.getRect(
      find.byKey(const ValueKey('comic-catalog-sheet')),
    );
    final handle = tester.getRect(
      find.byKey(const ValueKey('comic-catalog-drag-handle')),
    );
    final screen = tester.getSize(find.byType(ComicReaderPage));
    expect(sheet.top, greaterThan(0));
    expect(sheet.height, lessThan(screen.height));
    expect(handle.top, greaterThanOrEqualTo(sheet.top));
    expect(handle.top, greaterThanOrEqualTo(59));
    expect(find.text('Close'), findsOneWidget);

    await tester.fling(
      find.byKey(const ValueKey('comic-catalog-drag-handle')),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comic-catalog-sheet')), findsNothing);

    await tester.tapAt(const Offset(400, 450));
    await tester.pump(const Duration(milliseconds: 300));
    tester
        .widget<InkResponse>(
          find.ancestor(
            of: find.text('Table of Contents'),
            matching: find.byType(InkResponse),
          ),
        )
        .onTap!
        .call();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Three'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('comic-catalog-sheet')), findsNothing);
    expect(
      find.byKey(const ValueKey('continuous-image-reader-1')),
      findsOneWidget,
    );
    expect(find.text('Three'), findsWidgets);
    await _unmount(tester);
  });

  testWidgets(
    'vertical reading anchors an empty initial chapter without fake progress',
    (tester) async {
      final source = _FakeImageSource(
        chapters: const [
          ImageReaderChapter(id: 'c1', title: 'One'),
          ImageReaderChapter(id: 'c2', title: 'Two'),
          ImageReaderChapter(id: 'c3', title: 'Three'),
        ],
        pagesByChapter: const {0: 1, 1: 0, 2: 1},
        initialChapterIndex: 1,
      );

      await _pumpHost(tester, source);

      expect(
        find.byKey(
          const ValueKey('${ContinuousImageReader.emptyChapterKeyPrefix}1'),
        ),
        findsOneWidget,
      );
      expect(find.text('0 / 0'), findsWidgets);
      expect(
        source.saved.where((progress) => progress.chapterIndex == 1),
        isEmpty,
      );
      await _unmount(tester);
    },
  );

  testWidgets(
    'scrolling onto an empty chapter recenters without fake page progress',
    (tester) async {
      final source = _FakeImageSource(
        chapters: const [
          ImageReaderChapter(id: 'c1', title: 'One'),
          ImageReaderChapter(id: 'c2', title: 'Two'),
          ImageReaderChapter(id: 'c3', title: 'Three'),
        ],
        pagesByChapter: const {0: 1, 1: 0, 2: 1},
      );

      await _pumpHost(tester, source);
      await tester.drag(
        find.byType(ContinuousImageReader),
        const Offset(0, -360),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey('${ContinuousImageReader.emptyChapterKeyPrefix}1'),
        ),
        findsOneWidget,
      );
      expect(
        source.saved.where((progress) => progress.chapterIndex == 1),
        isEmpty,
      );

      for (final delta in const [-90.0, 90.0, -90.0, 90.0]) {
        await tester.drag(find.byType(ContinuousImageReader), Offset(0, delta));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets(
    'crossing the last page opens the next chapter on the same host',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PagedImageReaderSettingsStore.directionOverridesKey:
            '{"fake-settings":"ltr"}',
      });
      final source = _FakeImageSource(
        chapters: const [
          ImageReaderChapter(id: 'c1', title: 'One'),
          ImageReaderChapter(id: 'c2', title: 'Two'),
        ],
        pagesByChapter: const {0: 1, 1: 2},
      );

      await _pumpHost(tester, source);
      expect(find.text('Host book · One'), findsOneWidget);

      await tester.tapAt(const Offset(700, 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Host book · Two'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await _unmount(tester);
    },
  );

  testWidgets('document failure can retry without leaving the reader', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PagedImageReaderSettingsStore.directionOverridesKey:
          '{"fake-settings":"ltr"}',
    });
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 2},
      documentFailures: 1,
    );

    await _pumpHost(tester, source);
    expect(find.textContaining('Failed to open'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    for (
      var attempt = 0;
      attempt < 10 &&
          find.textContaining('Failed to open').evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(source.documentLoads, 2);
    expect(find.textContaining('Failed to open'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('retry invalidates the failed chapter and reloads it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PagedImageReaderSettingsStore.directionOverridesKey:
          '{"fake-settings":"ltr"}',
    });
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 2},
      failingChapters: {0},
    );

    await _pumpHost(tester, source);
    expect(find.textContaining('Failed to open'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(source.invalidated, [0]);
    expect(source.pageCountLoads, 2);
    await _unmount(tester);
  });
}
