part of 'book_source_reader_page.dart';

extension _BookSourceReaderChapterLoading on _BookSourceReaderPageState {
  Future<void> _loadChapter(
    int index, {
    double restoreProgress = 0,
    bool saveCurrent = true,
  }) async {
    if (index < 0 || index >= _chapters.length || _loadingContent) return;
    if (saveCurrent && index > _chapterIndex) _sessionPagesRead++;
    if (saveCurrent && _content != null) unawaited(_saveProgress());
    if (!mounted) return;
    final loadSerial = ++_chapterLoadSerial;
    _updateReaderState(() {
      _loadingContent = true;
      _requestedChapterIndex = index;
      _error = null;
    });
    try {
      final contentFuture = _continuousContentFor(index);
      final content = await contentFuture;
      if (!mounted || loadSerial != _chapterLoadSerial) return;
      if (await _deferChapterApplyForOpeningFlight(index)) {
        if (!mounted || loadSerial != _chapterLoadSerial) return;
      }
      while (mounted &&
          loadSerial == _chapterLoadSerial &&
          _pageMode != BookSourcePageMode.verticalScroll &&
          !_pagedViewportSize.isEmpty &&
          _cachedPagedLayoutFor(index, content, _pagedViewportSize) == null) {
        await _warmPagedLayout(index);
      }
      if (!mounted || loadSerial != _chapterLoadSerial) return;
      _applyLoadedChapter(index, content, restoreProgress: restoreProgress);
    } catch (error) {
      if (!mounted || loadSerial != _chapterLoadSerial) return;
      _updateReaderState(() {
        _loadingContent = false;
        _requestedChapterIndex = null;
        _error = error;
        _controlsVisible = true;
      });
    }
  }

  void _applyLoadedChapter(
    int index,
    BookSourceChapterContent content, {
    required double restoreProgress,
  }) {
    final normalizedProgress = restoreProgress.clamp(0.0, 1.0);
    final preparedLayout = _preparedPagedLayoutForChapter(index, content);
    final preparedPages = preparedLayout?.pages;
    final preparedPageCount = preparedPages?.length ?? 1;
    final restoredTextOffset = _restoreTextOffset;
    final preparedTarget = preparedPages == null
        ? 0
        : restoredTextOffset != null
        ? bookSourcePageIndexForOffset(preparedPages, restoredTextOffset)
        : ((preparedPageCount - 1) * normalizedProgress).round();
    final preparedPageIndex = preparedPages == null
        ? 0
        : (_usesTwoPageLayout
                  ? _spreadStartForPage(preparedTarget)
                  : preparedTarget)
              .clamp(0, preparedPageCount - 1);
    final slideLeading = _slideLeadingPageCount(index);
    _pagedLayouts.removeWhere(
      (chapterIndex, _) => chapterIndex < index - 1 || chapterIndex > index + 2,
    );
    _pagedLayoutWarms.removeWhere(
      (chapterIndex, _) => chapterIndex < index - 1 || chapterIndex > index + 2,
    );
    _updateReaderState(() {
      _chapterIndex = index;
      _content = content;
      _prefetchedContent[index] = content;
      _loadingContent = false;
      _requestedChapterIndex = null;
      _pageIndex = preparedPageIndex;
      _pageCount = preparedPageCount;
      _pageViewLeading = slideLeading;
      _paginatedPages = preparedPages ?? const [];
      _paginationKey = preparedLayout?.fingerprint;
      _restorePageProgress = normalizedProgress;
      _restorePagedPosition = preparedLayout == null;
      if (preparedLayout != null) _restoreTextOffset = null;
      _ignoreSlidePageChanges = true;
      _pendingSlideChapterIndex = null;
      _pendingSlideBoundaryViewIndex = null;
    });
    _trimChapterMemoryCaches();
    _restartReaderAloudFromCurrentPageAfterManualTurn();
    if (_pageMode == BookSourcePageMode.horizontalSlide) {
      _replaceSlidePageController(
        initialPage: preparedPageIndex + slideLeading,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ignoreSlidePageChanges = false;
      });
    }
    _scrollProgress.value = normalizedProgress;
    unawaited(_preloadAround(index));
  }

  _BookSourcePagedLayout? _preparedPagedLayoutForChapter(
    int index,
    BookSourceChapterContent content,
  ) {
    if (_pageMode == BookSourcePageMode.verticalScroll ||
        _pagedViewportSize.isEmpty) {
      return null;
    }
    return _cachedPagedLayoutFor(index, content, _pagedViewportSize);
  }

  int _slideLeadingPageCount(int chapterIndex) {
    if (chapterIndex <= 0) return 0;
    final previousContent = _prefetchedContent[chapterIndex - 1];
    if (previousContent == null || _pagedViewportSize.isEmpty) return 1;
    final previousLayout = _cachedPagedLayoutFor(
      chapterIndex - 1,
      previousContent,
      _pagedViewportSize,
    );
    return previousLayout?.pages.length ?? 1;
  }

  void _replaceSlidePageController({required int initialPage}) {
    final previous = _pageController;
    _pageController = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  Future<void> _preloadAround(int index) async {
    // The next chapter is the only cache entry needed for a forward turn.
    // Load and lay it out before competing for a source connection with the
    // backwards preview or the farther look-ahead chapter.
    await _preloadChapter(index + 1);
    for (final chapterIndex in <int>[index - 1, index + 2]) {
      unawaited(_preloadChapter(chapterIndex));
    }
  }

  Future<void> _preloadChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    try {
      await _continuousContentFor(index);
      _schedulePagedLayoutWarm(index);
    } catch (_) {
      // Adjacent content is opportunistic and can be retried on demand.
    }
  }

  Future<BookSourceChapterContent> _continuousContentFor(int index) {
    final cached = _prefetchedContent[index];
    if (cached != null && _readableChapterText.containsKey(index)) {
      return Future.value(cached);
    }
    final inFlight = _continuousContentLoads[index];
    if (inFlight != null) return inFlight;
    late final Future<BookSourceChapterContent> future;
    final contentFuture = cached != null
        ? Future<BookSourceChapterContent>.value(cached)
        : _client.getChapterContent(
            widget.source,
            bookId: widget.book.id,
            chapterId: _chapters[index].id,
            sourceVariables: {
              ...widget.book.sourceVariables,
              'chapterIndex': '$index',
              'chapterTitle': _sourceChapterTitle(index),
              'bookName': widget.book.title,
              'bookAuthor': widget.book.author,
              'bookType': '${widget.book.type}',
            },
          );
    future = contentFuture
        .then((content) async {
          _readableChapterText.remove(index);
          final readable = isImageOnlyBookSourceChapter(content)
              ? ''
              : await readableBookSourceChapterTextAsync(
                  content,
                  fallbackTitle: _sourceChapterTitle(index),
                );
          _readableChapterText[index] = await _replaceRules.applyAsync(
            readable,
            bookTitle: widget.book.title,
            sourceName: widget.source.name,
          );
          while (_readableChapterText.length >
              _bookSourceReadableChapterTextLimit) {
            _readableChapterText.remove(_readableChapterText.keys.first);
          }
          await _loadOnlinePagination(index);
          _prefetchedContent[index] = content;
          _trimChapterMemoryCaches();
          if (!mounted) {
            return content;
          }
          final pageStep = _usesTwoPageLayout ? 2 : 1;
          final updatesCurrentContent =
              !_loadingContent && _chapterIndex == index && _content != content;
          final revealsPagedBoundary =
              !_loadingContent &&
              _pageMode != BookSourcePageMode.verticalScroll &&
              ((index == _chapterIndex + 1 &&
                      _pageIndex + pageStep >= _pageCount) ||
                  (index == _chapterIndex - 1 && _pageIndex < pageStep));
          if (updatesCurrentContent || revealsPagedBoundary) {
            _updateReaderState(() {
              if (updatesCurrentContent) {
                _content = content;
              }
            });
          }
          _schedulePagedLayoutWarm(index);
          return content;
        })
        .whenComplete(() {
          if (identical(_continuousContentLoads[index], future)) {
            _continuousContentLoads.remove(index);
          }
        });
    _continuousContentLoads[index] = future;
    return future;
  }

  void _trimChapterMemoryCaches({bool aggressive = false}) {
    if (_chapters.isEmpty) return;
    final center = _chapterIndex;
    final requested = _requestedChapterIndex;
    bool retain(int index) {
      if (index == center || index == requested) return true;
      if (aggressive) return false;
      return index >= center - 1 &&
          index <=
              (_autoWholeBook
                  ? math.max(center + 2, _autoRetainThrough)
                  : center + 2);
    }

    _prefetchedContent.removeWhere((index, _) => !retain(index));
    _readableChapterText.removeWhere((index, _) => !retain(index));
    _pagedLayouts.removeWhere((index, _) => !retain(index));
    _verticalLayouts.removeWhere((index, _) => !retain(index));
    _pagedLayoutWarms.removeWhere((index, _) => !retain(index));
    _verticalPartKeys.removeWhere((key, _) {
      final separator = key.indexOf(':');
      final chapter = int.tryParse(
        separator < 0 ? key : key.substring(0, separator),
      );
      return chapter != null && !retain(chapter);
    });
  }

  void _releasePaginationPointer(PointerEvent event) {
    _paginationPointers.remove(event.pointer);
    if (_paginationPointers.isNotEmpty) return;
    _paginationPointerReleased?.complete();
    _paginationPointerReleased = null;
  }

  bool get _pageTurnIsAnimating =>
      (_pageController.hasClients &&
          _pageController.position.isScrollingNotifier.value) ||
      _coverPageTurnController.isAnimating ||
      _pageCurlController.isAnimating ||
      _spreadForwardPageCurlController.isAnimating ||
      _spreadBackwardPageCurlController.isAnimating;

  Future<void> _yieldForPagedLayout() async {
    // Layout may be queued while a finger is held still, when Flutter has no
    // transient animation callbacks. Let the gesture finish before measuring.
    do {
      while (mounted && _paginationPointers.isNotEmpty) {
        _paginationPointerReleased ??= Completer<void>();
        await _paginationPointerReleased!.future;
      }
      if (!mounted) return;
      // One event-loop turn per page keeps input responsive. Waiting on frames
      // instead of queuing idle scheduler tasks avoids polling while an
      // animation owns the scheduler.
      if (_paginationYield == null) {
        final yielded = Completer<void>();
        _paginationYield = yielded;
        _paginationYieldTimer = Timer(Duration.zero, () {
          _paginationYieldTimer = null;
          _paginationYield = null;
          yielded.complete();
        });
      }
      await _paginationYield!.future;
      while (mounted && _pageTurnIsAnimating) {
        await SchedulerBinding.instance.endOfFrame;
      }
    } while (mounted && _paginationPointers.isNotEmpty);
  }

  Future<_BookSourcePagedLayout?> _warmPagedLayout(int index) {
    final content = _prefetchedContent[index];
    if (!mounted ||
        content == null ||
        _pagedViewportSize.isEmpty ||
        _pageMode == BookSourcePageMode.verticalScroll) {
      return Future.value();
    }
    final viewport = _pagedViewportSize;
    final cached = _cachedPagedLayoutFor(index, content, viewport);
    if (cached != null) return Future.value(cached);
    final existing = _pagedLayoutWarms[index];
    if (existing != null) return existing;
    late final Future<_BookSourcePagedLayout?> future;
    future = Future<void>.value()
        .then((_) async {
          if (!mounted) return null;
          final settled = BookOpenTransition.openingFlightSettledListenableOf(
            context,
          );
          if (settled != null && !settled.value) {
            final ready = Completer<void>();
            void onSettled() {
              if (!settled.value) return;
              settled.removeListener(onSettled);
              ready.complete();
            }

            settled.addListener(onSettled);
            await Future.any([ready.future, _paginationDisposed.future]);
            settled.removeListener(onSettled);
          }
          if (!mounted || !identical(_pagedLayoutWarms[index], future)) {
            return null;
          }
          final result = await _preparePagedLayoutFor(
            index,
            content,
            viewport,
            yieldBetweenPages: _yieldForPagedLayout,
            isCurrent: () =>
                identical(_pagedLayoutWarms[index], future) &&
                _pagedViewportSize == viewport &&
                identical(_prefetchedContent[index], content),
          );
          if (result != null && mounted) _updateReaderState(() {});
          return result;
        })
        .whenComplete(() {
          if (identical(_pagedLayoutWarms[index], future)) {
            _pagedLayoutWarms.remove(index);
          }
        });
    _pagedLayoutWarms[index] = future;
    return future;
  }

  void _schedulePagedLayoutWarm(int index) {
    if (!mounted ||
        index < 0 ||
        index >= _chapters.length ||
        (index != _chapterIndex + 1 && index != _chapterIndex - 1)) {
      return;
    }
    unawaited(
      _warmPagedLayout(index).catchError((Object error) {
        debugPrint('prepare adjacent chapter failed: $error');
        return null;
      }),
    );
  }

  Future<void> _jumpToVerticalChapter(
    int index, {
    int? textOffset,
    double progress = 0,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    final content = await _continuousContentFor(index);
    if (!mounted) return;
    var targetPage = 0;
    _BookSourceVerticalLayout? layout;
    if (!_verticalViewportSize.isEmpty) {
      layout = _verticalLayoutFor(index, content, _verticalViewportSize);
      targetPage = textOffset != null
          ? bookSourcePageIndexForOffset(layout.pages, textOffset)
          : ((layout.pages.length - 1) * progress.clamp(0.0, 1.0)).round();
    }
    _updateReaderState(() {
      _chapterIndex = index;
      _content = content;
      _pageIndex = targetPage;
      _verticalPageIndex = targetPage;
      _verticalPageCount = layout?.pages.length ?? 1;
      _restorePagedPosition = false;
      _restoreTextOffset = null;
    });
    _scrollProgress.value = _verticalPageCount <= 1
        ? 0
        : targetPage / (_verticalPageCount - 1);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (_effectiveScrollByChapter) {
      if (_verticalPageScrollController.isAttached) {
        await _verticalPageScrollController.scrollTo(
          index: targetPage,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      unawaited(_preloadAround(index));
      _scheduleProgressSave();
      return;
    }
    if (!_verticalChapterScrollController.isAttached) return;
    await _verticalChapterScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    if (targetPage > 0) {
      await _verticalChapterOffsetController.animateScroll(
        offset: targetPage * _verticalPageExtentFor(_verticalViewportSize),
        duration: const Duration(milliseconds: 1),
      );
      if (!mounted) return;
    }
    unawaited(_preloadAround(index));
    _scheduleProgressSave();
  }
}
