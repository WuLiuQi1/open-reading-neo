import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reader/book_source/book_source_reader_page.dart';
import 'package:xxread/services/books/pagination_cache_dao.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';

void main() {
  testWidgets('horizontal source page commits only after scrolling settles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: BookSourcePageMode.horizontalSlide.name,
    });
    final client = _LongChapterClient();
    final progressStore = _RecordingProgressStore();
    final replaceRules = ReplaceRuleService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await replaceRules.close();
      client.close();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceReaderPage(
          paginationCacheDao: _MemoryPaginationCacheDao(),
          replaceRuleService: replaceRules,
          source: _source,
          book: _book,
          client: client,
          progressStore: progressStore,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byType(PageView));
    await tester.pumpAndSettle();
    progressStore.saved.clear();

    final pageView = find.byType(PageView);
    final controller = tester.widget<PageView>(pageView).controller!;
    expect(controller.page, 0);
    expect(controller.position.maxScrollExtent, greaterThan(0));
    controller.position.isScrollingNotifier.value = true;
    tester.widget<PageView>(pageView).onPageChanged!(1);

    expect(controller.position.isScrollingNotifier.value, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(progressStore.saved, isEmpty);

    controller.position.isScrollingNotifier.value = false;
    ScrollEndNotification(
      metrics: controller.position,
      context: tester.element(pageView),
    ).dispatch(tester.element(pageView));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(progressStore.saved, hasLength(1));
    expect(progressStore.saved.single.chapterProgress, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal source page does not save a withdrawn turn', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: BookSourcePageMode.horizontalSlide.name,
    });
    final client = _LongChapterClient();
    final progressStore = _RecordingProgressStore();
    final replaceRules = ReplaceRuleService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await replaceRules.close();
      client.close();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceReaderPage(
          paginationCacheDao: _MemoryPaginationCacheDao(),
          replaceRuleService: replaceRules,
          source: _source,
          book: _book,
          client: client,
          progressStore: progressStore,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byType(PageView));
    await tester.pumpAndSettle();
    progressStore.saved.clear();

    final pageView = find.byType(PageView);
    final controller = tester.widget<PageView>(pageView).controller!;
    controller.position.isScrollingNotifier.value = true;
    tester.widget<PageView>(pageView).onPageChanged!(1);
    tester.widget<PageView>(pageView).onPageChanged!(0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(progressStore.saved, isEmpty);

    controller.position.isScrollingNotifier.value = false;
    ScrollEndNotification(
      metrics: controller.position,
      context: tester.element(pageView),
    ).dispatch(tester.element(pageView));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(progressStore.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

const _book = BookSourceBook(
  id: 'book-1',
  title: 'Horizontal source book',
  author: 'Author',
  description: '',
  categories: [],
);

final _source = RegisteredBookSource(
  id: 'example.source',
  name: 'Example',
  description: '',
  manifestUrl: Uri.parse('https://example.org/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.0',
  languages: const ['zh-CN'],
  capabilities: const {'catalog', 'content'},
  enabled: true,
  addedAt: DateTime.utc(2026, 9, 10),
);

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Expected widget did not appear: $finder');
}

class _RecordingProgressStore extends BookSourceReadingProgressStore {
  final List<BookSourceReadingProgress> saved = [];

  @override
  Future<BookSourceReadingProgress?> load({
    required String sourceId,
    required String bookId,
  }) async => null;

  @override
  Future<void> save({
    required String sourceId,
    required String bookId,
    required BookSourceReadingProgress progress,
  }) async {
    saved.add(progress);
  }
}

class _LongChapterClient extends BookSourceClient {
  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async => const [
    BookSourceChapter(id: 'chapter-1', title: 'Chapter 1', order: 0),
  ];

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async => BookSourceChapterContent(
    bookId: bookId,
    chapterId: chapterId,
    title: 'Chapter 1',
    content: List.generate(
      180,
      (index) => 'Paragraph $index keeps the horizontal reader paginated.',
    ).join('\n'),
    contentType: 'text/plain',
  );
}

class _MemoryPaginationCacheDao extends PaginationCacheDao {
  @override
  Future<Map<String, Uint8List>> loadForIdentity(
    String identity,
    String bookRevision,
  ) async => const {};

  @override
  Future<void> upsertForIdentity({
    required String identity,
    int? localBookId,
    required String bookRevision,
    required String layoutFingerprint,
    required int chapterIndex,
    required Uint8List payload,
    int? expectedEpoch,
    int? expectedRevisionEpoch,
  }) async {}
}
