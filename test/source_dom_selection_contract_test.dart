import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:xxread/book_sources/source_engine/rules/source_rule_interpolation.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';

void main() {
  const engine = SourceRuleEngine();
  final baseUri = Uri.parse('https://books.test/');

  List<String> select(String body, String rule, {String? contextSelector}) {
    final document = SourceRuleDocument.parse(body, baseUri);
    final context = contextSelector == null
        ? null
        : (document.value as Document).querySelector(contextSelector);
    return engine
        .evaluateList(document, context, rule)
        .map((value) => value is Element ? value.text : '$value')
        .toList();
  }

  const lists =
      '<ul><li>A0</li><li>A1</li><li>A2</li></ul>'
      '<ul><li>B0</li><li>B1</li><li>B2</li></ul>';
  const nested = '<section><div>A<b>X</b></div><p>B</p></section>';
  const five = '<ul><li>0</li><li>1</li><li>2</li><li>3</li><li>4</li></ul>';

  test('applies selection separately to each parent context', () {
    expect(select(lists, 'ul@li.0'), ['A0', 'B0']);
    expect(select(lists, 'ul@li[-1:0:2]'), ['A2', 'A0', 'B2', 'B0']);
  });

  test('applies exclusions separately to each parent context', () {
    expect(select(lists, 'ul@li!0'), ['A1', 'A2', 'B1', 'B2']);
    expect(select(lists, 'ul@li[!0,-1]'), ['A1', 'B1']);
  });

  test('children selects direct elements without nested descendants', () {
    expect(select(nested, 'section@children'), ['AX', 'B']);
    expect(select(nested, 'section@children.1'), ['B']);
    expect(select(nested, 'section@children[!0]'), ['B']);
  });

  test('bare indexes select children of the current context', () {
    expect(select(nested, 'section@[1]'), ['B']);
    expect(select(nested, '[0]', contextSelector: 'section'), ['AX']);
    expect(select(nested, '[-1:0]', contextSelector: 'section'), ['B', 'AX']);
    expect(select(nested, '.1', contextSelector: 'section'), ['B']);
  });

  test('colon exclusions accept multiple positive and negative indexes', () {
    expect(select(five, 'li!0:2:-1'), ['1', '3']);
    expect(select(five, 'li!2:2'), ['0', '1', '3', '4']);
  });

  test('out of range include indexes produce no edge elements', () {
    for (final rule in [
      'li.99',
      'li.-99',
      'li[99]',
      'li[-99]',
      'li[9:12]',
      'li[-99:-88]',
    ]) {
      expect(select(five, rule), isEmpty, reason: rule);
    }
    expect(select(five, 'li[99,1,-99,3]'), ['1', '3']);
  });

  test('out of range exclusions preserve all elements', () {
    for (final rule in ['li!99:-99', 'li[!99,-99]', 'li[!9:12]']) {
      expect(select(five, rule), ['0', '1', '2', '3', '4'], reason: rule);
    }
  });

  test('partially overlapping ranges clamp only the outside endpoint', () {
    expect(select(five, 'li[-99:1]'), ['0', '1']);
    expect(select(five, 'li[3:99]'), ['3', '4']);
    expect(select(five, 'li[99:3]'), ['4', '3']);
  });

  test('normalizes negative and zero range steps against parent length', () {
    expect(select(five, 'li[0:4:-6]'), ['0', '1', '2', '3', '4']);
    expect(select(five, 'li[0:4:-5]'), ['0', '1', '2', '3', '4']);
    expect(select(five, 'li[0:4:-2]'), ['0', '3']);
    expect(select(five, 'li[0:4:0]'), ['0']);
  });

  test('empty parent selections remain empty', () {
    expect(select('<ul></ul>', 'ul@children[-1:0]'), isEmpty);
    expect(select('<ul></ul>', 'ul@li[!0]'), isEmpty);
    expect(select('<ul></ul>', 'missing@[0]'), isEmpty);
  });

  test('text selector matches own text case insensitively by substring', () {
    const body =
        '<section><div><a>Next chapter</a></div>'
        '<p>NEXT</p><p>next page</p></section>';
    expect(select(body, 'text.NEXT'), ['Next chapter', 'NEXT', 'next page']);
    expect(select(body, 'text.next[!1]'), ['Next chapter', 'next page']);
  });

  test('explicit CSS preserves literal tag and class selector semantics', () {
    const body =
        '<section><children>literal</children><p>paragraph</p>'
        '<tag class="li">class match</tag><li>list item</li></section>';
    expect(select(body, '@css:children'), ['literal']);
    expect(select(body, '@css:tag.li'), ['class match']);
    expect(select(body, '@css:section > :nth-child(2)'), ['paragraph']);
  });

  test('explicit CSS preserves quoted attributes and text terminals', () {
    final document = SourceRuleDocument.parse(
      '<a data-id="a@b" href="/next">Next</a>',
      baseUri,
    );
    expect(
      engine.evaluateString(document, null, '@css:[data-id="a@b"]@text'),
      'Next',
    );
  });

  test(
    'CSS child positions count elements while ignoring text and comments',
    () {
      const body =
          '<ul>intro<li>A</li>between<!-- note --><li>B</li><li>C</li></ul>';
      expect(select(body, '@css:li:nth-child(1)'), ['A']);
      expect(select(body, '@css:li:nth-child(2)'), ['B']);
      expect(select(body, 'ul@li:nth-child(3)'), ['C']);
      expect(select(body, '@css:li:nth-child(0)'), isEmpty);
    },
  );

  test('CSS child formulas cover odd even and signed integer progressions', () {
    for (final entry in <String, List<String>>{
      'odd': ['0', '2', '4'],
      'even': ['1', '3'],
      '2n + 1': ['0', '2', '4'],
      '-n+3': ['0', '1', '2'],
      'n+3': ['2', '3', '4'],
      '-2n+5': ['0', '2', '4'],
      '0n+2': ['1'],
      'n': ['0', '1', '2', '3', '4'],
    }.entries) {
      expect(
        select(five, '@css:li:nth-child(${entry.key})'),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test(
    'CSS child positions restart for each parent and compose with filters',
    () {
      expect(select(lists, '@css:ul > li:nth-child(2)'), ['A1', 'B1']);
      expect(
        select(
          lists,
          '@css:ul:has(> li:nth-child(2):contains(B1)) > li:nth-child(1)',
        ),
        ['B0'],
      );
    },
  );

  test('explicit CSS mode reaches fallback and concatenated branches', () {
    const body = '<tag class="li">class match</tag><li>list item</li>';
    expect(select(body, '@css:missing||tag.li'), ['class match']);
    expect(select(body, '@css:tag.li&&tag.li'), ['class match', 'class match']);
    expect(select(body, '@css:tag.li%%tag.li'), ['class match', 'class match']);
    expect(select(body, '+@CSS:missing||tag.li'), ['class match']);
  });

  test(
    'wrapped content selectors choose primary and fallback in sync and async paths',
    () async {
      const rule = '{{@css:.text-content1 .c-en@text||.text-content1@text}}';
      for (final entry in <String, String>{
        '<div class="text-content1"><span class="c-en">English</span></div>':
            'English',
        '<div class="text-content1">Fallback paragraph</div>':
            'Fallback paragraph',
        '<div class="text-content1"><p class="c-en">First paragraph</p><p class="c-en">Second paragraph</p></div>':
            'First paragraph\nSecond paragraph',
        '<div class="other">Unrelated</div>': '',
      }.entries) {
        final document = SourceRuleDocument.parse(entry.key, baseUri);
        expect(engine.evaluateString(document, null, rule), entry.value);
        expect(
          await engine.evaluateStringAsync(document, null, rule),
          entry.value,
        );
      }
    },
  );

  test(
    'wrapped selector expressions support JSON XPath and surrounding text',
    () async {
      final html = SourceRuleDocument.parse('<p>Chapter</p>', baseUri);
      final json = SourceRuleDocument.parse('{"title":"Chapter"}', baseUri);
      expect(
        engine.evaluateString(html, null, 'Title: {{//p/text()}}'),
        'Title: Chapter',
      );
      expect(
        await engine.evaluateStringAsync(html, null, '{{@xpath://p/text()}}'),
        'Chapter',
      );
      expect(
        engine.evaluateString(json, null, r'{{@json:$.title}}'),
        'Chapter',
      );
      expect(
        await engine.evaluateStringAsync(json, null, r'{{$.title}}'),
        'Chapter',
      );
    },
  );

  test('explicit XPath mode reaches relative fallback branches', () {
    expect(select('<p>chapter</p>', '@xpath://missing||html/body/p'), [
      'chapter',
    ]);
  });

  test(
    'wrapped attribute selectors join every distinct nonblank value',
    () async {
      final document = SourceRuleDocument.parse(
        '<a href="/one">One</a><a href="/two">Two</a>'
        '<a href="/one">Duplicate</a><a href="">Empty</a>',
        baseUri,
      );
      const rule = '{{@css:a@href}}';
      expect(engine.evaluateString(document, null, rule), '/one\n/two');
      expect(
        await engine.evaluateStringAsync(document, null, rule),
        '/one\n/two',
      );
    },
  );

  test('wrapped replacements run before the outer transformation', () async {
    final document = SourceRuleDocument.parse('<p>正文广告</p>', baseUri);
    for (final entry in <String, String>{
      '{{@css:p@text##广告##}}': '正文',
      '内容：{{@css:p@text##广告##}}##正文##内容': '内容：内容',
      r'{{@css:p@text##(正文).*##$1###}}': '正文',
    }.entries) {
      expect(engine.evaluateString(document, null, entry.key), entry.value);
      expect(
        await engine.evaluateStringAsync(document, null, entry.key),
        entry.value,
      );
    }
  });

  test(
    'embedded replacements preserve paragraphs after a matched line',
    () async {
      final document = SourceRuleDocument.parse(
        '<p>A</p><p>广告</p><p>B</p>',
        baseUri,
      );
      const rule = '{{@css:p@text##广告.*##}}';
      expect(engine.evaluateString(document, null, rule), 'A\n\nB');
      expect(await engine.evaluateStringAsync(document, null, rule), 'A\n\nB');
    },
  );

  test(
    'quoted selector delimiters do not become replacement boundaries',
    () async {
      final document = SourceRuleDocument.parse(
        '<p data-marker="##">正文广告</p>',
        baseUri,
      );
      const rule = '@css:p[data-marker="##"]@text##广告##';
      expect(engine.evaluateString(document, null, rule), '正文');
      expect(await engine.evaluateStringAsync(document, null, rule), '正文');
    },
  );

  test(
    'explicit selector modes propagate identically in sync and async evaluation',
    () async {
      for (final mode in ['@css:', '@json:', '@xpath:']) {
        final calls = <String>[];
        List<Object?> evaluate(
          Object? context,
          String rule, {
          required bool listMode,
        }) {
          calls.add(rule);
          return rule.endsWith('missing') ? [] : [rule];
        }

        final interpolation = SourceRuleInterpolation(
          evaluateSingle: evaluate,
          evaluateSingleAsync: (context, rule, {required listMode}) async =>
              evaluate(context, rule, listMode: listMode),
          evaluateScript: (_, _) => null,
          evaluateScriptAsync: (_, _) async => null,
          evaluateEmbeddedRule: (_, _) => '',
          evaluateEmbeddedRuleAsync: (_, _) async => '',
        );
        final rule = '${mode}missing||first&&second';
        expect(interpolation.evaluateAlternatives(null, rule, listMode: true), [
          '${mode}first',
          '${mode}second',
        ]);
        expect(calls, ['${mode}missing', '${mode}first', '${mode}second']);
        calls.clear();
        expect(
          await interpolation.evaluateAlternativesAsync(
            null,
            rule,
            listMode: true,
          ),
          ['${mode}first', '${mode}second'],
        );
        expect(calls, ['${mode}missing', '${mode}first', '${mode}second']);
      }
    },
  );
}
