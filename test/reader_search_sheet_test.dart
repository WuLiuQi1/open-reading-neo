import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_search_sheet.dart';

void main() {
  testWidgets('shows matches before the whole book finishes loading', (
    tester,
  ) async {
    final documents = StreamController<ReaderSearchDocument>();

    await _pumpSearchHost(
      tester,
      loadDocuments: () => documents.stream,
      documentCount: 2,
    );
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-text-search-field')),
      '线索',
    );
    await tester.pump(const Duration(milliseconds: 251));

    documents.add(
      const ReaderSearchDocument(
        chapterIndex: 0,
        chapterTitle: '第一章',
        text: '第一章里已经出现了关键线索。',
      ),
    );
    await tester.pump();

    expect(find.text('第一章'), findsOneWidget);
    expect(find.textContaining('关键线索'), findsOneWidget);
    expect(find.text('找到 1 处 · 已搜索 1/2 章'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await documents.close();
    await tester.pump();
    expect(find.text('找到 1 处'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('cancels stale query results when the keyword changes', (
    tester,
  ) async {
    final streams = <StreamController<ReaderSearchDocument>>[];

    await _pumpSearchHost(
      tester,
      loadDocuments: () {
        final stream = StreamController<ReaderSearchDocument>();
        streams.add(stream);
        return stream.stream;
      },
      documentCount: 1,
    );
    final field = find.byKey(const ValueKey('reader-full-text-search-field'));
    await tester.enterText(field, '旧词');
    await tester.pump(const Duration(milliseconds: 251));
    await tester.enterText(field, '新词');
    streams.first.add(
      const ReaderSearchDocument(
        chapterIndex: 0,
        chapterTitle: '旧结果',
        text: '这里只有旧词',
      ),
    );
    await tester.pump();
    expect(find.text('旧结果'), findsNothing);
    expect(streams, hasLength(1));
    await tester.pump(const Duration(milliseconds: 251));
    expect(streams, hasLength(2));
    streams.last.add(
      const ReaderSearchDocument(
        chapterIndex: 1,
        chapterTitle: '新结果',
        text: '这里只显示新词',
      ),
    );
    await tester.pump();

    expect(find.text('旧结果'), findsNothing);
    expect(find.text('新结果'), findsOneWidget);
    await streams.last.close();
    await tester.pump();
  });

  testWidgets('stops loading and reports a loader error', (tester) async {
    await _pumpSearchHost(
      tester,
      loadDocuments: () =>
          Stream<ReaderSearchDocument>.error(StateError('chapter unavailable')),
      documentCount: 3,
    );
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-text-search-field')),
      '内容',
    );
    await tester.pump(const Duration(milliseconds: 251));
    await tester.pump();

    expect(find.text('搜索失败，请重试'), findsOneWidget);
    expect(find.text('搜索过程中出现错误，请稍后重试'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('stops requesting chapters after the result limit', (
    tester,
  ) async {
    var requestedChapters = 0;
    var cancelled = false;
    Stream<ReaderSearchDocument> loadDocuments() async* {
      try {
        for (var index = 0; index < 3; index++) {
          requestedChapters++;
          yield ReaderSearchDocument(
            chapterIndex: index,
            chapterTitle: 'Chapter $index',
            text: List.filled(500, 'match').join(' '),
          );
        }
      } finally {
        cancelled = true;
      }
    }

    await _pumpSearchHost(
      tester,
      loadDocuments: loadDocuments,
      documentCount: 3,
    );
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-text-search-field')),
      'match',
    );
    await tester.pump(const Duration(milliseconds: 251));
    await tester.pump();

    expect(requestedChapters, 1);
    expect(cancelled, isTrue);
    expect(find.text('至少找到 500 处（仅显示前 500 处）'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('closing the sheet cancels the active search', (tester) async {
    var cancelled = false;
    final documents = StreamController<ReaderSearchDocument>(
      onCancel: () => cancelled = true,
    );
    addTearDown(documents.close);
    await _pumpSearchHost(
      tester,
      loadDocuments: () => documents.stream,
      documentCount: 2,
    );
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-text-search-field')),
      'match',
    );
    await tester.pump(const Duration(milliseconds: 251));
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a result returns it after the sheet closes', (
    tester,
  ) async {
    ReaderSearchResult? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  selected = await showReaderSearchSheet(
                    context,
                    palette: ReaderThemes.day,
                    loadDocuments: () => Stream.value(
                      const ReaderSearchDocument(
                        chapterIndex: 2,
                        chapterTitle: '第三章',
                        text: '这里出现了目标词。',
                      ),
                    ),
                    documentCount: 1,
                  );
                },
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-text-search-field')),
      '目标词',
    );
    await tester.pump(const Duration(milliseconds: 251));
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNothing);
    expect(selected, isNotNull);
    expect(selected!.chapterIndex, 2);
    expect(selected!.chapterTitle, '第三章');
    expect(selected!.excerpt, contains('目标词'));
  });
}

Future<void> _pumpSearchHost(
  WidgetTester tester, {
  required ReaderSearchLoader loadDocuments,
  required int documentCount,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showReaderSearchSheet(
                context,
                palette: ReaderThemes.day,
                loadDocuments: loadDocuments,
                documentCount: documentCount,
              ),
              child: const Text('打开搜索'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开搜索'));
  await tester.pumpAndSettle();
}
