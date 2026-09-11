import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xxread/pages/reader/comic/comic_scroll_controller.dart';

import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_volume_key_controller.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/pages/reader/image/image_reader_chrome.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

class ContinuousImageReader extends StatefulWidget {
  const ContinuousImageReader({
    super.key,
    required this.document,
    required this.source,
    required this.initialChapterIndex,
    required this.initialPageIndex,
    required this.onTableOfContents,
    required this.onSettings,
    required this.onChangeReadingMode,
    this.palette,
  });

  final ImageReaderDocument document;
  final ImageReaderSource source;
  final int initialChapterIndex;
  final int initialPageIndex;
  final VoidCallback? onTableOfContents;
  final VoidCallback onSettings;
  final VoidCallback onChangeReadingMode;
  final ReaderThemePalette? palette;

  @visibleForTesting
  static const chapterBoundaryKeyPrefix = 'continuous-chapter-boundary-';

  @visibleForTesting
  static const emptyChapterKeyPrefix = 'continuous-empty-chapter-';

  @visibleForTesting
  static const settingsButtonKey = ValueKey('continuous-reader-settings');

  @visibleForTesting
  static const modeButtonKey = ValueKey('continuous-reader-mode');

  @visibleForTesting
  static const pageKeyPrefix = 'continuous-page-';

  @visibleForTesting
  static const pageContentKeyPrefix = 'continuous-page-content-';

  @override
  State<ContinuousImageReader> createState() => _ContinuousImageReaderState();
}

class _ContinuousImageReaderState extends State<ContinuousImageReader> {
  final ComicScrollController _scrollController = ComicScrollController();
  final Map<int, Future<int>> _countLoads = {};
  final Map<int, int> _counts = {};
  final Set<int> _prefetchedChapters = {};
  final Map<({int chapterIndex, int pageIndex}), double> _pageAspectRatios = {};

  List<_ContinuousEntry> _entries = const [];
  late int _currentChapter = widget.initialChapterIndex;
  late int _currentPage = widget.initialPageIndex;
  bool _chromeVisible = false;
  int _windowGeneration = 0;
  bool _windowLoadInFlight = false;
  int? _pendingWindowChapter;

  ReaderThemePalette get _palette => widget.palette ?? widget.source.theme;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handlePositions);
    unawaited(ReaderKeepScreenOnController.activate(this));
    unawaited(_activateVolumeKeys());
    unawaited(_ensureWindow(widget.initialChapterIndex));
  }

  @override
  void dispose() {
    unawaited(ReaderVolumeKeyController.deactivate(this));
    unawaited(ReaderKeepScreenOnController.deactivate(this));
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _activateVolumeKeys() {
    return ReaderVolumeKeyController.activate(
      owner: this,
      pageTurningAvailable: true,
      onNextPage: _nextPage,
      onPreviousPage: _previousPage,
    );
  }

  Future<int> _loadCount(int chapterIndex) {
    final cached = _counts[chapterIndex];
    if (cached != null) return Future.value(cached);
    return _countLoads.putIfAbsent(chapterIndex, () async {
      try {
        final count = await widget.source.loadChapterPageCount(chapterIndex);
        _counts[chapterIndex] = count;
        return count;
      } finally {
        _countLoads.remove(chapterIndex);
      }
    });
  }

  Future<void> _ensureWindow(int anchorChapter) async {
    final generation = ++_windowGeneration;
    final requestedFirst = (anchorChapter - 1).clamp(
      0,
      widget.document.chapters.length - 1,
    );
    final requestedLast = (anchorChapter + 1).clamp(
      0,
      widget.document.chapters.length - 1,
    );
    var first = requestedFirst;
    var last = requestedLast;
    final loads = <Future<int>>[
      for (var index = first; index <= last; index++) _loadCount(index),
    ];
    await Future.wait(loads);
    if (!mounted || generation != _windowGeneration) return;
    // Keep any chapter still visible while a neighbor count was loading.
    if (_entries.isNotEmpty && _scrollController.hasClients) {
      final visible =
          _entries[_scrollController.indexAt(_scrollController.offset)]
              .chapterIndex;
      final visibleLast =
          _entries[_scrollController.indexAt(
                _scrollController.offset +
                    _scrollController.position.viewportDimension -
                    0.01,
              )]
              .chapterIndex;
      final keepFirst = (visible - 1).clamp(_windowFirst, _windowLast);
      final keepLast = (visibleLast + 1).clamp(_windowFirst, _windowLast);
      if (keepFirst < first) first = keepFirst;
      if (keepLast > last) last = keepLast;
    }
    _counts.removeWhere((chapter, _) => chapter < first || chapter > last);
    _prefetchedChapters.removeWhere(
      (chapter) => chapter < first || chapter > last,
    );
    widget.source.retainChapterWindow(first, last);
    final entries = <_ContinuousEntry>[];
    for (var chapter = first; chapter <= last; chapter++) {
      if (chapter > 0) {
        entries.add(
          _ContinuousEntry.boundary(
            chapterIndex: chapter,
            title: widget.document.chapters[chapter].title,
          ),
        );
      }
      final count = _counts[chapter] ?? 0;
      if (count <= 0) {
        entries.add(_ContinuousEntry.empty(chapterIndex: chapter));
      } else {
        for (var page = 0; page < count; page++) {
          entries.add(
            _ContinuousEntry.page(
              chapterIndex: chapter,
              pageIndex: page,
              pageCount: count,
            ),
          );
        }
      }
    }
    setState(() => _entries = List.unmodifiable(entries));
    _pageAspectRatios.removeWhere(
      (page, _) => page.chapterIndex < first || page.chapterIndex > last,
    );
    _prefetchAdjacentChapters(anchorChapter);
  }

  void _prefetchAdjacentChapters(int chapterIndex) {
    for (final neighbor in [chapterIndex - 1, chapterIndex + 1]) {
      if (neighbor < 0 || neighbor >= widget.document.chapters.length) continue;
      if (!_prefetchedChapters.add(neighbor)) continue;
      unawaited(_prefetchChapter(neighbor));
    }
  }

  Future<void> _prefetchChapter(int chapterIndex) async {
    try {
      final count = await _loadCount(chapterIndex);
      for (final page in [0, 1]) {
        if (page >= count) break;
        final bytes = await widget.source.loadPage(
          chapterIndex,
          page,
          preload: true,
        );
        if (!mounted) return;
        final ratio = await _imageAspectRatio(bytes);
        if (!mounted) return;
        _recordAspectRatio(chapterIndex, page, ratio);
        if (chapterIndex < _windowFirst || chapterIndex > _windowLast) return;
        await precacheImage(
          MemoryImage(bytes),
          context,
          onError: (error, stack) => comicDebugLog(
            'chapter-preload',
            'image decode failed chapterIndex=$chapterIndex page=$page',
            error: error,
            stackTrace: stack,
          ),
        );
      }
    } catch (error, stackTrace) {
      _prefetchedChapters.remove(chapterIndex);
      comicDebugLog(
        'chapter-preload',
        'failed chapterIndex=$chapterIndex',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handlePositions() {
    if (!mounted || _entries.isEmpty || !_scrollController.hasClients) return;
    var index = _scrollController.indexAt(_scrollController.offset);
    if (_entries[index].kind == _ContinuousEntryKind.boundary) {
      index = (index + 1).clamp(0, _entries.length - 1);
    }
    final entry = _entries[index];
    final lastVisible = _scrollController.indexAt(
      _scrollController.offset + _scrollController.position.viewportDimension,
    );
    final enteringChapter = _entries[lastVisible].chapterIndex;
    if (entry.chapterIndex == _windowFirst) {
      unawaited(_recenterWindow(entry.chapterIndex));
    }
    if (enteringChapter == _windowLast) {
      unawaited(_recenterWindow(enteringChapter));
    }
    final chapterChanged = entry.chapterIndex != _currentChapter;
    final pageChanged =
        entry.kind == _ContinuousEntryKind.page &&
        entry.pageIndex != _currentPage;
    if (!chapterChanged && !pageChanged) return;
    setState(() {
      _currentChapter = entry.chapterIndex;
      _currentPage = entry.kind == _ContinuousEntryKind.page
          ? entry.pageIndex
          : 0;
    });
    if (entry.kind == _ContinuousEntryKind.page) {
      unawaited(
        widget.source.saveProgress(
          chapterIndex: entry.chapterIndex,
          pageIndex: entry.pageIndex,
          pageCount: entry.pageCount,
        ),
      );
    }
    _prefetchAdjacentChapters(entry.chapterIndex);
  }

  int get _windowFirst {
    for (final entry in _entries) {
      if (entry.kind == _ContinuousEntryKind.page ||
          entry.kind == _ContinuousEntryKind.empty) {
        return entry.chapterIndex;
      }
    }
    return _currentChapter;
  }

  int get _windowLast {
    for (final entry in _entries.reversed) {
      if (entry.kind == _ContinuousEntryKind.page ||
          entry.kind == _ContinuousEntryKind.empty) {
        return entry.chapterIndex;
      }
    }
    return _currentChapter;
  }

  Future<void> _recenterWindow(int chapterIndex) async {
    if (chapterIndex <= 0 ||
        chapterIndex >= widget.document.chapters.length - 1 ||
        (_windowFirst <= chapterIndex - 1 && _windowLast >= chapterIndex + 1)) {
      return;
    }
    if (_windowLoadInFlight) {
      _pendingWindowChapter = chapterIndex;
      return;
    }

    _windowLoadInFlight = true;
    var nextChapter = chapterIndex;
    try {
      while (mounted) {
        _pendingWindowChapter = null;
        await _ensureWindow(nextChapter);
        final pending = _pendingWindowChapter;
        if (pending == null ||
            pending <= 0 ||
            pending >= widget.document.chapters.length - 1 ||
            (_windowFirst <= pending - 1 && _windowLast >= pending + 1)) {
          return;
        }
        nextChapter = pending;
      }
    } finally {
      _windowLoadInFlight = false;
    }
  }

  int _entryIndexFor(int chapterIndex, int pageIndex) {
    final page = _entries.indexWhere(
      (entry) =>
          entry.kind == _ContinuousEntryKind.page &&
          entry.chapterIndex == chapterIndex &&
          entry.pageIndex == pageIndex,
    );
    if (page >= 0) return page;
    return _entries.indexWhere(
      (entry) =>
          entry.kind == _ContinuousEntryKind.empty &&
          entry.chapterIndex == chapterIndex,
    );
  }

  void _goToCurrentOffset(int delta) {
    final current = _entryIndexFor(_currentChapter, _currentPage);
    if (current < 0) return;
    var target = current + delta;
    while (target >= 0 && target < _entries.length) {
      if (_entries[target].kind == _ContinuousEntryKind.page) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.offsetOf(target));
        }
        return;
      }
      target += delta.sign;
    }
  }

  void _nextPage() => _goToCurrentOffset(1);

  void _previousPage() => _goToCurrentOffset(-1);

  void _goToPage(int pageIndex) {
    final target = _entryIndexFor(_currentChapter, pageIndex);
    if (target < 0 || !_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.offsetOf(target));
  }

  void _handleTap(Offset position, Size size) {
    if (_chromeVisible) {
      setState(() => _chromeVisible = false);
      return;
    }
    final centerStart = size.width * 0.28;
    final centerEnd = size.width * 0.72;
    if (position.dx >= centerStart && position.dx <= centerEnd) {
      setState(() => _chromeVisible = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = _counts[_currentChapter] ?? 0;
    final displayPage = pageCount > 0 ? _currentPage + 1 : 0;
    return ColoredBox(
      color: _palette.background,
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_entries.isNotEmpty) {
                  _scrollController.updateGeometry(
                    [for (final entry in _entries) entry.key],
                    [
                      for (final entry in _entries)
                        _entryExtent(context, entry, constraints.maxWidth),
                    ],
                    initialIndex: _entryIndexFor(_currentChapter, _currentPage),
                  );
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) =>
                      _handleTap(details.localPosition, constraints.biggest),
                  child: _entries.isEmpty
                      ? _ReaderLoadingState(
                          palette: _palette,
                          label:
                              widget.document.chapters[_currentChapter].title,
                        )
                      : NotificationListener<ScrollMetricsNotification>(
                          onNotification: (_) {
                            _handlePositions();
                            return false;
                          },
                          child: ListView.builder(
                            controller: _scrollController,
                            itemExtentBuilder: (index, _) =>
                                _scrollController.extentOf(index),
                            findChildIndexCallback: _scrollController.indexOf,
                            itemCount: _entries.length,
                            padding: EdgeInsets.zero,
                            addAutomaticKeepAlives: false,
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              return switch (entry.kind) {
                                _ContinuousEntryKind.boundary =>
                                  _ChapterBoundary(
                                    key: entry.key,
                                    palette: _palette,
                                    title: entry.title,
                                  ),
                                _ContinuousEntryKind.empty => _EmptyChapter(
                                  key: entry.key,
                                  palette: _palette,
                                  message: widget.source.emptyPagesMessage(
                                    context.l10n,
                                  ),
                                  onRetry: () => unawaited(
                                    _retryChapter(entry.chapterIndex),
                                  ),
                                ),
                                _ContinuousEntryKind.page =>
                                  _ContinuousChapterPage(
                                    key: entry.key,
                                    source: widget.source,
                                    chapterIndex: entry.chapterIndex,
                                    pageIndex: entry.pageIndex,
                                    palette: _palette,
                                    knownAspectRatio:
                                        _pageAspectRatios[(
                                          chapterIndex: entry.chapterIndex,
                                          pageIndex: entry.pageIndex,
                                        )],
                                    onAspectRatio: (aspectRatio) =>
                                        _recordAspectRatio(
                                          entry.chapterIndex,
                                          entry.pageIndex,
                                          aspectRatio,
                                        ),
                                  ),
                              };
                            },
                          ),
                        ),
                );
              },
            ),
          ),
          _ProgressPill(
            palette: _palette,
            visible: !_chromeVisible,
            page: displayPage,
            pageCount: pageCount,
            chapterTitle: widget.document.chapters[_currentChapter].title,
          ),
          ImageReaderChrome(
            palette: _palette,
            visible: _chromeVisible,
            title: widget.document.chapters[_currentChapter].title,
            pageIndex: _currentPage,
            pageCount: pageCount,
            directionIcon: Icons.swap_vert_rounded,
            directionLabel: context.l10n.imageReaderDirectionVertical,
            onBack: () {
              BookOpenTransition.beginExit();
              Navigator.of(context).maybePop();
            },
            onPageSelected: _goToPage,
            onTableOfContents: widget.onTableOfContents,
            directionKey: ContinuousImageReader.modeButtonKey,
            settingsKey: ContinuousImageReader.settingsButtonKey,
            onDirection: widget.onChangeReadingMode,
            onSettings: widget.onSettings,
          ),
        ],
      ),
    );
  }

  void _recordAspectRatio(int chapter, int page, double ratio) {
    if (chapter < _windowFirst || chapter > _windowLast) return;
    final key = (chapterIndex: chapter, pageIndex: page);
    if (_pageAspectRatios[key] == ratio) return;
    setState(() => _pageAspectRatios[key] = ratio);
  }

  double _entryExtent(
    BuildContext context,
    _ContinuousEntry entry,
    double width,
  ) {
    if (entry.kind == _ContinuousEntryKind.page) {
      return width /
          (_pageAspectRatios[(
                chapterIndex: entry.chapterIndex,
                pageIndex: entry.pageIndex,
              )] ??
              _defaultPageAspectRatio);
    }
    final boundary = entry.kind == _ContinuousEntryKind.boundary;
    final painter = TextPainter(
      text: TextSpan(
        text: boundary
            ? entry.title
            : widget.source.emptyPagesMessage(context.l10n),
        style: DefaultTextStyle.of(context).style.merge(
          boundary ? _chapterTitleStyle : const TextStyle(height: 1.4),
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: boundary ? 2 : null,
    )..layout(maxWidth: (width - 48).clamp(1, double.infinity));
    final height = painter.height;
    painter.dispose();
    return boundary ? height + 81 : height + 176;
  }

  Future<void> _retryChapter(int chapterIndex) async {
    widget.source.invalidateChapter(chapterIndex);
    _counts.remove(chapterIndex);
    _prefetchedChapters.remove(chapterIndex);
    await _ensureWindow(chapterIndex);
  }
}

enum _ContinuousEntryKind { page, boundary, empty }

class _ContinuousEntry {
  const _ContinuousEntry._({
    required this.kind,
    required this.chapterIndex,
    this.pageIndex = 0,
    this.pageCount = 0,
    this.title = '',
  });

  factory _ContinuousEntry.page({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  }) => _ContinuousEntry._(
    kind: _ContinuousEntryKind.page,
    chapterIndex: chapterIndex,
    pageIndex: pageIndex,
    pageCount: pageCount,
  );

  factory _ContinuousEntry.boundary({
    required int chapterIndex,
    required String title,
  }) => _ContinuousEntry._(
    kind: _ContinuousEntryKind.boundary,
    chapterIndex: chapterIndex,
    title: title,
  );

  factory _ContinuousEntry.empty({required int chapterIndex}) =>
      _ContinuousEntry._(
        kind: _ContinuousEntryKind.empty,
        chapterIndex: chapterIndex,
      );

  final _ContinuousEntryKind kind;
  final int chapterIndex;
  final int pageIndex;
  final int pageCount;
  final String title;

  Key get key => ValueKey(switch (kind) {
    _ContinuousEntryKind.page =>
      '${ContinuousImageReader.pageKeyPrefix}$chapterIndex-$pageIndex',
    _ContinuousEntryKind.boundary =>
      '${ContinuousImageReader.chapterBoundaryKeyPrefix}$chapterIndex',
    _ContinuousEntryKind.empty =>
      '${ContinuousImageReader.emptyChapterKeyPrefix}$chapterIndex',
  });
}

class _ContinuousChapterPage extends StatefulWidget {
  const _ContinuousChapterPage({
    super.key,
    required this.source,
    required this.chapterIndex,
    required this.pageIndex,
    required this.palette,
    required this.knownAspectRatio,
    required this.onAspectRatio,
  });

  final ImageReaderSource source;
  final int chapterIndex;
  final int pageIndex;
  final ReaderThemePalette palette;
  final double? knownAspectRatio;
  final ValueChanged<double> onAspectRatio;

  @override
  State<_ContinuousChapterPage> createState() => _ContinuousChapterPageState();
}

class _ContinuousChapterPageState extends State<_ContinuousChapterPage> {
  MemoryImage? _provider;
  Object? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _ContinuousChapterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source) ||
        oldWidget.chapterIndex != widget.chapterIndex ||
        oldWidget.pageIndex != widget.pageIndex) {
      _provider = null;
      _error = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final bytes = await widget.source.loadPage(
        widget.chapterIndex,
        widget.pageIndex,
      );
      if (!mounted || generation != _loadGeneration) return;
      final ratio = await _imageAspectRatio(bytes);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _provider = MemoryImage(bytes);
      });
      widget.onAspectRatio(ratio);
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = error);
    }
  }

  Future<void> _retry() async {
    _loadGeneration++;
    await widget.source.invalidatePage(widget.chapterIndex, widget.pageIndex);
    if (!mounted) return;
    setState(() {
      _provider = null;
      _error = null;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = widget.knownAspectRatio ?? _defaultPageAspectRatio;
    if (_error != null) {
      return _PageErrorState(
        palette: widget.palette,
        pageNumber: widget.pageIndex + 1,
        onRetry: _retry,
      );
    }
    final provider = _provider;
    if (provider == null) {
      return _PageLoadingPlaceholder(
        palette: widget.palette,
        pageNumber: widget.pageIndex + 1,
        aspectRatio: aspectRatio,
      );
    }
    return KeyedSubtree(
      key: ValueKey(
        '${ContinuousImageReader.pageContentKeyPrefix}${widget.chapterIndex}-${widget.pageIndex}',
      ),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Image(
          image: provider,
          width: double.infinity,
          fit: BoxFit.fitWidth,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _PageErrorState(
            palette: widget.palette,
            pageNumber: widget.pageIndex + 1,
            onRetry: _retry,
          ),
        ),
      ),
    );
  }
}

const double _defaultPageAspectRatio = 1.0;

/// Read dimensions with the same decoder used to render the page. A guessed or
/// clamped ratio gives fitWidth a shorter box and crops valid long-strip art.
Future<double> _imageAspectRatio(Uint8List bytes) async {
  // Encoded ImageDescriptor dimensions are unavailable on Flutter web.
  if (kIsWeb) {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        return frame.image.width / frame.image.height;
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return descriptor.width / descriptor.height;
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

const _chapterTitleStyle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  height: 1.25,
);

class _ChapterBoundary extends StatelessWidget {
  const _ChapterBoundary({
    super.key,
    required this.palette,
    required this.title,
  });

  final ReaderThemePalette palette;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.background,
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 30),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 3,
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: _chapterTitleStyle.copyWith(color: palette.text),
          ),
        ],
      ),
    );
  }
}

class _ProgressPill extends StatelessWidget {
  const _ProgressPill({
    required this.palette,
    required this.visible,
    required this.page,
    required this.pageCount,
    required this.chapterTitle,
  });

  final ReaderThemePalette palette;
  final bool visible;
  final int page;
  final int pageCount;
  final String chapterTitle;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 14,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Semantics(
            label: '$chapterTitle $page / $pageCount',
            child: ReaderControlBar(
              palette: palette,
              isTopBar: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                child: Text(
                  '$page / $pageCount',
                  style: TextStyle(
                    color: palette.secondaryText,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderLoadingState extends StatelessWidget {
  const _ReaderLoadingState({required this.palette, required this.label});

  final ReaderThemePalette palette;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: palette.secondaryText,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.secondaryText,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageLoadingPlaceholder extends StatelessWidget {
  const _PageLoadingPlaceholder({
    required this.palette,
    required this.pageNumber,
    required this.aspectRatio,
  });

  final ReaderThemePalette palette;
  final int pageNumber;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Container(
        color: palette.background,
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: palette.secondaryText.withValues(alpha: 0.56),
            semanticsLabel: '$pageNumber',
          ),
        ),
      ),
    );
  }
}

class _PageErrorState extends StatelessWidget {
  const _PageErrorState({
    required this.palette,
    required this.pageNumber,
    required this.onRetry,
  });

  final ReaderThemePalette palette;
  final int pageNumber;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.background,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: palette.secondaryText,
            size: 30,
          ),
          const SizedBox(height: 10),
          Text(
            '$pageNumber',
            style: TextStyle(
              color: palette.secondaryText,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => unawaited(onRetry()),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(context.l10n.retry),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.text,
              side: BorderSide(color: palette.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChapter extends StatelessWidget {
  const _EmptyChapter({
    super.key,
    required this.palette,
    required this.message,
    required this.onRetry,
  });

  final ReaderThemePalette palette;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.background,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.secondaryText, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.l10n.retry),
          ),
        ],
      ),
    );
  }
}
