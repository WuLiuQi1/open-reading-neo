import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/rules/source_rule_engine.dart';

void main() {
  const engine = SourceRuleEngine();

  SourceRuleDocument html(String body) => SourceRuleDocument.parse(
    '<html><body>$body</body></html>',
    Uri.parse('https://books.test/'),
  );

  test('relative JSONPath filters match Legado book and comic rules', () {
    final document = SourceRuleDocument.parse('''{
        "data": {
          "catalog": [
            {"name": "volume", "grade": 1},
            {"name": "chapter 1", "grade": 2},
            {"name": "chapter 2", "grade": 3}
          ]
        }
      }''', Uri.parse('https://books.test/catalog'));

    final chapters = engine.evaluateList(
      document,
      null,
      'data.catalog[?(@.grade > 1)]',
    );

    expect(
      chapters.map(
        (chapter) => engine.evaluateString(document, chapter, 'name'),
      ),
      ['chapter 1', 'chapter 2'],
    );
  });

  test('plain relative JSON keys may contain colon and comma characters', () {
    final document = SourceRuleDocument.parse(
      '{"meta:author":"Alice","last,name":"Chapter"}',
      Uri.parse('https://books.test/book'),
    );

    expect(engine.evaluateString(document, null, 'meta:author'), 'Alice');
    expect(engine.evaluateString(document, null, 'last,name'), 'Chapter');
  });

  test('JSoup contains selects elements by descendant text', () {
    final document = html('''
      <nav><a href="/library"><b>书库</b></a><a href="/rank">排行</a></nav>
    ''');

    expect(
      engine.evaluateString(
        document,
        null,
        '@css:a:contains(书库)+a@href',
        resolveUrl: true,
      ),
      'https://books.test/rank',
    );
  });

  test('JSoup text predicates normalize whitespace like Element.text', () {
    final document = html('<a id="book">Book\n <b>VIP</b></a>');

    expect(
      engine.evaluateString(document, null, 'a:contains(Book VIP)@id'),
      'book',
    );
  });

  test('JSoup text predicates preserve block and BR boundaries', () {
    final document = html(
      '<section id="book"><div>Book</div><div>VIP</div></section>'
      '<p id="br">Book<br>VIP</p><p id="inline">Book<b>VIP</b></p>',
    );
    expect(
      engine.evaluateString(document, null, 'section:contains(Book VIP)@id'),
      'book',
    );
    expect(
      engine.evaluateString(document, null, r'section:matches(^Book VIP$)@id'),
      'book',
    );
    expect(
      engine.evaluateString(document, null, 'p:containsOwn(Book VIP)@id'),
      'br',
    );
    expect(
      engine.evaluateString(document, null, 'p:contains(BookVIP)@id'),
      'inline',
    );
  });

  test('JSoup pseudo arguments preserve quotes and ignore contains case', () {
    final document = html('''
      <div><a href="/one">Book (VIP)</a><a href="/two">other</a></div>
    ''');

    expect(
      engine.evaluateString(document, null, 'a:contains("book (vip)")@href'),
      '/one',
    );
  });

  test('pseudo-like text inside an attribute value stays ordinary CSS', () {
    final document = html('''
      <a data-note=":contains(foo)">attribute</a><a data-note="other">foo</a>
    ''');

    expect(
      engine.evaluateString(
        document,
        null,
        'a[data-note=":contains(foo)"]@text',
      ),
      'attribute',
    );
  });

  test('JSoup positional pseudos filter the selected result set', () {
    final document = html('''
      <table><tbody>
        <tr><td>one</td></tr><tr><td>two</td></tr><tr><td>three</td></tr>
      </tbody></table>
    ''');

    expect(
      engine
          .evaluateList(document, null, 'tr:gt(0):lt(2)')
          .map((row) => engine.evaluateString(document, row, 'text')),
      ['two'],
    );
  });

  test('JSoup direct-child eq works from a selected book context', () {
    final document = html('''
      <div class="book"><span>name</span><span>author</span><span>kind</span></div>
    ''');
    final book = engine.evaluateList(document, null, 'div.book').single;

    expect(engine.evaluateString(document, book, '>:eq(2)@text'), 'kind');
  });

  test('JSoup matchesOwn only checks direct text', () {
    final document = html('''
      <div class="direct">正文 12 <span>广告 99</span></div>
      <div class="nested"><span>正文 34</span></div>
    ''');

    expect(
      engine
          .evaluateList(document, null, 'div:matchesOwn(^正文\\s+\\d+)')
          .map((node) => engine.evaluateString(document, node, 'text')),
      ['正文 12 广告 99'],
    );
  });

  test('JSoup matches honors inline case-insensitive regex flags', () {
    final document = html('<p>Chapter ABC</p><p>chapter xyz</p>');

    expect(
      engine
          .evaluateList(document, null, r'p:matches((?i)^chapter abc$)')
          .map((node) => engine.evaluateString(document, node, 'text')),
      ['Chapter ABC'],
    );
  });

  test('matches regex content is not reparsed as a selector pseudo', () {
    final document = html('<p>prefix:containsfoo</p><p>other</p>');

    expect(
      engine
          .evaluateList(document, null, r'p:matches(^prefix:contains(foo)$)')
          .map((node) => engine.evaluateString(document, node, 'text')),
      ['prefix:containsfoo'],
    );
  });

  test('JSoup attribute regex preserves nested character classes', () {
    final document = html('''
      <img src="data:image/png;base64,abc">
      <img src="/covers/book.jpg">
      <img src="javascript:bad()">
    ''');

    expect(
      engine.evaluateList(
        document,
        null,
        r'img[src~=^(data|https?):|^[^:]+/]@src',
      ),
      ['data:image/png;base64,abc', '/covers/book.jpg'],
    );
  });

  test('JSoup has supports relative child selectors', () {
    final document = html('''
      <article id="book"><h2><a href="/book">Book</a></h2></article>
      <article id="ad"><div><h2><a href="/ad">Ad</a></h2></div></article>
    ''');

    expect(
      engine
          .evaluateList(document, null, 'article:has(>h2>a[href="/book"])')
          .map((node) => engine.evaluateString(document, node, 'id')),
      ['book'],
    );
  });

  test('JSoup has follows adjacent, sibling, and descendant combinators', () {
    final document = html('''
      <section id="adjacent"><i></i><b><em></em></b></section>
      <section id="general"><i></i><span></span><b></b></section>
      <section id="missing"><i></i><span></span></section>
    ''');

    expect(
      engine
          .evaluateList(document, null, 'section:has(> i + b)@id')
          .cast<String>(),
      ['adjacent'],
    );
    expect(
      engine
          .evaluateList(document, null, 'section:has(> i ~ b)@id')
          .cast<String>(),
      ['adjacent', 'general'],
    );
    expect(
      engine
          .evaluateList(document, null, 'section:has(> i + b em)@id')
          .cast<String>(),
      ['adjacent'],
    );
  });

  test('JSoup positional pseudos stay linear for large chapter lists', () {
    final items = List.generate(10000, (index) => '<li>$index</li>').join();
    final document = html('<ul>$items</ul>');

    expect(engine.evaluateList(document, null, 'li:gt(0)'), hasLength(9999));
  });

  test('compatibility markers are removed after successful selection', () {
    final document = html('<div><a href="/one">Book</a></div>');

    expect(
      engine.evaluateList(document, null, 'a:contains(Book)'),
      hasLength(1),
    );
    expect(
      () => engine.evaluateList(document, null, 'a:contains(Book)['),
      throwsA(anything),
    );
    expect(document.rawText, isNot(contains('data-open-reading-compat')));
    expect(
      engine.evaluateString(document, null, 'html'),
      isNot(contains('data-open-reading-compat')),
    );
  });
}
