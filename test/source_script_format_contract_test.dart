import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_request_template.dart';
import 'package:xxread/book_sources/source_engine/source_response.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_transport.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';

void main() {
  late QuickJsSourceScriptEvaluator evaluator;
  late ReadingSourceConfig source;

  setUp(() {
    evaluator = QuickJsSourceScriptEvaluator();
    source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Reading Source contract fixture',
      'bookSourceUrl': 'https://books.test',
    });
  });

  tearDown(() => evaluator.dispose());

  test(
    'java get follows Reading Source chapter book rule and source precedence',
    () {
      final context = SourceScriptContext(
        source: source,
        variables: const {'shared': 'rule', 'ruleOnly': 'rule-value'},
        book: const {'name': 'Fixture book'},
        chapter: const {'title': 'Fixture chapter'},
      );

      expect(
        evaluator.evaluate('''
        source.put('sourceOnly', 'source-value');
        source.put('shared', 'source');
        book.putVariable('bookOnly', 'book-value');
        book.putVariable('shared', 'book');
        chapter.putVariable('chapterOnly', 'chapter-value');
        chapter.putVariable('shared', 'chapter');
        [
          java.get('bookName'), java.get('title'), java.get('shared'),
          java.get('chapterOnly'), java.get('bookOnly'),
          java.get('ruleOnly'), java.get('sourceOnly'), java.get('missing')
        ];
      ''', context),
        [
          'Fixture book',
          'Fixture chapter',
          'chapter',
          'chapter-value',
          'book-value',
          'rule-value',
          'source-value',
          '',
        ],
      );
    },
  );

  test('java put stores in the active entity and remains source scoped', () {
    final firstBook = <String, Object?>{
      'name': 'Fixture book',
      'bookUrl': '/book/1',
    };
    final firstChapter = <String, Object?>{
      'title': 'Fixture chapter',
      'chapterUrl': '/chapter/1',
    };
    final chapterContext = SourceScriptContext(
      source: source,
      book: firstBook,
      chapter: firstChapter,
      bookWriter: firstBook.addAll,
      chapterWriter: firstChapter.addAll,
    );
    final secondBook = <String, Object?>{
      'name': 'Second book',
      'bookUrl': '/book/2',
    };
    final bookContext = SourceScriptContext(
      source: source,
      book: secondBook,
      bookWriter: secondBook.addAll,
    );

    expect(
      evaluator.evaluate(
        "[java.put('token', 'chapter-token'), chapter.getVariable('token'), book.getVariable('token')]",
        chapterContext,
      ),
      ['chapter-token', 'chapter-token', ''],
    );
    expect(
      evaluator.evaluate("java.get('token')", chapterContext),
      'chapter-token',
    );

    final secondChapter = <String, Object?>{
      'title': 'Second chapter',
      'chapterUrl': '/chapter/2',
    };
    expect(
      evaluator.evaluate(
        "java.get('token')",
        SourceScriptContext(
          source: source,
          book: firstBook,
          chapter: secondChapter,
          bookWriter: firstBook.addAll,
          chapterWriter: secondChapter.addAll,
        ),
      ),
      '',
    );

    expect(
      evaluator.evaluate(
        "[java.put('token', 'book-token'), book.getVariable('token')]",
        bookContext,
      ),
      ['book-token', 'book-token'],
    );
    expect(
      evaluator.evaluate("java.get('token')", chapterContext),
      'chapter-token',
    );

    expect(
      evaluator.evaluate(
        "java.get('token')",
        SourceScriptContext(
          source: source,
          book: secondBook,
          chapter: const {
            'title': 'Second book chapter',
            'chapterUrl': '/book/2/chapter/1',
          },
        ),
      ),
      'book-token',
    );
  });

  test(
    'java log returns the original value like Reading Source JsExtensions',
    () {
      expect(
        evaluator.evaluate(
          "var payload = {name: 'comic', pages: [1, 2]}; java.log(payload) === payload && java.log('chapter')",
          SourceScriptContext(source: source),
        ),
        'chapter',
      );
    },
  );

  test('rule data overrides older script state without losing other puts', () {
    evaluator.evaluate(
      "java.put('token', 'script-token'); java.put('cursor', 'next')",
      SourceScriptContext(source: source),
    );

    expect(
      evaluator.evaluate(
        "[java.get('token'), java.get('cursor')]",
        SourceScriptContext(
          source: source,
          variables: const {'token': 'runtime-token'},
        ),
      ),
      ['runtime-token', 'next'],
    );
  });

  test(
    'java ajax accepts a Reading Source URL list and requests its first entry',
    () async {
      SourceScriptNetworkRequest? captured;
      final value = await evaluator.evaluateAsync(
        "java.ajax(['https://books.test/chapter/1', 'ignored'])",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async {
            captured = request;
            return SourceScriptNetworkResult(
              body: 'chapter body',
              finalUrl: request.url,
            );
          },
        ),
      );

      expect(captured?.url, 'https://books.test/chapter/1');
      expect(value, 'chapter body');
    },
  );

  test(
    'deprecated Reading Source AES helpers share the symmetric crypto engine',
    () {
      expect(
        evaluator.evaluate('''
        var key = '1234567890abcdef';
        var iv = 'abcdef1234567890';
        var encrypted = java.aesEncodeToBase64String(
          'comic-page', key, 'AES/CBC/PKCS5Padding', iv
        );
        java.bytesToStr(java.aesBase64DecodeToByteArray(
          encrypted, key, 'AES/CBC/PKCS5Padding', iv
        ));
      ''', SourceScriptContext(source: source)),
        'comic-page',
      );
    },
  );

  test(
    'runtime chapter templates retain variables written to the book',
    () async {
      final transport = _FixtureTransport({
        'https://api.test/book/1': '{"title":"Fixture book"}',
        'https://api.test/content?token=':
            '{"body":"A complete readable chapter body."}',
        'https://api.test/content?token=book-token':
            '{"body":"A complete readable chapter body."}',
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);
      final registered = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Runtime entity fixture',
        'bookSourceUrl': 'https://api.test',
        'ruleBookInfo': {
          'init': "@js:java.put('token','book-token');result",
          'name': r'$.title',
        },
        'ruleContent': {'content': r'$.body'},
      }).toRegisteredSource(enabled: true);

      final book = await runtime.getBook(registered, '/book/1');
      await runtime.getChapterContent(
        registered,
        bookId: book.id,
        chapterId: "@js:'https://api.test/content?token='+java.get('token')",
      );

      expect(
        transport.requests.map((request) => request.url.toString()),
        contains('https://api.test/content?token=book-token'),
      );
    },
  );
}

class _FixtureTransport implements SourceTransport {
  _FixtureTransport(this.responses);

  final Map<String, String> responses;
  final List<SourceRequestTemplate> requests = [];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    final body = responses[request.url.toString()];
    if (body == null) {
      throw StateError('Missing fixture response for ${request.url}');
    }
    return SourceResponse(body: body, finalUri: request.url);
  }
}
