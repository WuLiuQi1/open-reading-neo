import 'dart:async';

import 'package:flutter/material.dart';

import 'package:xxread/utils/reader_themes.dart';

class ReaderSearchDocument {
  const ReaderSearchDocument({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.text,
  });

  final int chapterIndex;
  final String chapterTitle;
  final String text;
}

class ReaderSearchResult {
  const ReaderSearchResult({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.offset,
    required this.excerpt,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int offset;
  final String excerpt;
}

typedef ReaderSearchLoader = Stream<ReaderSearchDocument> Function();

Future<void> showReaderSearchSheet(
  BuildContext context, {
  required ReaderThemePalette palette,
  required ReaderSearchLoader loadDocuments,
  required int documentCount,
  required ValueChanged<ReaderSearchResult> onResultSelected,
  String initialQuery = '',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: palette.background,
  builder: (_) => _ReaderSearchSheet(
    palette: palette,
    loadDocuments: loadDocuments,
    documentCount: documentCount,
    onResultSelected: onResultSelected,
    initialQuery: initialQuery,
  ),
);

class _ReaderSearchSheet extends StatefulWidget {
  const _ReaderSearchSheet({
    required this.palette,
    required this.loadDocuments,
    required this.documentCount,
    required this.onResultSelected,
    required this.initialQuery,
  });

  final ReaderThemePalette palette;
  final ReaderSearchLoader loadDocuments;
  final int documentCount;
  final ValueChanged<ReaderSearchResult> onResultSelected;
  final String initialQuery;

  @override
  State<_ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<_ReaderSearchSheet> {
  static const _resultLimit = 500;

  late final TextEditingController _controller;
  Timer? _debounce;
  StreamSubscription<ReaderSearchDocument>? _subscription;
  List<ReaderSearchResult> _results = const [];
  int _searchGeneration = 0;
  int _searchedDocuments = 0;
  bool _loading = false;
  bool _truncated = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery.trim());
    if (_controller.text.isNotEmpty) _search(_controller.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_subscription?.cancel());
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _search('');
    if (value.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(value));
  }

  void _search(String rawQuery) {
    _debounce?.cancel();
    final query = rawQuery.trim();
    final generation = ++_searchGeneration;
    final previous = _subscription;
    _subscription = null;
    if (previous != null) unawaited(previous.cancel());
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searchedDocuments = 0;
        _loading = false;
        _truncated = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _results = const [];
      _searchedDocuments = 0;
      _loading = true;
      _truncated = false;
      _error = null;
    });
    final queryLower = query.toLowerCase();
    final results = <ReaderSearchResult>[];
    late final StreamSubscription<ReaderSearchDocument> subscription;
    subscription = widget.loadDocuments().listen(
      (document) {
        if (!mounted || generation != _searchGeneration) return;
        final previousResultCount = results.length;
        final textLower = document.text.toLowerCase();
        var from = 0;
        while (results.length < _resultLimit) {
          final offset = textLower.indexOf(queryLower, from);
          if (offset < 0) break;
          final start = (offset - 24).clamp(0, document.text.length);
          final end = (offset + query.length + 48).clamp(
            start,
            document.text.length,
          );
          results.add(
            ReaderSearchResult(
              chapterIndex: document.chapterIndex,
              chapterTitle: document.chapterTitle,
              offset: offset,
              excerpt: document.text
                  .substring(start, end)
                  .replaceAll(RegExp(r'\s+'), ' '),
            ),
          );
          from = offset + query.length;
        }
        _searchedDocuments++;
        final reachedLimit = results.length >= _resultLimit;
        final shouldRefresh =
            results.length != previousResultCount ||
            _searchedDocuments == widget.documentCount ||
            _searchedDocuments % 8 == 0;
        if (!shouldRefresh) return;
        setState(() {
          _results = List.unmodifiable(results);
          _truncated = reachedLimit;
          if (reachedLimit) _loading = false;
        });
        if (reachedLimit) {
          unawaited(subscription.cancel());
          _subscription = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _results = List.unmodifiable(results);
          _loading = false;
          _error = error;
        });
      },
      onDone: () {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _results = List.unmodifiable(results);
          _loading = false;
          _truncated = results.length >= _resultLimit;
        });
      },
      cancelOnError: true,
    );
    _subscription = subscription;
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return FractionallySizedBox(
      heightFactor: .9,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('reader-full-text-search-field'),
                    controller: _controller,
                    autofocus: true,
                    onChanged: _onChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜索本书内容',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _controller.clear();
                                _onChanged('');
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      filled: true,
                      fillColor: palette.controlFill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_controller.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _statusText,
                  key: const ValueKey('reader-full-text-search-status'),
                  style: TextStyle(color: palette.secondaryText),
                ),
              ),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Text(
                      _emptyStateText,
                      style: TextStyle(color: palette.secondaryText),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                    itemCount: _results.length,
                    separatorBuilder: (_, _) =>
                        Divider(color: palette.text.withValues(alpha: .1)),
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        title: Text(
                          result.chapterTitle,
                          style: TextStyle(
                            color: palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            result.excerpt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.secondaryText,
                              height: 1.45,
                            ),
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          widget.onResultSelected(result);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String get _statusText {
    if (_error != null) return '搜索失败，请重试';
    final resultText = _truncated
        ? '至少找到 $_resultLimit 处（仅显示前 $_resultLimit 处）'
        : '找到 ${_results.length} 处';
    if (!_loading) return resultText;
    final total = widget.documentCount;
    return total > 0
        ? '$resultText · 已搜索 $_searchedDocuments/$total 章'
        : '$resultText · 正在搜索';
  }

  String get _emptyStateText {
    if (_controller.text.trim().isEmpty) return '输入人物、地点或关键词';
    if (_error != null) return '搜索过程中出现错误，请稍后重试';
    return '没有找到相关内容';
  }
}
