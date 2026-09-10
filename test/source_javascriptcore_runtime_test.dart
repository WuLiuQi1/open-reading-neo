import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_javascriptcore_runtime.dart';

void main() {
  if (!Platform.isMacOS && !Platform.isIOS) return;

  test('disposed source hosts do not accumulate in the global registry', () {
    final before = JavascriptRuntime.channelFunctionsRegistered.keys.toSet();
    for (var index = 0; index < 100; index++) {
      final runtime = SourceJavaScriptCoreRuntime();
      runtime.onMessage('host', (_) => {'value': '中文 $index'});
      expect(
        runtime.evaluate("sendMessage('host', 'null').value").stringResult,
        '中文 $index',
      );
      runtime.dispose();
    }
    expect(JavascriptRuntime.channelFunctionsRegistered.keys.toSet(), before);
  });

  test(
    'native exceptions and primitive results survive repeated evaluation',
    () {
      final runtime = SourceJavaScriptCoreRuntime();
      addTearDown(runtime.dispose);
      for (final script in [
        "throw new Error('bad')",
        "throw 'bad'",
        'throw null',
      ]) {
        expect(runtime.evaluate(script).isError, isTrue, reason: script);
        expect(runtime.evaluate('21 * 2').stringResult, '42');
      }
      expect(runtime.evaluate("'中文 😀'").stringResult, '中文 😀');
      expect(runtime.evaluate('null').stringResult, 'null');
      expect(runtime.evaluate('undefined').stringResult, 'undefined');
    },
  );

  test('host exceptions become catchable JS exceptions', () {
    final runtime = SourceJavaScriptCoreRuntime();
    addTearDown(runtime.dispose);
    runtime.onMessage('broken', (_) => throw StateError('host failed'));
    final result = runtime.evaluate('''
      (() => { try { sendMessage('broken', 'null'); }
        catch (e) { return String(e).includes('host failed'); } })()
    ''');
    expect(result.isError, isFalse);
    expect(result.stringResult, 'true');
    expect(runtime.evaluate("sendMessage('broken', 'null')").isError, isTrue);
    expect(runtime.evaluate('1 + 1').stringResult, '2');
  });

  test('timers are cancellable and cannot call a disposed context', () async {
    final runtime = SourceJavaScriptCoreRuntime();
    final fired = Completer<void>();
    var callbacks = 0;
    runtime.onMessage('tick', (_) {
      callbacks++;
      if (!fired.isCompleted) fired.complete();
      return null;
    });
    runtime.evaluate("setTimeout(() => sendMessage('tick', 'null'), 0)");
    await fired.future.timeout(const Duration(seconds: 2));
    expect(callbacks, 1);
    runtime.evaluate('''
      var cancelled = setTimeout(() => sendMessage('tick', 'null'), 10);
      clearTimeout(cancelled);
    ''');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(callbacks, 1);
    runtime.evaluate("setTimeout(() => sendMessage('tick', 'null'), 10)");
    runtime.dispose();
    runtime.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(callbacks, 1);
    expect(() => runtime.evaluate('42'), throwsStateError);
  });
}
