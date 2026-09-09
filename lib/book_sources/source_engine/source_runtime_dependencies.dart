import 'source_debug.dart';
import 'source_request_template.dart';
import 'source_response.dart';
import 'scripting/source_script_engine_platform.dart';

class SourceRuntimeTrace {
  SourceRuntimeTrace([this.recorder]);

  SourceDebugRecorder? recorder;
  String? _stage;

  Future<T> stage<T>(
    String name,
    Future<T> Function() action, {
    String Function(T)? describe,
  }) async {
    final current = recorder;
    if (current == null) return action();
    _stage = name;
    current.stageStarted(name);
    try {
      final result = await action();
      current.stageSucceeded(name, describe?.call(result) ?? '');
      return result;
    } catch (error) {
      current.stageFailed(name, error);
      rethrow;
    } finally {
      _stage = null;
    }
  }

  Stopwatch? startNetwork() => recorder == null ? null : (Stopwatch()..start());

  void networkSuccess(
    SourceRequestTemplate request,
    SourceResponse response,
    Stopwatch? stopwatch,
  ) {
    recorder?.recordNetwork(
      stage: _stage ?? '',
      method: request.method.name.toUpperCase(),
      url: request.url,
      statusCode: response.statusCode,
      bodyPreview: _debugPreview(response.body),
      elapsed: stopwatch?.elapsed,
    );
  }

  void networkFailure(
    SourceRequestTemplate request,
    Object error,
    Stopwatch? stopwatch,
  ) {
    recorder?.recordNetwork(
      stage: _stage ?? '',
      method: request.method.name.toUpperCase(),
      url: request.url,
      error: error,
      elapsed: stopwatch?.elapsed,
    );
  }
}

class SourceRuntimeScriptOwner {
  SourceRuntimeScriptOwner([SourceScriptEvaluator? evaluator])
    : _evaluator = evaluator;

  SourceScriptEvaluator? _evaluator;
  bool _closed = false;

  SourceScriptEvaluator get evaluator {
    if (_closed) {
      throw StateError('The source runtime is closed.');
    }
    return _evaluator ??= QuickJsSourceScriptEvaluator();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _evaluator?.dispose();
    _evaluator = null;
  }
}

String _debugPreview(String body) {
  const maxLength = 50000;
  return body.length > maxLength
      ? '${body.substring(0, maxLength)}\n…(${body.length - maxLength} more characters)'
      : body;
}
