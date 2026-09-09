import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

void main() {
  late QuickJsSourceScriptEvaluator evaluator;
  late SourceScriptContext context;

  setUp(() {
    evaluator = QuickJsSourceScriptEvaluator();
    context = SourceScriptContext(
      source: ReadingSourceConfig.fromJson({
        'bookSourceName': 'Selector overload fixture',
        'bookSourceUrl': 'https://books.test',
      }),
      baseUrl: Uri.parse('https://books.test/catalog/'),
      result: {'title': '<b>A &amp; B</b>'},
    );
  });
  tearDown(() => evaluator.dispose());

  test('boolean string overload controls entity decoding, not content', () {
    expect(
      evaluator.evaluate("java.getString('title', false)", context),
      '<b>A &amp; B</b>',
    );
    expect(
      evaluator.evaluate("java.getString('title', true)", context),
      '<b>A & B</b>',
    );
    expect(
      evaluator.evaluate("java.getString('title')", context),
      '<b>A & B</b>',
    );
  });

  test('null content reuses the current result for string and list', () {
    expect(
      evaluator.evaluate("java.getString('title', null)", context),
      '<b>A & B</b>',
    );
    expect(evaluator.evaluate("java.getStringList('title', null)", context), [
      '<b>A &amp; B</b>',
    ]);
  });

  test('URL overload resolves the first attribute against current base', () {
    expect(
      evaluator.evaluate(
        '''java.getString('a@href', '<a href="one?x=1&amp;y=2">A</a><a href="two">B</a>', true)''',
        context,
      ),
      'https://books.test/catalog/one?x=1&y=2',
    );
  });

  test('URL list overload resolves and deduplicates after replacements', () {
    expect(
      evaluator.evaluate(
        '''java.getStringList('a@href##^prefix:', '<a href="prefix:one">A</a><a href="/catalog/one">B</a><a href="../two">C</a>', true).toArray()''',
        context,
      ),
      ['https://books.test/catalog/one', 'https://books.test/two'],
    );
  });

  test('missing URL value returns base but an empty rule stays empty', () {
    expect(
      evaluator.evaluate("java.getString('missing', null, true)", context),
      'https://books.test/catalog/',
    );
    expect(evaluator.evaluate("java.getString('', null, true)", context), '');
  });

  test('URL overload respects script baseUrl updates', () {
    expect(
      evaluator.evaluate(
        '''baseUrl = 'https://redirect.test/next/'; java.getString('url', {url: 'chapter'}, true)''',
        context,
      ),
      'https://redirect.test/next/chapter',
    );
  });

  test('URL decoding happens before relative path normalization', () {
    expect(
      evaluator.evaluate(
        "java.getString('url', {url: '&#46;&#46;/chapter'}, true)",
        context,
      ),
      'https://books.test/chapter',
    );
  });

  test('URL helpers keep embedded data and discard script navigation', () {
    expect(
      evaluator.evaluate(
        "java.getStringList('urls', {urls: ['', 'one', 'javascript:void(0)', 'data:text/plain,chapter']}, true).toArray()",
        context,
      ),
      [
        'https://books.test/catalog/',
        'https://books.test/catalog/one',
        'data:text/plain,chapter',
      ],
    );
    expect(
      evaluator.evaluate(
        "java.getString('url', {url: 'javascript:void(0)'}, true)",
        context,
      ),
      '',
    );
  });

  test('empty list rules retain the nullable collection contract', () {
    expect(
      evaluator.evaluate("java.getStringList('') === null", context),
      true,
    );
    expect(
      evaluator.evaluate('java.getStringList(null) === null', context),
      true,
    );
  });

  test(
    'three-argument boolean content does not select the decode overload',
    () {
      expect(
        evaluator.evaluate("java.getString('title', false, true)", context),
        'https://books.test/catalog/',
      );
    },
  );

  test('scalar object properties split into lines before URL resolution', () {
    const content = r"{urls: 'one\ntwo'}";
    expect(
      evaluator.evaluate(
        "java.getStringList('urls', $content).toArray()",
        context,
      ),
      ['one', 'two'],
    );
    expect(
      evaluator.evaluate(
        "java.getStringList('urls', $content, true).toArray()",
        context,
      ),
      ['https://books.test/catalog/one', 'https://books.test/catalog/two'],
    );
    expect(
      evaluator.evaluate(
        "java.getStringList('urls', {urls: ''}).toArray()",
        context,
      ),
      [''],
    );
  });

  test('list entries and HTML text retain their internal newlines', () {
    expect(
      evaluator.evaluate(
        r"java.getStringList('urls', {urls: ['one\ntwo']}).toArray()",
        context,
      ),
      ['one\ntwo'],
    );
    expect(
      evaluator.evaluate(
        r"java.getStringList('p@text', '<p>one\ntwo</p>').toArray()",
        context,
      ),
      ['one\ntwo'],
    );
  });
}
