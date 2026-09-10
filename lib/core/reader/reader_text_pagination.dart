import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'native_text_paginator.dart';
import 'reader_text_layout.dart';

/// The maximum width of a single flowing-text leaf.
///
/// Local files and book-source chapters must resolve their content box through
/// this same rule so an identical chapter produces identical line breaks.
const double readerMaxTextContentWidth = 760;

double readerTextContentWidth(double viewportWidth, double horizontalMargin) =>
    (viewportWidth - horizontalMargin * 2).clamp(
      0.0,
      readerMaxTextContentWidth,
    );

double readerTextContentHeight(
  double viewportHeight,
  double topInset,
  double bottomInset,
) => (viewportHeight - topInset - bottomInset).clamp(0.0, double.infinity);

@immutable
class ReaderTextPage {
  const ReaderTextPage({
    required this.text,
    this.startOffset = 0,
    int? endOffset,
    this.layout,
    int? layoutStart,
    int? layoutEnd,
    this.displayStart = 0,
    int? displayEnd,
    this.isChapterTitle = false,
    this.showsInlineChapterTitle = false,
  }) : endOffset = endOffset ?? startOffset + text.length,
       layoutStart = layoutStart ?? displayStart,
       layoutEnd = layoutEnd ?? (displayEnd ?? displayStart + text.length),
       displayEnd = displayEnd ?? displayStart + text.length,
       assert((layoutStart ?? displayStart) <= displayStart),
       assert(
         (displayEnd ?? displayStart + text.length) <=
             (layoutEnd ?? (displayEnd ?? displayStart + text.length)),
       ),
       assert(!isChapterTitle || !showsInlineChapterTitle);

  const ReaderTextPage.chapterTitle({int sourceOffset = 0})
    : text = '',
      startOffset = sourceOffset,
      endOffset = sourceOffset,
      layout = null,
      layoutStart = 0,
      layoutEnd = 0,
      displayStart = 0,
      displayEnd = 0,
      isChapterTitle = true,
      showsInlineChapterTitle = false;

  /// The complete display-text range owned by this page. It may include folded
  /// leading/trailing blank rows that remain addressable for source coverage.
  final String text;
  final int startOffset;
  final int endOffset;
  final ReaderTextLayout? layout;
  final int layoutStart;
  final int layoutEnd;

  /// Absolute boundaries in [layout] that are actually painted.
  final int displayStart;
  final int displayEnd;
  final bool isChapterTitle;
  final bool showsInlineChapterTitle;

  /// Compatibility name for the former book-source-only page model.
  bool get showsChapterTitle => isChapterTitle;

  /// Maps a UTF-16 offset in the text actually painted by this page back to
  /// the canonical chapter text. Generated indentation and paragraph spacing
  /// are therefore never persisted as annotation offsets.
  int sourceOffsetForTextOffset(
    int textOffset, {
    bool preferVisibleStart = false,
  }) {
    final visibleLength = (displayEnd - displayStart).clamp(0, text.length);
    final safeOffset = textOffset.clamp(0, visibleLength);
    final textLayout = layout;
    if (textLayout == null) {
      return (startOffset + safeOffset).clamp(startOffset, endOffset);
    }
    final displayOffset = displayStart + safeOffset;
    return preferVisibleStart
        ? textLayout.sourceOffsetForVisibleStart(displayOffset)
        : textLayout.sourceOffsetForDisplayOffset(displayOffset);
  }

  int textOffsetForSourceOffset(int sourceOffset) {
    final textLayout = layout;
    if (textLayout == null) {
      return (sourceOffset - startOffset).clamp(0, text.length);
    }
    final displayOffset = textLayout.displayOffsetForSourceOffset(sourceOffset);
    return (displayOffset - displayStart).clamp(0, displayEnd - displayStart);
  }

  TextSpan buildSpan({
    required TextStyle style,
    ReaderSourceSpanBuilder? sourceSpanBuilder,
  }) {
    final textLayout = layout;
    if (textLayout == null) {
      final sourceSpan = sourceSpanBuilder?.call(startOffset, endOffset);
      return switch (sourceSpan) {
        final TextSpan span => span,
        final InlineSpan span => TextSpan(style: style, children: [span]),
        null => TextSpan(text: text, style: style),
      };
    }
    return textLayout.buildSpan(
      displayStart,
      displayEnd,
      sourceSpanBuilder:
          sourceSpanBuilder ??
          (sourceStart, sourceEnd) {
            final localStart = sourceStart - textLayout.sourceOffset;
            final localEnd = sourceEnd - textLayout.sourceOffset;
            return TextSpan(
              text: textLayout.sourceText.substring(localStart, localEnd),
              style: style,
            );
          },
      generatedStyle: style,
    );
  }
}

/// Projects and paginates one canonical text range.
///
/// This is the single entry point used by local text chapters and online
/// source chapters. Source adapters may produce different canonical text, but
/// indentation, paragraph spacing, visual-line measurement, offsets and title
/// page semantics are owned here.
List<ReaderTextPage> paginateReaderText({
  required String text,
  required double maxWidth,
  required double maxHeight,
  required NativeTextFlowStyle flowStyle,
  required TextStyle style,
  int sourceOffset = 0,
  double? firstPageHeight,
  int firstLineIndent = 0,
  int paragraphSpacing = 0,
  bool indentFirstParagraph = true,
  bool normalizeParagraphBreaks = false,
  bool includeChapterTitlePage = false,
  double? inlineChapterTitleExtent,
  ReaderSourceSpanBuilder? sourceSpanBuilder,
}) {
  _validateChapterTitleLayout(
    includeChapterTitlePage: includeChapterTitlePage,
    inlineChapterTitleExtent: inlineChapterTitleExtent,
  );
  return developer.Timeline.timeSync(
    'paginateReaderText',
    arguments: {'chars': text.length},
    () => _paginateReaderText(
      text: text,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      flowStyle: flowStyle,
      style: style,
      sourceOffset: sourceOffset,
      firstPageHeight: firstPageHeight,
      firstLineIndent: firstLineIndent,
      paragraphSpacing: paragraphSpacing,
      indentFirstParagraph: indentFirstParagraph,
      normalizeParagraphBreaks: normalizeParagraphBreaks,
      includeChapterTitlePage: includeChapterTitlePage,
      inlineChapterTitleExtent: inlineChapterTitleExtent,
      sourceSpanBuilder: sourceSpanBuilder,
    ),
  );
}

/// Paginates through the same shared engine as [paginateReaderText], yielding
/// before each measured body page so long chapters do not monopolize the UI
/// isolate. Throwing from [yieldBetweenPages] cancels before the next page is
/// measured.
Future<List<ReaderTextPage>> paginateReaderTextIncrementally({
  required String text,
  required double maxWidth,
  required double maxHeight,
  required NativeTextFlowStyle flowStyle,
  required TextStyle style,
  required Future<void> Function() yieldBetweenPages,
  int sourceOffset = 0,
  double? firstPageHeight,
  int firstLineIndent = 0,
  int paragraphSpacing = 0,
  bool indentFirstParagraph = true,
  bool normalizeParagraphBreaks = false,
  bool includeChapterTitlePage = false,
  double? inlineChapterTitleExtent,
  ReaderSourceSpanBuilder? sourceSpanBuilder,
}) async {
  _validateChapterTitleLayout(
    includeChapterTitlePage: includeChapterTitlePage,
    inlineChapterTitleExtent: inlineChapterTitleExtent,
  );
  final plan = _ReaderTextPaginationPlan.create(
    text: text,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    flowStyle: flowStyle,
    style: style,
    sourceOffset: sourceOffset,
    firstPageHeight: firstPageHeight,
    firstLineIndent: firstLineIndent,
    paragraphSpacing: paragraphSpacing,
    indentFirstParagraph: indentFirstParagraph,
    normalizeParagraphBreaks: normalizeParagraphBreaks,
    includeChapterTitlePage: includeChapterTitlePage,
    inlineChapterTitleExtent: inlineChapterTitleExtent,
    sourceSpanBuilder: sourceSpanBuilder,
  );
  final ranges = plan.ranges;
  if (ranges == null) return plan.pages;

  final iterator = ranges.iterator;
  var bodyPageIndex = 0;
  while (true) {
    await yieldBetweenPages();
    final hasPage = iterator.moveNext();
    if (!hasPage) {
      throw StateError('Pagination ended before covering the chapter text.');
    }
    final range = iterator.current;
    plan.addRange(range, bodyPageIndex++);
    if (range.end == plan.layout.text.length) break;
  }
  plan.assertComplete();
  return plan.pages;
}

List<ReaderTextPage> _paginateReaderText({
  required String text,
  required double maxWidth,
  required double maxHeight,
  required NativeTextFlowStyle flowStyle,
  required TextStyle style,
  int sourceOffset = 0,
  double? firstPageHeight,
  int firstLineIndent = 0,
  int paragraphSpacing = 0,
  bool indentFirstParagraph = true,
  bool normalizeParagraphBreaks = false,
  bool includeChapterTitlePage = false,
  double? inlineChapterTitleExtent,
  ReaderSourceSpanBuilder? sourceSpanBuilder,
}) {
  final plan = _ReaderTextPaginationPlan.create(
    text: text,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    flowStyle: flowStyle,
    style: style,
    sourceOffset: sourceOffset,
    firstPageHeight: firstPageHeight,
    firstLineIndent: firstLineIndent,
    paragraphSpacing: paragraphSpacing,
    indentFirstParagraph: indentFirstParagraph,
    normalizeParagraphBreaks: normalizeParagraphBreaks,
    includeChapterTitlePage: includeChapterTitlePage,
    inlineChapterTitleExtent: inlineChapterTitleExtent,
    sourceSpanBuilder: sourceSpanBuilder,
  );
  final ranges = plan.ranges;
  if (ranges != null) {
    var bodyPageIndex = 0;
    for (final range in ranges) {
      plan.addRange(range, bodyPageIndex++);
    }
    plan.assertComplete();
  }
  return plan.pages;
}

void _validateChapterTitleLayout({
  required bool includeChapterTitlePage,
  required double? inlineChapterTitleExtent,
}) {
  if (includeChapterTitlePage && inlineChapterTitleExtent != null) {
    throw ArgumentError(
      'Dedicated and inline chapter title modes cannot be combined.',
    );
  }
  if (inlineChapterTitleExtent != null &&
      (!inlineChapterTitleExtent.isFinite || inlineChapterTitleExtent < 0)) {
    throw ArgumentError.value(
      inlineChapterTitleExtent,
      'inlineChapterTitleExtent',
      'must be finite and non-negative',
    );
  }
}

class _ReaderTextPaginationPlan {
  _ReaderTextPaginationPlan({
    required this.pages,
    required this.layout,
    required this.sourceEnd,
    required this.inlineChapterTitleExtent,
    required this.ranges,
  });

  factory _ReaderTextPaginationPlan.create({
    required String text,
    required double maxWidth,
    required double maxHeight,
    required NativeTextFlowStyle flowStyle,
    required TextStyle style,
    required int sourceOffset,
    required double? firstPageHeight,
    required int firstLineIndent,
    required int paragraphSpacing,
    required bool indentFirstParagraph,
    required bool normalizeParagraphBreaks,
    required bool includeChapterTitlePage,
    required double? inlineChapterTitleExtent,
    required ReaderSourceSpanBuilder? sourceSpanBuilder,
  }) {
    final pages = <ReaderTextPage>[
      if (includeChapterTitlePage)
        ReaderTextPage.chapterTitle(sourceOffset: sourceOffset),
    ];
    final layout = ReaderTextLayout.build(
      text,
      sourceOffset: sourceOffset,
      firstLineIndent: firstLineIndent,
      paragraphSpacing: paragraphSpacing,
      indentFirstParagraph: indentFirstParagraph,
      normalizeParagraphBreaks: normalizeParagraphBreaks,
    );
    final effectiveFirstPageHeight = _inlineTitleBodyHeight(
      maxHeight: maxHeight,
      firstPageHeight: firstPageHeight,
      inlineChapterTitleExtent: inlineChapterTitleExtent,
    );

    if (layout.text.isEmpty) {
      if (pages.isEmpty || text.isNotEmpty) {
        pages.add(
          ReaderTextPage(
            text: '',
            startOffset: sourceOffset,
            endOffset: sourceOffset + text.length,
            layout: layout,
            showsInlineChapterTitle: inlineChapterTitleExtent != null,
          ),
        );
      }
      return _ReaderTextPaginationPlan(
        pages: pages,
        layout: layout,
        sourceEnd: sourceOffset + text.length,
        inlineChapterTitleExtent: inlineChapterTitleExtent,
        ranges: null,
      );
    }

    if (maxWidth <= 0 ||
        maxHeight <= 0 ||
        (effectiveFirstPageHeight ?? maxHeight) <= 0) {
      pages.add(
        ReaderTextPage(
          text: layout.text,
          startOffset: sourceOffset,
          endOffset: sourceOffset + text.length,
          layout: layout,
          displayEnd: layout.text.length,
          showsInlineChapterTitle: inlineChapterTitleExtent != null,
        ),
      );
      return _ReaderTextPaginationPlan(
        pages: pages,
        layout: layout,
        sourceEnd: sourceOffset + text.length,
        inlineChapterTitleExtent: inlineChapterTitleExtent,
        ranges: null,
      );
    }

    TextSpan buildSpan(int start, int end) => layout.buildSpan(
      start,
      end,
      sourceSpanBuilder:
          sourceSpanBuilder ??
          (sourceStart, sourceEnd) {
            final localStart = sourceStart - layout.sourceOffset;
            final localEnd = sourceEnd - layout.sourceOffset;
            return TextSpan(
              text: layout.sourceText.substring(localStart, localEnd),
              style: style,
            );
          },
      generatedStyle: style,
    );

    return _ReaderTextPaginationPlan(
      pages: pages,
      layout: layout,
      sourceEnd: sourceOffset + text.length,
      inlineChapterTitleExtent: inlineChapterTitleExtent,
      ranges:
          NativeTextPaginator(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            flowStyle: flowStyle,
          ).paginatePages(
            text: layout.text,
            spanBuilder: buildSpan,
            firstPageHeight: effectiveFirstPageHeight,
          ),
    );
  }

  final List<ReaderTextPage> pages;
  final ReaderTextLayout layout;
  final int sourceEnd;
  final double? inlineChapterTitleExtent;
  final Iterable<NativeTextPageRange>? ranges;

  void addRange(NativeTextPageRange range, int bodyPageIndex) {
    pages.add(
      ReaderTextPage(
        text: layout.text.substring(range.start, range.end),
        startOffset: layout.sourceOffsetForDisplayOffset(range.start),
        endOffset: layout.sourceOffsetForDisplayOffset(range.end),
        layout: layout,
        layoutStart: range.start,
        layoutEnd: range.end,
        displayStart: range.visibleStart,
        displayEnd: range.visibleEnd,
        showsInlineChapterTitle:
            inlineChapterTitleExtent != null && bodyPageIndex == 0,
      ),
    );
  }

  void assertComplete() {
    assert(pages.isNotEmpty);
    assert(pages.first.startOffset == layout.sourceOffset);
    assert(pages.last.endOffset == sourceEnd);
    for (var index = 1; index < pages.length; index++) {
      assert(pages[index - 1].endOffset == pages[index].startOffset);
    }
  }
}

double? _inlineTitleBodyHeight({
  required double maxHeight,
  required double? firstPageHeight,
  required double? inlineChapterTitleExtent,
}) {
  if (inlineChapterTitleExtent == null || maxHeight <= 0) {
    return firstPageHeight;
  }
  final availableHeight = firstPageHeight ?? maxHeight;
  if (!availableHeight.isFinite) return availableHeight;
  return (availableHeight - inlineChapterTitleExtent)
      .clamp(1.0, double.infinity)
      .toDouble();
}

int readerTextPageIndexForOffset(List<ReaderTextPage> pages, int offset) {
  if (pages.isEmpty) return 0;
  final minOffset = pages.first.startOffset;
  final maxOffset = pages.last.endOffset;
  final safeOffset = offset.clamp(minOffset, maxOffset);
  final index = pages.indexWhere(
    (page) =>
        !page.isChapterTitle &&
        safeOffset >= page.startOffset &&
        safeOffset < page.endOffset,
  );
  return index >= 0 ? index : pages.length - 1;
}
