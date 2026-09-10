import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/native_text_paginator.dart';
import 'package:xxread/core/reader/reader_text_pagination.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 字体不内置后，测试用系统默认字体跑文本布局断言；不再 rootBundle.load 已删字体。

  const fontSize = 20.0;
  const lineHeight = 1.8;
  const style = TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    color: Color(0xFF000000),
  );
  const twoLines = TextSpan(text: 'First line\nSecond line', style: style);

  TextPainter layout({StrutStyle? strut, TextHeightBehavior? behavior}) {
    return TextPainter(
      text: twoLines,
      textDirection: TextDirection.ltr,
      strutStyle: strut,
      textHeightBehavior: behavior,
    )..layout(maxWidth: 500);
  }

  test('trimmed behavior removes exactly the first/last line leading', () {
    final full = layout();
    final trimmed = layout(
      strut: readerStrutStyle(style),
      behavior: readerTextHeightBehavior,
    );
    expect(
      full.height - trimmed.height,
      moreOrLessEquals((lineHeight - 1) * fontSize, epsilon: 0.01),
    );
    full.dispose();
    trimmed.dispose();
  });

  test('line pitch between lines is unchanged by trimming', () {
    final full = layout();
    final trimmed = layout(
      strut: readerStrutStyle(style),
      behavior: readerTextHeightBehavior,
    );
    double pitch(TextPainter painter) {
      final metrics = painter.computeLineMetrics();
      expect(metrics, hasLength(2));
      return metrics[1].baseline - metrics[0].baseline;
    }

    expect(pitch(full), moreOrLessEquals(lineHeight * fontSize, epsilon: 0.01));
    expect(pitch(trimmed), moreOrLessEquals(pitch(full), epsilon: 0.01));
    full.dispose();
    trimmed.dispose();
  });

  test('readerStrutStyle does not re-add the trimmed leading', () {
    // StrutStyle.fromTextStyle carries the height multiplier, and struts
    // ignore TextHeightBehavior entirely — guard against regressing to it.
    final withLegacyStrut = layout(
      strut: StrutStyle.fromTextStyle(style),
      behavior: readerTextHeightBehavior,
    );
    final withReaderStrut = layout(
      strut: readerStrutStyle(style),
      behavior: readerTextHeightBehavior,
    );
    final noStrut = layout(behavior: readerTextHeightBehavior);

    expect(
      withReaderStrut.height,
      moreOrLessEquals(noStrut.height, epsilon: 0.01),
    );
    expect(withLegacyStrut.height, greaterThan(withReaderStrut.height));
    withLegacyStrut.dispose();
    withReaderStrut.dispose();
    noStrut.dispose();
  });

  test('paginator fits one extra line per page thanks to trimming', () {
    const text = 'line one\nline two\nline three\nline four';
    TextSpan buildSpan(int start, int end) =>
        TextSpan(text: text.substring(start, end), style: style);
    List<NativeTextPageRange> paginate(NativeTextFlowStyle flowStyle) {
      return NativeTextPaginator(
        maxWidth: 500,
        // Two full line boxes (72) minus a hair: without trimming only one
        // line fits, with trimming the first page gains the leading back.
        maxHeight: 2 * lineHeight * fontSize - 10,
        flowStyle: flowStyle,
      ).paginate(text: text, spanBuilder: buildSpan);
    }

    final untrimmed = paginate(
      const NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: null,
        strutStyle: null,
        textHeightBehavior: null,
      ),
    );
    final trimmed = paginate(
      NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: null,
        strutStyle: readerStrutStyle(style),
        textHeightBehavior: readerTextHeightBehavior,
      ),
    );

    expect(untrimmed.first.lineCount, 1);
    expect(trimmed.first.lineCount, 2);
  });

  test('reader flow defaults to natural alignment', () {
    const flow = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: Locale('zh', 'CN'),
      strutStyle: null,
      textHeightBehavior: readerTextHeightBehavior,
    );

    expect(flow.textAlign, TextAlign.start);
  });

  test('explicit justified flow fills both edges of wrapped Chinese lines', () {
    const width = 219.0;
    const bodyStyle = TextStyle(
      fontFamily: 'SourceHanSerifCN',
      fontSize: 20,
      letterSpacing: 0.2,
    );
    const flow = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: Locale('zh', 'CN'),
      strutStyle: StrutStyle(fontFamily: 'SourceHanSerifCN', fontSize: 20),
      textHeightBehavior: readerTextHeightBehavior,
      textAlign: TextAlign.justify,
    );
    final painter = flow.createPainter(
      TextSpan(text: List.filled(20, '开元阅读正文排版').join(), style: bodyStyle),
    )..layout(maxWidth: width);
    final lines = painter.computeLineMetrics();

    expect(flow.textAlign, TextAlign.justify);
    expect(lines.length, greaterThan(1));
    for (final line in lines.take(lines.length - 1)) {
      expect(line.left.abs(), lessThanOrEqualTo(0.25));
      expect(line.width, closeTo(width, 0.25));
    }
    painter.dispose();
  });

  test('shared paginator owns inline chapter title pagination', () {
    final text = List.generate(12, (index) => 'Line $index').join('\n');
    const flow = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: null,
      strutStyle: null,
      textHeightBehavior: readerTextHeightBehavior,
    );
    final plain = paginateReaderText(
      text: text,
      maxWidth: 500,
      maxHeight: 100,
      flowStyle: flow,
      style: style,
    );
    final withTitle = paginateReaderText(
      text: text,
      maxWidth: 500,
      maxHeight: 100,
      inlineChapterTitleExtent: 60,
      flowStyle: flow,
      style: style,
    );

    expect(withTitle.first.showsInlineChapterTitle, isTrue);
    expect(
      withTitle.skip(1).every((page) => !page.showsInlineChapterTitle),
      isTrue,
    );
    expect(withTitle.first.endOffset, lessThan(plain.first.endOffset));
  });

  test('inline title preserves unpaginated and empty chapter contracts', () {
    const flow = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: null,
      strutStyle: null,
      textHeightBehavior: readerTextHeightBehavior,
    );
    final continuous = paginateReaderText(
      text: 'one\ntwo\nthree',
      maxWidth: 500,
      maxHeight: 0,
      inlineChapterTitleExtent: 200,
      flowStyle: flow,
      style: style,
    );
    final finite = paginateReaderText(
      text: 'one\ntwo\nthree',
      maxWidth: 500,
      maxHeight: 80,
      inlineChapterTitleExtent: 200,
      flowStyle: flow,
      style: style,
    );
    final empty = paginateReaderText(
      text: '',
      maxWidth: 500,
      maxHeight: 80,
      inlineChapterTitleExtent: 40,
      flowStyle: flow,
      style: style,
    );

    expect(continuous, hasLength(1));
    expect(continuous.single.text, 'one\ntwo\nthree');
    expect(continuous.single.showsInlineChapterTitle, isTrue);
    expect(finite.length, greaterThan(1));
    expect(finite.first.showsInlineChapterTitle, isTrue);
    expect(empty, hasLength(1));
    expect(empty.single.showsInlineChapterTitle, isTrue);
  });

  test('dedicated and inline chapter title modes are mutually exclusive', () {
    expect(
      () => paginateReaderText(
        text: 'body',
        maxWidth: 500,
        maxHeight: 100,
        includeChapterTitlePage: true,
        inlineChapterTitleExtent: 40,
        flowStyle: const NativeTextFlowStyle(
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          locale: null,
          strutStyle: null,
          textHeightBehavior: readerTextHeightBehavior,
        ),
        style: style,
      ),
      throwsArgumentError,
    );
  });

  test(
    'incremental pagination matches synchronous pagination contracts',
    () async {
      const flow = NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: Locale('zh', 'CN'),
        strutStyle: null,
        textHeightBehavior: readerTextHeightBehavior,
      );
      final cases =
          <
            ({
              String text,
              int sourceOffset,
              int firstLineIndent,
              int paragraphSpacing,
              bool includeChapterTitlePage,
              double? inlineChapterTitleExtent,
            })
          >[
            (
              text: 'English paragraph wraps across pages. ' * 8,
              sourceOffset: 0,
              firstLineIndent: 0,
              paragraphSpacing: 0,
              includeChapterTitlePage: false,
              inlineChapterTitleExtent: null,
            ),
            (
              text: '第一段中文混合 English。\n\n第二段继续分页。' * 6,
              sourceOffset: 37,
              firstLineIndent: 2,
              paragraphSpacing: 1,
              includeChapterTitlePage: true,
              inlineChapterTitleExtent: null,
            ),
            (
              text: '  \n\n正文前有空白。\n下一段。   ',
              sourceOffset: 91,
              firstLineIndent: 2,
              paragraphSpacing: 2,
              includeChapterTitlePage: false,
              inlineChapterTitleExtent: 24,
            ),
            (
              text: '',
              sourceOffset: 12,
              firstLineIndent: 2,
              paragraphSpacing: 1,
              includeChapterTitlePage: false,
              inlineChapterTitleExtent: null,
            ),
            (
              text: ' \n\t\n ',
              sourceOffset: 5,
              firstLineIndent: 0,
              paragraphSpacing: 0,
              includeChapterTitlePage: false,
              inlineChapterTitleExtent: null,
            ),
          ];

      for (final entry in cases) {
        final sync = paginateReaderText(
          text: entry.text,
          maxWidth: 180,
          maxHeight: 72,
          flowStyle: flow,
          style: style,
          sourceOffset: entry.sourceOffset,
          firstLineIndent: entry.firstLineIndent,
          paragraphSpacing: entry.paragraphSpacing,
          includeChapterTitlePage: entry.includeChapterTitlePage,
          inlineChapterTitleExtent: entry.inlineChapterTitleExtent,
        );
        final incremental = await paginateReaderTextIncrementally(
          text: entry.text,
          maxWidth: 180,
          maxHeight: 72,
          flowStyle: flow,
          style: style,
          sourceOffset: entry.sourceOffset,
          firstLineIndent: entry.firstLineIndent,
          paragraphSpacing: entry.paragraphSpacing,
          includeChapterTitlePage: entry.includeChapterTitlePage,
          inlineChapterTitleExtent: entry.inlineChapterTitleExtent,
          yieldBetweenPages: () async {},
        );

        expect(_pageSnapshots(incremental), _pageSnapshots(sync));
      }
    },
  );

  test(
    'incremental pagination yields before the chapter is measured',
    () async {
      const flow = NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: null,
        strutStyle: null,
        textHeightBehavior: readerTextHeightBehavior,
      );
      final enteredYield = Completer<void>();
      final resume = Completer<void>();
      var spanBuilds = 0;
      final result = paginateReaderTextIncrementally(
        text: 'A long line of words that needs several pages. ' * 20,
        maxWidth: 140,
        maxHeight: 54,
        flowStyle: flow,
        style: style,
        sourceSpanBuilder: (start, end) {
          spanBuilds++;
          return TextSpan(text: 'x' * (end - start), style: style);
        },
        yieldBetweenPages: () async {
          if (!enteredYield.isCompleted) {
            enteredYield.complete();
            await resume.future;
          }
        },
      );

      await enteredYield.future;
      expect(spanBuilds, 0);
      var completed = false;
      result.whenComplete(() => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      resume.complete();
      expect(await result, hasLength(greaterThan(1)));
    },
  );

  test(
    'incremental pagination stops measuring when yielding cancels',
    () async {
      const flow = NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: null,
        strutStyle: null,
        textHeightBehavior: readerTextHeightBehavior,
      );
      final cancellation = StateError('cancel pagination');
      var yields = 0;
      var spanBuilds = 0;

      final result = paginateReaderTextIncrementally(
        text: 'page content ' * 100,
        maxWidth: 120,
        maxHeight: 50,
        flowStyle: flow,
        style: style,
        sourceSpanBuilder: (start, end) {
          spanBuilds++;
          return TextSpan(text: 'x' * (end - start), style: style);
        },
        yieldBetweenPages: () async {
          yields++;
          if (yields == 2) throw cancellation;
        },
      );

      await expectLater(result, throwsA(same(cancellation)));
      final buildsAtCancellation = spanBuilds;
      await Future<void>.delayed(Duration.zero);
      expect(yields, 2);
      expect(buildsAtCancellation, greaterThan(0));
      expect(spanBuilds, buildsAtCancellation);
    },
  );
}

List<Object?> _pageSnapshots(List<ReaderTextPage> pages) => pages
    .map(
      (page) => <Object?>[
        page.text,
        page.startOffset,
        page.endOffset,
        page.layoutStart,
        page.layoutEnd,
        page.displayStart,
        page.displayEnd,
        page.isChapterTitle,
        page.showsInlineChapterTitle,
      ],
    )
    .toList();
