part of 'source_runtime_reading.dart';

extension SourceRuntimeCatalogReading on SourceRuntimeReading {
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    int? maxChapters,
    BookDownloadCancellation? cancellation,
  }) async {
    if (maxChapters != null && maxChapters < 1) {
      throw ArgumentError.value(maxChapters, 'maxChapters', 'must be positive');
    }
    cancellation?.throwIfCancelled();
    final source = sourceFromRegistered(registered);
    final ruleState = runtimeRuleStateFor(
      _state,
      _rules,
      source,
      bookId,
      sourceVariables,
    );
    final bookContext = _state.bookContext(
      source,
      bookId,
      ruleState,
      bookType: bookType(source),
    );
    final tocUrl = await _tocUrl(
      source,
      bookId,
      ruleState,
      bookContext,
      cancellation: cancellation,
    );
    final rule = source.rule('ruleToc');
    var chapterListRule = _rules.requiredRule(rule, 'chapterList');
    final reverseChapters = chapterListRule.startsWith('-');
    if (reverseChapters || chapterListRule.startsWith('+')) {
      chapterListRule = chapterListRule.substring(1).trimLeft();
    }
    if (chapterListRule.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source is missing the chapterList rule.',
      );
    }
    final candidates = <_ChapterCandidate>[];
    final sampledChapterUrls = <String>{};
    final pendingUrls = <String>[tocUrl];
    final seenPages = <String>{};
    var fixedPageList = false;
    var fetchedPages = 0;
    catalogPages:
    while (fetchedPages < SourceRuntimeReading._maxPageHops &&
        pendingUrls.isNotEmpty) {
      cancellation?.throwIfCancelled();
      final pageUrl = pendingUrls.removeAt(0);
      final requestedTarget = _networkTarget(pageUrl);
      if (requestedTarget.isEmpty || !seenPages.add(requestedTarget)) continue;
      final response = await _requests.requestReusingBookInfo(
        source,
        bookId,
        decodeSourceDataTarget(pageUrl) ?? pageUrl,
        variables: requestVariables(ruleState, {'bookUrl': bookId}),
        book: bookContext,
        cancellation: cancellation,
      );
      fetchedPages++;
      final redirectTarget = response.finalUri.toString();
      if (redirectTarget != requestedTarget && !seenPages.add(redirectTarget)) {
        continue;
      }
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId},
        book: bookContext,
        ruleState: ruleState,
        cancellation: cancellation,
      );
      final chapterContext = <String, Object?>{};
      final contextualDocument = document.withScriptEntities(
        book: bookContext,
        chapter: chapterContext,
        bookWriter: (value) => bookContext.addAll(value),
        chapterWriter: (value) => chapterContext.addAll(value),
      );
      var contexts = await _rules.list(
        contextualDocument,
        null,
        chapterListRule,
      );
      if (contexts.isEmpty && source.isImageSource) {
        contexts = _fallbackChapterAnchors(contextualDocument.value);
      }
      for (final context in contexts) {
        chapterContext
          ..clear()
          ..addAll({'index': candidates.length, 'url': pageUrl});
        var title = await _rules.value(
          contextualDocument,
          context,
          rule,
          'chapterName',
        );
        if (context is dom.Element &&
            context.localName == 'a' &&
            title.isEmpty) {
          title = context.text.trim();
        }
        chapterContext['title'] = title;
        final originalUrl = _chapterAnchorUrl(contextualDocument, context);
        final resolvedChapterUrl = await _resolvedChapterUrl(
          contextualDocument,
          context,
          rule,
        );
        final isVolume = _sourceRuleTrue(
          await _rules.value(contextualDocument, context, rule, 'isVolume'),
        );
        if (title.isEmpty || isVolume) continue;
        if (resolvedChapterUrl.invalid && originalUrl.isEmpty) continue;
        final url = resolvedChapterUrl.invalid
            ? originalUrl
            : resolvedChapterUrl.url.isEmpty
            ? response.finalUri.toString()
            : resolvedChapterUrl.url;
        if (url.isEmpty) continue;
        if (candidates.length >= SourceRuntimeReading._maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        candidates.add(
          _ChapterCandidate(
            title: title,
            url: url,
            fallbackUrl: originalUrl.isNotEmpty && originalUrl != url
                ? originalUrl
                : '',
            context: Map.unmodifiable(chapterContext),
          ),
        );
        sampledChapterUrls.add(url);
        if (!reverseChapters &&
            maxChapters != null &&
            sampledChapterUrls.length >= maxChapters) {
          break catalogPages;
        }
      }
      if (!fixedPageList) {
        final nextUrls = await _optionalResolvedUrls(
          contextualDocument,
          null,
          rule,
          'nextTocUrl',
        );
        final unseenNextUrls = <String>[];
        final pageCandidates = <String>{};
        for (final candidate in nextUrls) {
          final target = _networkTarget(candidate);
          if (target.isEmpty ||
              seenPages.contains(target) ||
              !pageCandidates.add(target)) {
            continue;
          }
          unseenNextUrls.add(candidate);
        }
        if (fetchedPages == 1 && nextUrls.length > 1) {
          fixedPageList = true;
        }
        final additions = fixedPageList
            ? unseenNextUrls
            : unseenNextUrls.take(1);
        for (final candidate in additions) {
          if (!pendingUrls.any(
            (queued) => _networkTarget(queued) == _networkTarget(candidate),
          )) {
            pendingUrls.add(candidate);
          }
        }
      }
    }
    var chapterEntries = _deduplicateChapters(
      candidates,
      reverse: reverseChapters,
    );
    if (chapterEntries.isEmpty && source.isImageSource) {
      chapterEntries = [
        _ChapterCandidate(
          title: '全本',
          url: bookId,
          fallbackUrl: '',
          context: const {},
        ),
      ];
    }
    if (chapterEntries.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    final chapters = <BookSourceChapter>[];
    var order = 0;
    for (final entry in chapterEntries) {
      final nextChapterUrl = order + 1 < chapterEntries.length
          ? chapterEntries[order + 1].url
          : '';
      chapters.add(
        BookSourceChapter(id: entry.url, title: entry.title, order: order),
      );
      _state.rememberChapterContext(source, bookId, entry.url, {
        ...entry.context,
        'index': order,
        'title': entry.title,
        'url': entry.url,
        'chapterUrl': entry.url,
        'nextChapterUrl': nextChapterUrl,
        if (entry.fallbackUrl.isNotEmpty) 'fallbackUrl': entry.fallbackUrl,
      });
      order++;
    }
    _state.rememberBookContext(source, bookId, bookContext);
    _state.rememberRuleState(source, bookId, ruleState);
    await _sessions.flush(source);
    return chapters;
  }

  List<Object?> _fallbackChapterAnchors(Object? value) {
    final candidates = switch (value) {
      dom.Document document => document.querySelectorAll('a[href]'),
      dom.Element element => element.querySelectorAll('a[href]'),
      _ => const <dom.Element>[],
    };
    final anchors = <dom.Element>[];
    final seen = <String>{};
    for (final anchor in candidates) {
      final href = anchor.attributes['href']?.trim() ?? '';
      final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (href.isEmpty || text.isEmpty) continue;
      final lower = href.toLowerCase();
      final chapterLikeUrl =
          lower.contains('chapter') ||
          lower.contains('chapter_slot=') ||
          lower.contains('section_slot=') ||
          lower.contains('/read/') ||
          lower.contains('/viewer/');
      final chapterLikeText = RegExp(
        r'(?:第\s*\d+\s*(?:话|話|章|回)|\d+\s*(?:话|話|章|回)|番外|全本)',
        caseSensitive: false,
      ).hasMatch(text);
      if (!chapterLikeUrl || !chapterLikeText) continue;
      final key = '$href\u0000$text';
      if (seen.add(key)) anchors.add(anchor);
    }
    return anchors;
  }

  Future<String> _tocUrl(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> ruleState,
    Map<String, Object?> bookContext, {
    BookDownloadCancellation? cancellation,
  }) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _rules.optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final response = await _requests.requestReusingBookInfo(
      source,
      bookId,
      decodeSourceDataTarget(bookId) ?? bookId,
      variables: requestVariables(ruleState, {'bookUrl': bookId}),
      book: bookContext,
      cancellation: cancellation,
    );
    final document = _requests.document(
      source,
      response,
      variables: {'bookUrl': bookId},
      book: bookContext,
      ruleState: ruleState,
      cancellation: cancellation,
    );
    final contextualDocument = document.withScriptEntities(
      book: bookContext,
      bookWriter: (value) => bookContext.addAll(value),
    );
    final init = _rules.optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.list(contextualDocument, null, init)).firstOrNull;
    try {
      final resolved = await _rules.evaluateUrl(
        contextualDocument,
        context,
        tocRule,
      );
      return resolved.isEmpty ? bookId : resolved;
    } on FormatException {
      // A selector may yield transformed page HTML or an obsolete non-URL
      // value. The common compatible-source behavior is to keep using the
      // detail page as the catalog page in that case.
      return bookId;
    } on BookSourceProtocolException catch (error) {
      if (error.message.contains('non-HTTP URL')) return bookId;
      rethrow;
    }
  }

  void _ensureChapterRequestSucceeded(SourceResponse response) {
    if (response.statusCode < 400) return;
    throw BookSourceProtocolException(
      'Chapter request failed with HTTP ${response.statusCode}.',
    );
  }

  Future<({String url, bool invalid})> _resolvedChapterUrl(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
  ) async {
    try {
      return (
        url: await _rules.url(document, context, rules, 'chapterUrl'),
        invalid: false,
      );
    } on FormatException {
      return (url: '', invalid: true);
    } on BookSourceProtocolException catch (error) {
      if (_isNonNetworkUrlError(error)) return (url: '', invalid: true);
      rethrow;
    }
  }

  String _chapterAnchorUrl(SourceRuleDocument document, Object? context) {
    if (context is! dom.Element) return '';
    final anchor = context.localName == 'a'
        ? context
        : context.querySelector('a[href]');
    final href = anchor?.attributes['href']?.trim() ?? '';
    if (href.isEmpty) return '';
    try {
      return resolveSourceRequestUrl(document.baseUri, href);
    } on FormatException {
      return '';
    } on BookSourceProtocolException catch (error) {
      if (_isNonNetworkUrlError(error)) return '';
      rethrow;
    }
  }

  List<_ChapterCandidate> _deduplicateChapters(
    List<_ChapterCandidate> chapters, {
    required bool reverse,
  }) {
    final byUrl = <String, _ChapterCandidate>{};
    if (reverse) {
      for (final chapter in chapters) {
        byUrl.putIfAbsent(chapter.url, () => chapter);
      }
      return byUrl.values
          .toList(growable: false)
          .reversed
          .toList(growable: false);
    }
    // Reference semantics keep the last duplicate in normal catalog order.
    // This avoids a newest-chapters widget shadowing the full list below it.
    for (final chapter in chapters) {
      byUrl
        ..remove(chapter.url)
        ..[chapter.url] = chapter;
    }
    return byUrl.values.toList(growable: false);
  }
}

class _ChapterCandidate {
  const _ChapterCandidate({
    required this.title,
    required this.url,
    required this.fallbackUrl,
    required this.context,
  });

  final String title;
  final String url;
  final String fallbackUrl;
  final Map<String, Object?> context;
}
