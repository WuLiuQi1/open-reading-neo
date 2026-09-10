import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi';

import 'package:flutter_js/javascript_runtime.dart';
import 'package:flutter_js/javascriptcore/binding/js_object_ref.dart'
    as js_object;
import 'package:flutter_js/javascriptcore/flutter_jscore.dart';
import 'package:flutter_js/javascriptcore/jscore_bindings.dart';
import 'package:flutter_js/js_eval_result.dart';

typedef _CallocNative = Pointer<Void> Function(IntPtr count, IntPtr size);
typedef _CallocDart = Pointer<Void> Function(int count, int size);
typedef _FreeNative = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

final _process = DynamicLibrary.process();
final _calloc = _process.lookupFunction<_CallocNative, _CallocDart>('calloc');
final _free = _process.lookupFunction<_FreeNative, _FreeDart>('free');

/// A source-script-only JavaScriptCore runtime with instance-owned callbacks.
///
/// flutter_js 0.8.7 routes every JavaScriptCore bridge through one static Dart
/// callback. Concurrent source evaluators can therefore dispatch into the wrong
/// source, and disposing the newest evaluator leaves the callback dangling.
class SourceJavaScriptCoreRuntime extends FlutterJsPlatformEmpty {
  SourceJavaScriptCoreRuntime() {
    _contextGroup = jSContextGroupCreate();
    _globalContext = jSGlobalContextCreateInGroup(_contextGroup, nullptr);
    _globalObject = jSContextGetGlobalObject(_globalContext);
    _sendMessageCallback =
        NativeCallable<js_object.JSObjectCallAsFunctionCallback>.isolateLocal(
          _sendMessage,
        );
    try {
      _installSendMessage();
      _installConsoleAndTimers();
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  late final Pointer _contextGroup;
  late final Pointer _globalContext;
  late final Pointer _globalObject;
  late final NativeCallable<js_object.JSObjectCallAsFunctionCallback>
  _sendMessageCallback;

  final Map<String, Function> _channels = {};
  final Map<String, Timer> _timers = {};
  bool _disposed = false;

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) {
    _ensureAlive();
    final script = JSString.fromString(code);
    final source = sourceUrl == null ? null : JSString.fromString(sourceUrl);
    final exception = _newExceptionSlot();
    try {
      final value = jSEvaluateScript(
        _globalContext,
        script.pointer,
        nullptr,
        source?.pointer ?? nullptr,
        1,
        exception,
      );
      final thrown = exception.value;
      if (thrown != nullptr) {
        return JsEvalResult(
          'ERROR: ${_valueToString(_globalContext, thrown)}',
          thrown,
          isError: true,
        );
      }
      return JsEvalResult(_valueToString(_globalContext, value), value);
    } finally {
      _freeExceptionSlot(exception);
      source?.release();
      script.release();
    }
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) async {
    return evaluate(code, sourceUrl: sourceUrl);
  }

  @override
  int executePendingJob() {
    _ensureAlive();
    evaluate('(function () {})();');
    return 0;
  }

  @override
  bool setupBridge(String channelName, void Function(dynamic) fn) {
    _ensureAlive();
    if (_channels.containsKey(channelName)) return false;
    _channels[channelName] = fn;
    return true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _channels.clear();
    jSGlobalContextRelease(_globalContext);
    jSContextGroupRelease(_contextGroup);
    _sendMessageCallback.close();
  }

  @override
  String getEngineInstanceId() => identityHashCode(this).toString();

  @override
  void initChannelFunctions() {}

  void _installSendMessage() {
    final name = JSString.fromString('sendMessage');
    final exception = _newExceptionSlot();
    try {
      final function = jSObjectMakeFunctionWithCallback(
        _globalContext,
        name.pointer,
        _sendMessageCallback.nativeFunction,
      );
      jSObjectSetProperty(
        _globalContext,
        _globalObject,
        name.pointer,
        function,
        js_object.JSPropertyAttributes.kJSPropertyAttributeDontDelete,
        exception,
      );
      if (exception.value != nullptr) {
        throw StateError(_valueToString(_globalContext, exception.value));
      }
    } finally {
      _freeExceptionSlot(exception);
      name.release();
    }
  }

  void _installConsoleAndTimers() {
    setupBridge('__SourceConsole', (message) {
      if (message is List && message.isNotEmpty) {
        developer.log(message.skip(1).join(' '), name: 'source.javascript');
      }
    });
    setupBridge('__SourceSetTimeout', _scheduleTimer);
    setupBridge('__SourceClearTimeout', _clearTimer);
    final result = evaluate(r'''
      globalThis.console = {
        log: (...args) => sendMessage('__SourceConsole', JSON.stringify(['log', ...args])),
        warn: (...args) => sendMessage('__SourceConsole', JSON.stringify(['warn', ...args])),
        error: (...args) => sendMessage('__SourceConsole', JSON.stringify(['error', ...args]))
      };
      (() => {
        let nextId = 0;
        const callbacks = Object.create(null);
        globalThis.setTimeout = (callback, delay) => {
          const id = String(++nextId);
          callbacks[id] = callback;
          sendMessage('__SourceSetTimeout', JSON.stringify({id, delay: Number(delay) || 0}));
          return id;
        };
        globalThis.clearTimeout = (id) => {
          id = String(id);
          delete callbacks[id];
          sendMessage('__SourceClearTimeout', JSON.stringify(id));
        };
        globalThis.__OPEN_READING_FIRE_TIMEOUT__ = (id) => {
          const callback = callbacks[id];
          delete callbacks[id];
          if (typeof callback === 'function') callback();
        };
      })();
    ''');
    if (result.isError) throw StateError(result.stringResult);
  }

  Pointer _sendMessage(
    Pointer context,
    Pointer function,
    Pointer thisObject,
    int argumentCount,
    Pointer<Pointer> arguments,
    Pointer<Pointer> exception,
  ) {
    if (_disposed ||
        jSContextGetGlobalContext(context).address != _globalContext.address) {
      return nullptr;
    }
    try {
      if (argumentCount < 2) {
        throw const FormatException(
          'sendMessage requires channel and payload.',
        );
      }
      final channel = _valueToString(context, arguments[0]);
      final payload = jsonDecode(_valueToString(context, arguments[1]));
      final callback = _channels[channel];
      final result = callback == null
          ? null
          : Function.apply(callback, [payload]);
      if (result is Future) {
        throw UnsupportedError('Async host callbacks are not supported.');
      }
      return _jsonValue(context, result);
    } catch (error) {
      final message = JSString.fromString('$error');
      try {
        exception.value = jSValueMakeString(context, message.pointer);
      } finally {
        message.release();
      }
      return jSValueMakeUndefined(context);
    }
  }

  void _scheduleTimer(dynamic message) {
    if (_disposed || message is! Map) return;
    final id = '${message['id'] ?? ''}';
    if (id.isEmpty) return;
    final rawDelay = message['delay'];
    final delay = rawDelay is num ? rawDelay.round().clamp(0, 2147483647) : 0;
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(Duration(milliseconds: delay), () {
      _timers.remove(id);
      if (_disposed) return;
      evaluate('__OPEN_READING_FIRE_TIMEOUT__(${jsonEncode(id)});');
    });
  }

  void _clearTimer(dynamic id) {
    _timers.remove('$id')?.cancel();
  }

  Pointer _jsonValue(Pointer context, Object? value) {
    final encoded = JSString.fromString(jsonEncode(value));
    try {
      final result = jSValueMakeFromJSONString(context, encoded.pointer);
      return result == nullptr ? jSValueMakeNull(context) : result;
    } finally {
      encoded.release();
    }
  }

  String _valueToString(Pointer context, Pointer value) {
    if (value == nullptr) return 'undefined';
    if (jSValueIsNull(context, value) == 1) return 'null';
    if (jSValueIsUndefined(context, value) == 1) return 'undefined';
    final string = jSValueToStringCopy(context, value, nullptr);
    if (string == nullptr) return 'undefined';
    try {
      return JSString(string).string ?? 'undefined';
    } finally {
      JSString(string).release();
    }
  }

  Pointer<Pointer> _newExceptionSlot() {
    final slot = _calloc(1, sizeOf<Pointer>()).cast<Pointer>();
    if (slot == nullptr) {
      throw StateError('Could not allocate JSC exception slot.');
    }
    return slot;
  }

  void _freeExceptionSlot(Pointer<Pointer> slot) {
    _free(slot.cast<Void>());
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('The JavaScriptCore runtime is disposed.');
  }
}
