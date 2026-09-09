import '../models/registered_book_source.dart';
import 'package:html/dom.dart' as dom;
import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import 'source_config.dart';
import 'source_content_images.dart';
import 'source_remote_asset.dart';
import 'source_response.dart';
import 'source_runtime_catalog.dart';
import 'source_request_template.dart';
import 'rules/source_rule_engine.dart' show SourceRuleDocument;
import 'rules/source_rule_parser.dart' show sourceRuleHasDynamicExpression;
import 'source_runtime_login.dart';
import 'source_runtime_requests.dart';
import 'source_runtime_rules.dart';
import 'source_runtime_state.dart';
import 'source_text_replacement.dart';

part 'source_runtime_catalog_reading.dart';

class SourceRuntimeReading {
  SourceRuntimeReading({
    required SourceRuntimeRequestPort requests,
    required SourceRuntimeRulePort rules,
    required SourceRuntimeState state,
    required SourceRuntimeSessionPort sessions,
  }) : this._(requests, rules, state, sessions);

  SourceRuntimeReading._(
    this._requests,
    this._rules,
    this._state,
    this._sessions,
  );

  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;
  static const _imageExtractor = SourceContentImageExtractor();

  final SourceRuntimeRequestPort _requests;
  final SourceRuntimeRulePort _rules;
  final SourceRuntimeState _state;
  final SourceRuntimeSessionPort _sessions;

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final source = sourceFromRegistered(registered);
    final rule = source.rule('ruleContent');
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
    final parts = <String>[];
    final textImagePages = <SourceContentImagePage>[];
    var selectedImages = SourceContentImageAccumulator();
    final recoveredImages = SourceContentImageAccumulator();
    final recoveredContentParts = <String>[];
    final seenPages = <String>{};
    var replaceRemovedImages = false;
    final replaceRule = _rules.optionalRule(rule, 'replaceRegex');
    final contentWebJs = _rules.optionalRule(rule, 'webJs');
    final evaluateReplaceRule = sourceRuleHasDynamicExpression(replaceRule);
    var requiresSequentialPageState =
        sourceRuleHasDynamicExpression(_rules.optionalRule(rule, 'content')) ||
        sourceRuleHasDynamicExpression(
          _rules.optionalRule(rule, 'nextContentUrl'),
        );
    final rememberedChapter = _state.chapterContext(source, bookId, chapterId);
    var chapterTitle =
        sourceVariables['chapterTitle'] ??
        '${rememberedChapter['title'] ?? ''}';
    final fallbackUrl = '${rememberedChapter['fallbackUrl'] ?? ''}'.trim();
    final nextChapterTarget = _networkTarget(
      '${rememberedChapter['nextChapterUrl'] ?? ''}',
    );
    final pendingUrls = <String>[chapterId];
    final prefetched = <String, Future<_PrefetchedPage>>{};
    var fixedUrlsToSchedule = <String>[];
    var fixedScheduleIndex = 0;
    Future<_RequestedPage> requestPage(
      String pageUrl, {
      bool isolateChapter = false,
    }) async {
      final requestChapter = isolateChapter
          ? <String, Object?>{...rememberedChapter}
          : rememberedChapter;
      requestChapter
        ..['url'] = pageUrl
        ..['chapterUrl'] = chapterId;
      final response = await _requests.request(
        source,
        decodeSourceDataTarget(pageUrl) ?? pageUrl,
        variables: requestVariables(ruleState, {
          'bookUrl': bookId,
          'chapterUrl': chapterId,
        }),
        book: bookContext,
        chapter: requestChapter,
        defaultWebJs: contentWebJs.isEmpty ? null : contentWebJs,
        cancellation: cancellation,
      );
      return _RequestedPage(response: response, chapter: requestChapter);
    }

    void scheduleFixedPages() {
      if (requiresSequentialPageState) return;
      while (prefetched.length < 4 &&
          fixedScheduleIndex < fixedUrlsToSchedule.length) {
        final url = fixedUrlsToSchedule[fixedScheduleIndex++];
        prefetched[url] = requestPage(url, isolateChapter: true).then(
          (page) => _PrefetchedPage(page: page),
          onError: (Object error, StackTrace stackTrace) =>
              _PrefetchedPage(error: error, stackTrace: stackTrace),
        );
      }
    }

    SourceRuleDocument? firstDocument;
    var fixedPageList = false;
    for (var hop = 0; hop < _maxPageHops && pendingUrls.isNotEmpty; hop++) {
      final pageUrl = pendingUrls.removeAt(0);
      final requestedUrl = _networkTarget(pageUrl);
      if (!seenPages.add(requestedUrl)) continue;
      final prefetchedResult = await prefetched.remove(pageUrl);
      final requestedPage = prefetchedResult == null
          ? await requestPage(pageUrl)
          : prefetchedResult.unwrap();
      scheduleFixedPages();
      final response = requestedPage.response;
      _ensureChapterRequestSucceeded(response);
      if (!seenPages.add(response.finalUri.toString()) &&
          response.finalUri.toString() != requestedUrl) {
        continue;
      }
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': chapterId},
        book: bookContext,
        ruleState: ruleState,
        cancellation: cancellation,
      );
      final chapterContext = requestedPage.chapter
        ..['url'] = pageUrl
        ..['chapterUrl'] = chapterId
        ..['index'] =
            int.tryParse(sourceVariables['chapterIndex'] ?? '') ??
            rememberedChapter['index'] ??
            hop
        ..['title'] = chapterTitle;
      final contextualDocument = document.withScriptEntities(
        book: bookContext,
        chapter: chapterContext,
        bookWriter: (value) => bookContext.addAll(value),
        chapterWriter: (value) => chapterContext.addAll(value),
      );
      firstDocument ??= contextualDocument;
      final rawContent = await _rules.value(
        contextualDocument,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      final content = source.isImageSource && !evaluateReplaceRule
          ? _rules.replace(rawContent, replaceRule)
          : rawContent;
      var pageHasSelectedImages = false;
      if (content.trim().isNotEmpty) {
        final trimmed = content.trim();
        parts.add(trimmed);
        textImagePages.add((
          content: rawContent.trim(),
          baseUri: contextualDocument.baseUri,
        ));
        final pageImages = _imageExtractor.extract([
          (content: trimmed, baseUri: contextualDocument.baseUri),
        ], allowPlainValues: source.isImageSource);
        selectedImages.addAll(pageImages);
        pageHasSelectedImages = pageImages.isNotEmpty;
      }
      if (rawContent != content && !pageHasSelectedImages) {
        replaceRemovedImages =
            replaceRemovedImages ||
            _imageExtractor.extract([
              (content: rawContent, baseUri: contextualDocument.baseUri),
            ], allowPlainValues: source.isImageSource).isNotEmpty;
      }
      if (source.isImageSource &&
          selectedImages.isEmpty &&
          !replaceRemovedImages &&
          !pageHasSelectedImages) {
        final recoveredPages = _imageExtractor.recoverComicContainers([
          (content: response.body, baseUri: response.finalUri),
        ]);
        recoveredImages.addAll(_imageExtractor.extract(recoveredPages));
        recoveredContentParts.addAll(
          recoveredPages.map((page) => page.content),
        );
      }
      if (!fixedPageList) {
        final nextUrls = await _optionalResolvedUrls(
          contextualDocument,
          null,
          rule,
          'nextContentUrl',
        );
        if (hop == 0 && nextUrls.length > 1) fixedPageList = true;
        final candidates = fixedPageList ? nextUrls : nextUrls.take(1);
        for (final candidate in candidates) {
          final target = _networkTarget(candidate);
          if (target.isEmpty || target == nextChapterTarget) continue;
          if (!seenPages.contains(target) && !pendingUrls.contains(candidate)) {
            pendingUrls.add(candidate);
          }
        }
        if (fixedPageList) {
          fixedUrlsToSchedule = pendingUrls
              .take(_maxPageHops - 1)
              .toList(growable: false);
          requiresSequentialPageState =
              requiresSequentialPageState ||
              fixedUrlsToSchedule.any(sourceRuleHasDynamicExpression);
          scheduleFixedPages();
        }
      }
    }
    var joinedContent = parts.join('\n\n');
    if (selectedImages.isEmpty &&
        !replaceRemovedImages &&
        fallbackUrl.isNotEmpty &&
        !seenPages.contains(fallbackUrl)) {
      final fallbackChapter = <String, Object?>{
        ...rememberedChapter,
        'url': fallbackUrl,
        'chapterUrl': fallbackUrl,
      };
      final response = await _requests.request(
        source,
        decodeSourceDataTarget(fallbackUrl) ?? fallbackUrl,
        variables: requestVariables(ruleState, {
          'bookUrl': bookId,
          'chapterUrl': fallbackUrl,
        }),
        book: bookContext,
        chapter: fallbackChapter,
        defaultWebJs: contentWebJs.isEmpty ? null : contentWebJs,
        cancellation: cancellation,
      );
      rememberedChapter.addAll(fallbackChapter);
      _ensureChapterRequestSucceeded(response);
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': fallbackUrl},
        book: bookContext,
        chapter: rememberedChapter,
        ruleState: ruleState,
        cancellation: cancellation,
      );
      final rawFallbackContent = await _rules.value(
        document,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      final fallbackContent = source.isImageSource && !evaluateReplaceRule
          ? _rules.replace(rawFallbackContent, replaceRule)
          : rawFallbackContent;
      var fallbackHasSelectedImages = false;
      if (fallbackContent.trim().isNotEmpty) {
        final trimmed = fallbackContent.trim();
        parts.add(trimmed);
        textImagePages.add((
          content: rawFallbackContent.trim(),
          baseUri: document.baseUri,
        ));
        final fallbackPageImages = _imageExtractor.extract([
          (content: trimmed, baseUri: document.baseUri),
        ], allowPlainValues: source.isImageSource);
        selectedImages.addAll(fallbackPageImages);
        fallbackHasSelectedImages = fallbackPageImages.isNotEmpty;
        joinedContent = parts.join('\n\n');
      }
      if (rawFallbackContent != fallbackContent && !fallbackHasSelectedImages) {
        replaceRemovedImages = _imageExtractor.extract([
          (content: rawFallbackContent, baseUri: document.baseUri),
        ], allowPlainValues: source.isImageSource).isNotEmpty;
      }
      if (source.isImageSource &&
          selectedImages.isEmpty &&
          !replaceRemovedImages &&
          !fallbackHasSelectedImages) {
        final recoveredPages = _imageExtractor.recoverComicContainers([
          (content: response.body, baseUri: response.finalUri),
        ]);
        recoveredImages.addAll(_imageExtractor.extract(recoveredPages));
        recoveredContentParts.addAll(
          recoveredPages.map((page) => page.content),
        );
      }
    }
    if (firstDocument != null) {
      final subContentRule = _rules.optionalRule(rule, 'subContent');
      if (subContentRule.isNotEmpty) {
        final rawSubContent = await _rules.value(
          firstDocument,
          null,
          rule,
          'subContent',
          joinSeparator: '\n',
          regexDotAll: false,
        );
        var subContent = rawSubContent.trim();
        var subContentBaseUri = firstDocument.baseUri;
        if (subContent.toLowerCase().startsWith('http')) {
          final subContentChapter = <String, Object?>{
            ...rememberedChapter,
            'url': subContent,
            'chapterUrl': chapterId,
          };
          final response = await _requests.request(
            source,
            subContent,
            variables: requestVariables(ruleState, {
              'bookUrl': bookId,
              'chapterUrl': chapterId,
            }),
            book: bookContext,
            chapter: subContentChapter,
            defaultWebJs: contentWebJs.isEmpty ? null : contentWebJs,
            cancellation: cancellation,
          );
          rememberedChapter.addAll(subContentChapter);
          _ensureChapterRequestSucceeded(response);
          subContent = response.body.trim();
          subContentBaseUri = response.finalUri;
        }
        if (!source.isImageSource && subContent.isNotEmpty) {
          parts.add(subContent);
          textImagePages.add((content: subContent, baseUri: subContentBaseUri));
        }
      }
      final titleRule = _rules.optionalRule(rule, 'title');
      if (titleRule.isNotEmpty) {
        try {
          final resolvedTitle = await _rules.value(
            firstDocument,
            null,
            rule,
            'title',
            regexDotAll: false,
          );
          if (resolvedTitle.trim().isNotEmpty) {
            final titleParts = RegExp(
              r'(.*)((?:data|https?):[\s\S]+)$',
            ).firstMatch(resolvedTitle.trim());
            if (titleParts != null) {
              final visibleTitle = titleParts.group(1)!.trim();
              if (visibleTitle.isNotEmpty) chapterTitle = visibleTitle;
              rememberedChapter['reviewImg'] = titleParts.group(2);
            } else {
              chapterTitle = resolvedTitle.trim();
            }
            rememberedChapter['title'] = chapterTitle;
          }
        } catch (_) {
          // Reading-source compatibility treats ruleContent.title as optional
          // metadata. Its failure must not discard content that has already
          // been read successfully.
        }
      }
    }
    joinedContent = parts.join('\n\n');
    if (evaluateReplaceRule && firstDocument != null) {
      final rawJoinedContent = joinedContent;
      joinedContent = await _rules.value(
        firstDocument,
        rawJoinedContent,
        {'replaceRegex': replaceRule},
        'replaceRegex',
        regexDotAll: false,
      );
      final rawImages = _imageExtractor.extract(
        textImagePages,
        allowPlainValues: source.isImageSource,
      );
      final replacementBase =
          textImagePages.firstOrNull?.baseUri ?? firstDocument.baseUri;
      final replacementImages = evaluatedReplacementImages(
        textImagePages,
        joinedContent,
        fallbackBaseUri: replacementBase,
        allowPlainValues: source.isImageSource,
      );
      selectedImages = SourceContentImageAccumulator();
      selectedImages.addAll(replacementImages);
      if (rawImages.isNotEmpty && selectedImages.isEmpty) {
        replaceRemovedImages = true;
      }
    } else if (!source.isImageSource) {
      final replacement = replaceTextPages(textImagePages, replaceRule);
      joinedContent = replacement.content;
      selectedImages = SourceContentImageAccumulator();
      selectedImages.addAll(_imageExtractor.extract(replacement.pages));
    }
    final imageHeaders = await _requests.sourceHeaders(
      source,
      cancellation: cancellation,
    );
    final assets =
        selectedImages.isEmpty && source.isImageSource && !replaceRemovedImages
        ? recoveredImages.values
        : selectedImages.values;
    var images = _remoteImages(source, assets, imageHeaders);
    if (selectedImages.isEmpty && images.isNotEmpty) {
      final recoveredContent = recoveredContentParts.join('\n');
      if (recoveredContent.isNotEmpty) {
        joinedContent = joinedContent.isEmpty
            ? recoveredContent
            : '$joinedContent\n$recoveredContent';
      }
    }
    final contentIsEmpty = source.isImageSource
        ? parts.isEmpty || parts.every(_looksLikePlaceholderContent)
        : _looksLikePlaceholderContent(joinedContent);
    if (contentIsEmpty && images.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    _state.rememberRuleState(source, bookId, ruleState);
    rememberedChapter
      ..['url'] = chapterId
      ..['chapterUrl'] = chapterId
      ..['title'] = chapterTitle;
    _state.rememberChapterContext(source, bookId, chapterId, rememberedChapter);
    await _sessions.flush(source);
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: chapterTitle,
      content: joinedContent,
      contentType: 'text/html',
      images: images,
    );
  }

  Future<List<String>> _optionalResolvedUrls(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    try {
      return await _rules.urls(document, context, rules, key);
    } on FormatException {
      return const [];
    } on BookSourceProtocolException catch (error) {
      if (_isNonNetworkUrlError(error)) return const [];
      rethrow;
    }
  }

  List<BookSourceRemoteImage> _remoteImages(
    ReadingSourceConfig source,
    Iterable<SourceRuntimeRemoteAsset> assets,
    Map<String, String> sourceHeaders,
  ) {
    return assets
        .map((asset) {
          final headers = <String, String>{...sourceHeaders, ...asset.headers};
          final cookie = _requests.cookieHeader(source, asset.url);
          if (cookie.isNotEmpty) headers['Cookie'] = cookie;
          return BookSourceRemoteImage(
            url: asset.url,
            headers: Map.unmodifiable(headers),
          );
        })
        .toList(growable: false);
  }
}

class _PrefetchedPage {
  const _PrefetchedPage({this.page, this.error, this.stackTrace});

  final _RequestedPage? page;
  final Object? error;
  final StackTrace? stackTrace;

  _RequestedPage unwrap() {
    if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
    return page!;
  }
}

class _RequestedPage {
  const _RequestedPage({required this.response, required this.chapter});

  final SourceResponse response;
  final Map<String, Object?> chapter;
}

bool _isNonNetworkUrlError(BookSourceProtocolException error) {
  final message = error.message.toLowerCase();
  return message.contains('non-http url') ||
      message.contains('must use http or https') ||
      message.contains('targets must use http or https');
}

bool _sourceRuleTrue(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized == 'null') return false;
  return !RegExp(
    r'^(?:false|no|not|0|0\.0)$',
    caseSensitive: false,
  ).hasMatch(normalized);
}

String _networkTarget(String value) {
  final decoded = decodeSourceDataTarget(value.trim()) ?? value.trim();
  return decoded.split(RegExp(r',\s*\{')).first.trim();
}

bool _looksLikePlaceholderContent(String value) {
  if (RegExp(r'<img\b', caseSensitive: false).hasMatch(value)) return false;
  final plain = value
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (plain.isEmpty) return true;
  if (plain.length <= 180 &&
      RegExp(
        r'(?:请先登录|请登录|登录后阅读|验证码|人机验证|安全验证|访问频繁|请求频繁|加载中|正在加载|请稍候|内容获取失败|章节不存在)',
        caseSensitive: false,
      ).hasMatch(plain)) {
    return true;
  }
  return plain.startsWith('{') &&
      RegExp(
        r'"(?:error|message|code)"\s*:',
        caseSensitive: false,
      ).hasMatch(plain);
}
