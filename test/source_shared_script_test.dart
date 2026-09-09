import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

void main() {
  late QuickJsSourceScriptEvaluator evaluator;

  setUp(() => evaluator = QuickJsSourceScriptEvaluator());
  tearDown(() => evaluator.dispose());

  SourceScriptContext context(String host, [String library = '']) =>
      SourceScriptContext(
        source: ReadingSourceConfig.fromJson({
          'bookSourceName': 'Shared script fixture',
          'bookSourceUrl': 'https://$host.test',
          'jsLib': library,
        }),
      );

  test('shared helper exports cannot escape into another source', () {
    final first = context(
      'first',
      "const token = 'private'; function sourceToken(){ return token; }",
    );
    expect(evaluator.evaluate('this.sourceToken()', first), 'private');
    expect(
      evaluator.evaluate('typeof sourceToken', context('second')),
      'undefined',
    );
    expect(evaluator.evaluate('this.sourceToken()', first), 'private');
  });

  test('explicit shared globals are isolated after success and failure', () {
    final first = context(
      'first',
      "this.sharedMarker = 'private'; globalThis.sharedData = {token: 1};",
    );
    expect(evaluator.evaluate('sharedMarker', first), 'private');
    expect(
      evaluator.evaluate(
        '[typeof sharedMarker, typeof sharedData]',
        context('second'),
      ),
      ['undefined', 'undefined'],
    );
    expect(
      () => evaluator.evaluate("throw new Error('failed')", first),
      throwsA(isA<Exception>()),
    );
    expect(
      evaluator.evaluate(
        '[typeof sharedMarker, typeof sharedData]',
        context('second'),
      ),
      ['undefined', 'undefined'],
    );
    expect(evaluator.evaluate('sharedData.token', first), 1);
  });

  test('shared helper exports are removed when a rule throws', () {
    expect(
      () => evaluator.evaluate(
        "throw new Error('rule failure')",
        context('first', 'function failedHelper(){ return 1; }'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(
      evaluator.evaluate('typeof failedHelper', context('second')),
      'undefined',
    );
  });

  test('temporary helpers restore existing global functions', () {
    expect(
      evaluator.evaluate(
        'this.parseInt()',
        context('first', "function parseInt(){ return 'custom'; }"),
      ),
      'custom',
    );
    expect(evaluator.evaluate("parseInt('42')", context('second')), 42);
  });

  test('class imports cannot restore an expired shared helper', () {
    evaluator.evaluate(
      'importClass(android.util.Base64); true',
      context('first', "function Base64(){ return 'shared'; }"),
    );
    expect(evaluator.evaluate('typeof Base64', context('second')), 'undefined');
  });

  test('pending network replay cannot expose shared helper closures', () async {
    final requested = Completer<void>();
    final response = Completer<SourceScriptNetworkResult>();
    final first = context(
      'first',
      "function fetchValue(){ return java.ajax('https://first.test/value'); }",
    );
    final pending = evaluator.evaluateAsync(
      'this.fetchValue()',
      SourceScriptContext(
        source: first.source,
        networkHandler: (_) {
          requested.complete();
          return response.future;
        },
      ),
    );
    await requested.future;
    expect(
      evaluator.evaluate('typeof fetchValue', context('second')),
      'undefined',
    );
    response.complete(
      const SourceScriptNetworkResult(
        body: 'ready',
        finalUrl: 'https://first.test/value',
      ),
    );
    expect(await pending, 'ready');
    expect(
      evaluator.evaluate('typeof fetchValue', context('second')),
      'undefined',
    );
  });
}
