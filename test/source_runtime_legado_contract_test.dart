import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'strips the Legado reverse marker after merging catalog pages',
    () async {
      final transport = _ContractTransport({
        'https://books.test/toc/1': _response('''
        <div class="comic_main_list">
          <a href="/chapter/1">第一话</a>
          <a href="/chapter/2">第二话</a>
        </div>
        <select>
          <option value="/toc/1">1</option>
          <option value="/toc/2,{&quot;headers&quot;:{&quot;X-Toc&quot;:&quot;two&quot;}}">2</option>
          <option value="/toc/3">3</option>
        </select>
      ''', 'https://books.test/toc/1'),
        'https://books.test/toc/2': _response('''
        <div class="comic_main_list"><a href="/chapter/3">第三话</a></div>
        <option value="/ignored">ignored child page</option>
      ''', 'https://books.test/toc/2'),
        'https://books.test/toc/3': _response(
          '<div class="comic_main_list"><a href="/chapter/4">第四话</a></div>',
          'https://books.test/toc/3',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final chapters = await runtime.getChapters(
        _source(
          chapterList: '-@css:.comic_main_list>a',
          nextTocUrl: 'option@value',
        ),
        'https://books.test/toc/1',
      );

      expect(chapters.map((chapter) => chapter.title), [
        '第四话',
        '第三话',
        '第二话',
        '第一话',
      ]);
      expect(transport.requests.map((request) => request.url.toString()), [
        'https://books.test/toc/1',
        'https://books.test/toc/2',
        'https://books.test/toc/3',
      ]);
      expect(transport.requests[1].headers['X-Toc'], 'two');
    },
  );

  test('strips the Legado plus marker without reversing chapters', () async {
    final runtime = SourceRuntime(
      transport: _ContractTransport({
        'https://books.test/toc': _response('''
          <ul class="chapter__list-box">
            <li><a href="/chapter/1">第一话</a></li>
            <li><a href="/chapter/2">第二话</a></li>
          </ul>
        ''', 'https://books.test/toc'),
      }),
    );
    addTearDown(runtime.close);

    final chapters = await runtime.getChapters(
      _source(chapterList: '+class.chapter__list-box@tag.li'),
      'https://books.test/toc',
    );

    expect(chapters.map((chapter) => chapter.title), ['第一话', '第二话']);
  });

  test(
    'treats a current-page option plus one sibling as a fixed list',
    () async {
      final transport = _ContractTransport({
        'https://books.test/toc/1': _response(
          '<a class="chapter" href="/chapter/1">第一章</a>'
              '<option value="/toc/1">current</option>'
              '<option value="/toc/2">second</option>',
          'https://books.test/toc/1',
        ),
        'https://books.test/toc/2': _response(
          '<a class="chapter" href="/chapter/2">第二章</a>'
              '<option value="/toc/3">child</option>',
          'https://books.test/toc/2',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final chapters = await runtime.getChapters(
        _source(chapterList: 'a.chapter', nextTocUrl: 'option@value'),
        'https://books.test/toc/1',
      );

      expect(chapters.map((chapter) => chapter.title), ['第一章', '第二章']);
      expect(transport.requests, hasLength(2));
    },
  );

  test('caps a chained catalog at twenty fetched pages', () async {
    final responses = <String, SourceResponse>{};
    for (var page = 1; page <= 25; page++) {
      responses['https://books.test/toc/$page'] = _response(
        '<a class="chapter" href="/chapter/$page">第$page章</a>'
            '<option value="/toc/${page + 1}">next</option>',
        'https://books.test/toc/$page',
      );
    }
    final transport = _ContractTransport(responses);
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final chapters = await runtime.getChapters(
      _source(chapterList: 'a.chapter', nextTocUrl: 'option@value'),
      'https://books.test/toc/1',
    );

    expect(transport.requests, hasLength(20));
    expect(chapters, hasLength(20));
    expect(chapters.last.title, '第20章');
  });

  test(
    'uses the final catalog URL for a non-volume chapter with no URL',
    () async {
      final transport = _ContractTransport({
        'https://books.test/article': _response(
          '<h1>参考文章</h1>',
          'https://cdn.test/final/article',
        ),
        'https://cdn.test/final/article': _response(
          '{"body":"虚拟 JSON 正文"}',
          'https://cdn.test/final/article',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);
      final source = _source(
        chapterList: 'h1',
        chapterName: 'text',
        chapterUrl: '',
        content: r'$.body',
      );

      final chapters = await runtime.getChapters(
        source,
        'https://books.test/article',
      );
      final content = await runtime.getChapterContent(
        source,
        bookId: 'https://books.test/article',
        chapterId: chapters.single.id,
      );

      expect(chapters.single.id, 'https://cdn.test/final/article');
      expect(content.content, '虚拟 JSON 正文');
    },
  );

  test('retains chapter rule variables for content pagination', () async {
    final transport = _ContractTransport({
      'https://books.test/toc': _response(
        '<ul><li><a href="/chapter/1">chapter-token</a></li></ul>',
        'https://books.test/toc',
      ),
      'https://books.test/chapter/1': _response(
        '<main>first</main>',
        'https://books.test/chapter/1',
      ),
      'https://books.test/page/2': _response(
        '<main>second</main>',
        'https://books.test/page/2',
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);
    final source = _source(
      chapterList: 'li',
      chapterName: 'a@text@put:{token:a@text}',
      nextContentUrl:
          "<js>java.get('token') === 'chapter-token' ? '/page/2' : ''</js>",
    );

    final chapters = await runtime.getChapters(
      source,
      'https://books.test/toc',
    );
    final content = await runtime.getChapterContent(
      source,
      bookId: 'https://books.test/toc',
      chapterId: chapters.single.id,
    );

    expect(content.content, contains('first'));
    expect(content.content, contains('second'));
  });

  for (final inline in [false, true]) {
    test(
      'carries ${inline ? 'inline java.put' : 'chapter.putVariable'} state into each scripted fixed-page request',
      () async {
        final transport = _ContractTransport({
          'https://books.test/chapter/1': _response(
            '<main>first</main>'
                '<a class="next" href="/page/2,{&quot;headers&quot;:{&quot;X-State&quot;:&quot;<js>chapter.getVariable(\'token\')</js>&quot;}}">two</a>'
                '<a class="next" href="/page/3,{&quot;headers&quot;:{&quot;X-State&quot;:&quot;<js>chapter.getVariable(\'token\')</js>&quot;}}">three</a>',
            'https://books.test/chapter/1',
          ),
          'https://books.test/page/2': _response(
            '<main>second</main>',
            'https://books.test/page/2',
          ),
          'https://books.test/page/3': _response(
            '<main>third</main>',
            'https://books.test/page/3',
          ),
        });
        final runtime = SourceRuntime(transport: transport);
        addTearDown(runtime.close);

        final content = await runtime.getChapterContent(
          _source(
            chapterList: 'h1',
            content: inline
                ? "main@html&&{{java.put('token', String(Number(java.get('token') || 0) + 1))}}"
                : '''main@html<js>
            if (result.indexOf('first') >= 0) {
              chapter.putVariable('token', 'from-first');
            } else if (result.indexOf('second') >= 0) {
              chapter.putVariable('token', 'from-second');
            }
            result;
          </js>''',
            nextContentUrl: 'a.next@href',
          ),
          bookId: 'https://books.test/book/1',
          chapterId: 'https://books.test/chapter/1',
        );

        expect(content.content, contains('third'));
        expect(
          transport.requests[1].headers['X-State'],
          inline ? '1' : 'from-first',
        );
        expect(
          transport.requests[2].headers['X-State'],
          inline ? '2' : 'from-second',
        );
      },
    );
  }

  test('carries java.put state into the next content-page request', () async {
    final transport = _ContractTransport({
      'https://books.test/chapter/1': _response(
        '<main>first</main>'
            '<a class="next" href="/page/2,{&quot;headers&quot;:{&quot;X-State&quot;:&quot;<js>chapter.getVariable(\'token\')</js>&quot;}}">next</a>',
        'https://books.test/chapter/1',
      ),
      'https://books.test/page/2': _response(
        '<main>second</main>',
        'https://books.test/page/2',
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(
        chapterList: 'h1',
        content: '''main@html<js>
          if (result.indexOf('first') >= 0) java.put('token', 'java-first');
          result;
        </js>''',
        nextContentUrl: 'a.next@href',
      ),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(content.content, contains('second'));
    expect(transport.requests[1].headers['X-State'], 'java-first');
  });

  test(
    'does not turn a volume title or invalid explicit URL into a chapter',
    () async {
      for (final rule in <Map<String, String>>[
        {'chapterUrl': '', 'isVolume': '@js:true'},
        {'chapterUrl': "'javascript:void(0)'", 'isVolume': ''},
        {'chapterUrl': "'mailto:invalid@example.com'", 'isVolume': ''},
      ]) {
        final runtime = SourceRuntime(
          transport: _ContractTransport({
            'https://books.test/toc': _response(
              '<h1>卷标题</h1>',
              'https://books.test/toc',
            ),
          }),
        );
        addTearDown(runtime.close);

        await expectLater(
          runtime.getChapters(
            _source(
              chapterList: 'h1',
              chapterName: 'text',
              chapterUrl: rule['chapterUrl']!,
              isVolume: rule['isVolume']!,
            ),
            'https://books.test/toc',
          ),
          throwsA(isA<Exception>()),
        );
      }
    },
  );

  test(
    'runs a scripted full-content replacement once after all parts merge',
    () async {
      final runtime = SourceRuntime(
        transport: _ContractTransport({
          'https://books.test/chapter/1': _response(
            '<main>b近</main><aside>附注</aside>'
                '<a class="next" href="/page/2">next</a>',
            'https://books.test/chapter/1',
          ),
          'https://books.test/page/2': _response(
            '<main>cH0U<img src="gone.jpg"></main>',
            'https://cdn.test/final/2',
          ),
        }),
      );
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(
          chapterList: 'h1',
          content: 'main@html',
          nextContentUrl: 'a.next@href',
          subContent: 'aside@text',
          replaceRegex: '''<js>
          var runs = java.get('replaceRuns') || 0;
          java.put('replaceRuns', runs + 1);
          (runs + 1) + ':' + result
            .replace(/b近/, '逼近')
            .replace(/cH0U/, '抽')
            .replace(/<img[^>]+>/, '');
        </js>''',
        ),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.content, startsWith('1:'));
      expect(content.content, contains('逼近'));
      expect(content.content, contains('抽'));
      expect(content.content, contains('附注'));
      expect(content.images, isEmpty);
    },
  );

  test(
    'keeps surviving scripted images on their response page bases',
    () async {
      final runtime = SourceRuntime(
        transport: _ContractTransport({
          'https://books.test/chapter/1': _response(
            '<main>first<img src="one.jpg"></main>'
                '<a class="next" href="/page/2">next</a>',
            'https://cdn-one.test/a/index.html',
          ),
          'https://cdn-one.test/page/2': _response(
            '<main>second<img src="two.jpg"></main>',
            'https://cdn-two.test/b/index.html',
          ),
        }),
      );
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(
          chapterList: 'h1',
          nextContentUrl: 'a.next@href',
          replaceRegex: "<js>result.replace(/first/, 'updated')</js>",
        ),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.content, contains('updated'));
      expect(content.images.map((image) => image.url), [
        Uri.parse('https://cdn-one.test/a/one.jpg'),
        Uri.parse('https://cdn-two.test/b/two.jpg'),
      ]);
    },
  );

  test('applies ruleContent webJs only to WebView requests', () async {
    final transport = _ContractTransport({
      'https://books.test/chapter/1': _response(
        '<main>first</main>'
            '<a class="next" href="/page/2,{&quot;webView&quot;:true,&quot;webJs&quot;:&quot;override();&quot;}">next</a>'
            '<aside>https://books.test/sub</aside>',
        'https://books.test/chapter/1',
      ),
      'https://books.test/page/2': _response(
        '<main>second</main>',
        'https://books.test/page/2',
      ),
      'https://books.test/sub': _response(
        'plain sub content',
        'https://books.test/sub',
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    await runtime.getChapterContent(
      _source(
        chapterList: 'h1',
        nextContentUrl: 'a.next@href',
        subContent: 'aside@text',
        webJs: 'defaultContent();',
      ),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1,{"webView":true}',
    );

    expect(transport.requests[0].useWebView, isTrue);
    expect(transport.requests[0].webJs, 'defaultContent();');
    expect(transport.requests[1].useWebView, isTrue);
    expect(transport.requests[1].webJs, 'override();');
    expect(transport.requests[2].useWebView, isFalse);
    expect(transport.requests[2].webJs, isNull);
  });
}

RegisteredBookSource _source({
  required String chapterList,
  String chapterName = 'a@text',
  String chapterUrl = 'a@href',
  String isVolume = '',
  String nextTocUrl = '',
  String content = 'main@html',
  String nextContentUrl = '',
  String subContent = '',
  String replaceRegex = '',
  String webJs = '',
}) => ReadingSourceConfig.fromJson({
  'bookSourceName': 'Legado contract test',
  'bookSourceUrl': 'https://books.test',
  'ruleToc': {
    'chapterList': chapterList,
    'chapterName': chapterName,
    'chapterUrl': chapterUrl,
    'isVolume': isVolume,
    'nextTocUrl': nextTocUrl,
  },
  'ruleContent': {
    'content': content,
    'nextContentUrl': nextContentUrl,
    'subContent': subContent,
    'replaceRegex': replaceRegex,
    'webJs': webJs,
  },
}).toRegisteredSource(enabled: true);

SourceResponse _response(String body, String finalUrl) =>
    SourceResponse(body: body, finalUri: Uri.parse(finalUrl));

class _ContractTransport implements SourceTransport {
  _ContractTransport(this.responses);

  final Map<String, SourceResponse> responses;
  final List<SourceRequestTemplate> requests = [];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    return responses[request.url.toString()] ??
        (throw StateError('Missing response for ${request.url}'));
  }
}
