import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/rules/source_rule_engine.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request_template.dart';
import 'package:xxread/book_sources/source_engine/source_response.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_transport.dart';

void main() {
  const engine = SourceRuleEngine();
  final source =
      jsonDecode(
            File(
              'test/fixtures/book_sources/yiove_midu.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final document = SourceRuleDocument.parse(
    jsonEncode({
      'bookId': 123,
      'chapterId': 456,
      'content_md5': 'abc',
      'chapterNum': 20,
      'category': '小说',
      'score': 9.5,
      'tags': ['甲', '乙'],
      'items': [
        {'label': 'a}b', 'name': '目标'},
      ],
    }),
    Uri.parse('https://book.midukanshu.com/'),
  );

  test(
    'Midu original rules complete search, detail, catalog and content',
    () async {
      final transport = _MiduTransport();
      final runtime = SourceRuntime(
        transport: transport,
        loginSessionStore: _EmptySessionStore(),
      );
      addTearDown(runtime.close);
      final registered = ReadingSourceConfig.fromJson(
        source,
      ).toRegisteredSource(enabled: true);
      final results = await runtime.search(registered, '测试');
      expect(results.items.single.title, '测试小说');
      final book = await runtime.getBook(registered, results.items.single.id);
      expect(book.title, '测试小说');
      final chapters = await runtime.getChapters(registered, book.id);
      expect(chapters.single.title, '第一章');
      expect(
        chapters.single.id,
        'https://book.midukanshu.com/book/chapter/segment/master/123_456.txt?md5=abc',
      );
      final content = await runtime.getChapterContent(
        registered,
        bookId: book.id,
        chapterId: chapters.single.id,
      );
      expect(content.content, '这是原创测试正文。');
      expect(transport.requests.map((request) => request.url.toString()), [
        'http://api.midukanshu.com/fiction/search/search',
        'https://book.midukanshu.com/book/chapter_list/100/123.txt',
        'https://book.midukanshu.com/book/chapter/segment/master/123_456.txt?md5=abc',
      ]);
      expect(transport.requests.first.method, SourceRequestMethod.post);
      expect(
        transport.requests.first.body,
        contains('keyword=%E6%B5%8B%E8%AF%95'),
      );
    },
  );

  test(
    'unchanged Yiove Midu rules interpolate chapter URLs and metadata',
    () async {
      final search = source['ruleSearch'] as Map<String, dynamic>;
      final toc = source['ruleToc'] as Map<String, dynamic>;
      final cases = <String, String>{
        search['lastChapter'] as String: '第20章',
        search['kind'] as String: '小说\n9.5分',
        toc['chapterUrl'] as String:
            'https://book.midukanshu.com/book/chapter/segment/master/123_456.txt?md5=abc',
      };
      for (final entry in cases.entries) {
        expect(
          engine.evaluateString(document, null, entry.key, joinSeparator: '\n'),
          entry.value,
        );
        expect(
          await engine.evaluateStringAsync(
            document,
            null,
            entry.key,
            joinSeparator: '\n',
          ),
          entry.value,
        );
      }
    },
  );

  test('embedded JSONPath respects quoted braces and array results', () async {
    const rule = r"匹配{$.items[?(@.label == 'a}b')].name}：{$.tags[*]}";
    expect(engine.evaluateString(document, null, rule), '匹配目标：甲\n乙');
    expect(await engine.evaluateListAsync(document, null, rule), ['匹配目标：甲\n乙']);
    expect(engine.evaluateList(document, null, rule), ['匹配目标：甲\n乙']);
  });

  test(
    'empty fields preserve surrounding literals and transforms still apply',
    () {
      expect(engine.evaluateString(document, null, r'第{$.missing}章'), '第章');
      expect(
        engine.evaluateString(document, null, r'第{$.chapterNum}章##20##二十'),
        '第二十章',
      );
      expect(
        engine.evaluateString(document, null, r'{{$.chapterNum}}章'),
        '20章',
      );
    },
  );
}

class _MiduTransport implements SourceTransport {
  final requests = <SourceRequestTemplate>[];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    final body = switch (request.url.path) {
      '/fiction/search/search' => jsonEncode({
        'data': [
          {
            'book_id': 123,
            'title': '测试小说',
            'author': '测试作者',
            'category': '小说',
            'score': 9.5,
            'chapterNum': 1,
          },
        ],
      }),
      '/book/chapter_list/100/123.txt' => jsonEncode([
        {'bookId': 123, 'chapterId': 456, 'title': '第一章', 'content_md5': 'abc'},
      ]),
      '/book/chapter/segment/master/123_456.txt' => jsonEncode({
        'content': '这是原创测试正文。',
      }),
      _ => throw StateError('Unexpected request: ${request.url}'),
    };
    return SourceResponse(body: body, finalUri: request.url);
  }
}

class _EmptySessionStore implements SourceLoginSessionStore {
  @override
  Future<SourceLoginSession> read(String sourceId) async =>
      const SourceLoginSession();
  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {}
  @override
  Future<void> clear(String sourceId) async {}
}
