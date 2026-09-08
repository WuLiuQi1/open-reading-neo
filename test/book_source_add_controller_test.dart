import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_add_controller.dart';

void main() {
  test('suppresses stale URL and byte analyses by generation', () async {
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(analyzer: analyzer);
    final first = controller.analyzeUrl('https://old.example');
    final second = controller.analyzeBytes(Uint8List.fromList([1]));
    analyzer.bytes.complete(BookSourceImportAnalysis.orsp(_source('new')));
    await second;
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('old')));
    await first;

    expect(controller.state.analysis?.sources.single.id, 'new');
    expect(controller.state.loading, isFalse);
    controller.dispose();
  });

  test('reports download, analysis, and idle phases', () async {
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(analyzer: analyzer);

    final pending = controller.analyzeUrl('https://source.example');
    expect(controller.state.phase, BookSourceAddPhase.downloading);
    analyzer.finishDownload();
    expect(controller.state.phase, BookSourceAddPhase.analyzing);
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('source')));
    await pending;

    expect(controller.state.phase, BookSourceAddPhase.idle);
    expect(controller.state.loading, isFalse);
    controller.dispose();
  });

  test('clear and dispose suppress late analysis completion', () async {
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(analyzer: analyzer);
    final pending = controller.analyzeUrl('https://late.example');
    controller.clear();
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('late')));
    await pending;
    expect(controller.state.analysis, isNull);

    final disposedAnalyzer = _Analyzer();
    final disposed = BookSourceAddController(analyzer: disposedAnalyzer);
    final disposedPending = disposed.analyzeUrl('https://disposed.example');
    disposed.dispose();
    disposedAnalyzer.url.complete(
      BookSourceImportAnalysis.orsp(_source('disposed')),
    );
    await disposedPending;
    controller.dispose();
  });

  test('commits analyzed sources and reports imported count', () async {
    final registry = _Registry();
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(
      registry: registry,
      analyzer: analyzer,
    );
    final analysis = controller.analyzeUrl('https://source.example');
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('source')));
    await analysis;

    final result = await controller.commit();
    expect(result?.sources.single.id, 'source');
    expect(result?.importedCount, 1);
    expect(registry.upserted.single.id, 'source');
    controller.dispose();
  });

  test(
    'downloads and commits Legado sources with rules and conflict counts',
    () async {
      final importService = _FixedDownloadImportService([
        {
          'bookSourceName': 'Saved Legado source',
          'bookSourceUrl': 'https://saved.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.result', 'name': 'h3@text'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content@html'},
        },
        {
          'bookSourceName': 'Conflicting Legado source',
          'bookSourceUrl': 'https://conflict.example',
          'searchUrl': '/find/{{key}}',
          'ruleSearch': {'bookList': '.book'},
        },
      ]);
      final analyzer = BookSourceImportAnalyzer(
        additionalImporter: importService,
      );
      final registry = _Registry(
        conflictedNames: const {'Conflicting Legado source'},
      );
      final controller = BookSourceAddController(
        registry: registry,
        analyzer: analyzer,
      );
      addTearDown(() {
        controller.dispose();
        analyzer.close();
        importService.close();
      });

      await controller.analyzeUrl('https://sources.example/legado.json');
      final result = await controller.commit();

      expect(controller.state.analysis?.kind, BookSourceImportKind.additional);
      expect(registry.bulkUpserted, hasLength(2));
      final saved = registry.bulkUpserted.singleWhere(
        (source) => source.name == 'Saved Legado source',
      );
      expect(saved.sourceProtocol, BookSourceProtocolKind.readingSource);
      expect(saved.sourceConfig?['searchUrl'], '/search?q={{key}}');
      expect(saved.sourceConfig?['ruleSearch'], {
        'bookList': '.result',
        'name': 'h3@text',
      });
      expect(saved.sourceConfig?['ruleContent'], {'content': '#content@html'});
      expect(result?.importedCount, 1);
      expect(result?.conflictedCount, 1);
      expect(result?.sources.single.name, 'Saved Legado source');
    },
  );

  test('closes only factory-owned import services', () {
    final owned = _ImportService();
    final controller = BookSourceAddController(
      importServiceFactory: () => owned,
    );
    controller.analyzeUrl('https://source.example');
    controller.dispose();
    expect(owned.closed, isTrue);

    final borrowed = _ImportService();
    final borrowedController = BookSourceAddController(importService: borrowed);
    borrowedController.analyzeUrl('https://source.example');
    borrowedController.dispose();
    expect(borrowed.closed, isFalse);
  });

  test('cancels an owned analysis and recreates its import service', () async {
    final services = <_ImportService>[];
    final controller = BookSourceAddController(
      importServiceFactory: () {
        final service = _ImportService();
        services.add(service);
        return service;
      },
    );

    final first = controller.analyzeUrl('https://source.example');
    expect(controller.state.phase, BookSourceAddPhase.downloading);
    controller.cancelAnalysis();
    await first;

    expect(controller.state.phase, BookSourceAddPhase.idle);
    expect(controller.state.analysis, isNull);
    expect(services.single.closed, isTrue);

    final second = controller.analyzeUrl('https://next.example');
    expect(services, hasLength(2));
    controller.cancelAnalysis();
    await second;
    controller.dispose();
  });
}

RegisteredBookSource _source(String id) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/api/'),
  protocolVersion: '1.5',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);

class _Analyzer extends BookSourceImportAnalyzer {
  final Completer<BookSourceImportAnalysis> url = Completer();
  final Completer<BookSourceImportAnalysis> bytes = Completer();
  VoidCallback? _onDownloadComplete;

  @override
  Future<BookSourceImportAnalysis> analyzeUrl(
    String input, {
    VoidCallback? onDownloadStarted,
    VoidCallback? onDownloadComplete,
  }) {
    _onDownloadComplete = onDownloadComplete;
    return url.future;
  }

  void finishDownload() => _onDownloadComplete?.call();

  @override
  Future<BookSourceImportAnalysis> analyzeBytesAsync(
    Uint8List bytes, {
    Uri? documentUri,
  }) => this.bytes.future;
}

class _Registry extends BookSourceRegistry {
  _Registry({this.conflictedNames = const {}});

  final Set<String> conflictedNames;
  List<RegisteredBookSource> upserted = const [];
  List<RegisteredBookSource> bulkUpserted = const [];

  @override
  Future<List<RegisteredBookSource>> upsert(RegisteredBookSource source) async {
    upserted = [source];
    return upserted;
  }

  @override
  Future<BookSourceUpsertAllResult> upsertAll(
    Iterable<RegisteredBookSource> imported,
  ) async {
    bulkUpserted = imported.toList(growable: false);
    final conflicted = bulkUpserted
        .where((source) => conflictedNames.contains(source.name))
        .toList(growable: false);
    return BookSourceUpsertAllResult(
      sources: bulkUpserted
          .where((source) => !conflictedNames.contains(source.name))
          .toList(growable: false),
      conflicted: conflicted,
    );
  }
}

class _FixedDownloadImportService extends SourceImportService {
  _FixedDownloadImportService(Object json)
    : bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));

  final Uint8List bytes;

  @override
  Future<Uint8List> downloadBytes(String input) async => bytes;
}

class _ImportService extends SourceImportService {
  bool closed = false;
  final Completer<Uint8List> download = Completer();

  @override
  Future<Uint8List> downloadBytes(String input) => download.future;

  @override
  void close({bool force = true}) {
    closed = true;
    if (!download.isCompleted) {
      download.completeError(const SourceImportCancelledException());
    }
    super.close(force: force);
  }
}
