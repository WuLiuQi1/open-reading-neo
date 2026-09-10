import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

SourceScriptContext _context(String name) => SourceScriptContext(
  source: ReadingSourceConfig.fromJson({
    'bookSourceName': name,
    'bookSourceUrl': 'https://$name.test',
  }),
);

void main() {
  test('interleaved engines keep host callbacks in their owning source', () {
    final first = QuickJsSourceScriptEvaluator();
    final second = QuickJsSourceScriptEvaluator();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(
      first.evaluate(
        "cache.put('key', 'first'); cache.get('key')",
        _context('a'),
      ),
      'first',
    );
    expect(
      second.evaluate(
        "cache.put('key', 'second'); cache.get('key')",
        _context('b'),
      ),
      'second',
    );
    expect(first.evaluate("cache.get('key')", _context('a')), 'first');
  });

  test('disposing the newest engine leaves older callbacks usable', () {
    final first = QuickJsSourceScriptEvaluator();
    addTearDown(first.dispose);
    final second = QuickJsSourceScriptEvaluator();
    second.dispose();
    expect(
      first.evaluate("java.md5Encode('abc')", _context('a')),
      '900150983cd24fb0d6963f7d28e17f72',
    );
  });

  test('disposal rejects pending network replay and queued scripts', () async {
    final evaluator = QuickJsSourceScriptEvaluator();
    final requested = Completer<void>();
    final response = Completer<SourceScriptNetworkResult>();
    final context = SourceScriptContext(
      source: _context('a').source,
      networkHandler: (_) {
        requested.complete();
        return response.future;
      },
    );
    final pending = evaluator.evaluateAsync("java.ajax('/value')", context);
    await requested.future;
    final queued = evaluator.evaluateAsync('42', context);
    final pendingCheck = expectLater(pending, throwsStateError);
    final queuedCheck = expectLater(queued, throwsStateError);
    evaluator.dispose();
    evaluator.dispose();
    response.complete(
      const SourceScriptNetworkResult(
        body: 'late',
        finalUrl: 'https://a.test/value',
      ),
    );
    await Future.wait([pendingCheck, queuedCheck]);
    expect(() => evaluator.evaluate('42', context), throwsStateError);
  });
}
