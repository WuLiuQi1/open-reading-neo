import 'source_rule_json.dart';
import 'source_rule_parser.dart';
import 'source_rule_regex.dart';

typedef SourceSingleRuleEvaluator =
    List<Object?> Function(
      Object? context,
      String rule, {
      required bool listMode,
    });
typedef SourceAsyncSingleRuleEvaluator =
    Future<List<Object?>> Function(
      Object? context,
      String rule, {
      required bool listMode,
    });
typedef SourceInlineScriptEvaluator =
    Object? Function(Object? context, String script);
typedef SourceAsyncInlineScriptEvaluator =
    Future<Object?> Function(Object? context, String script);
typedef SourceEmbeddedRuleEvaluator =
    String Function(Object? context, String rule);
typedef SourceAsyncEmbeddedRuleEvaluator =
    Future<String> Function(Object? context, String rule);

class SourceRuleInterpolation {
  const SourceRuleInterpolation({
    required this.evaluateSingle,
    required this.evaluateSingleAsync,
    required this.evaluateScript,
    required this.evaluateScriptAsync,
    required this.evaluateEmbeddedRule,
    required this.evaluateEmbeddedRuleAsync,
  });

  final SourceSingleRuleEvaluator evaluateSingle;
  final SourceAsyncSingleRuleEvaluator evaluateSingleAsync;
  final SourceInlineScriptEvaluator evaluateScript;
  final SourceAsyncInlineScriptEvaluator evaluateScriptAsync;
  final SourceEmbeddedRuleEvaluator evaluateEmbeddedRule;
  final SourceAsyncEmbeddedRuleEvaluator evaluateEmbeddedRuleAsync;

  List<Object?> evaluateAlternatives(
    Object? context,
    String selector, {
    required bool listMode,
  }) {
    final mode = _sourceExplicitRuleMode(selector);
    for (final fallback in splitSourceRuleTopLevel(selector, '||')) {
      final interleaved = splitSourceRuleTopLevel(fallback, '%%');
      if (interleaved.length > 1) {
        final groups = <List<Object?>>[];
        for (final part in interleaved) {
          final values = evaluateConcatenated(
            context,
            part,
            listMode: listMode,
            inheritedMode: mode,
          );
          if (values.isNotEmpty) groups.add(values);
        }
        if (groups.isNotEmpty) return interleaveSourceRuleValues(groups);
        continue;
      }
      final concatenated = evaluateConcatenated(
        context,
        fallback,
        listMode: listMode,
        inheritedMode: mode,
      );
      if (concatenated.any(
        (value) => sourceRuleStringValue(value).isNotEmpty,
      )) {
        return concatenated;
      }
    }
    return const [];
  }

  List<Object?> evaluateConcatenated(
    Object? context,
    String selector, {
    required bool listMode,
    String inheritedMode = '',
  }) {
    final concatenated = <Object?>[];
    for (final part in splitSourceRuleTopLevel(selector, '&&')) {
      concatenated.addAll(
        evaluateSingle(
          context,
          _sourceRuleWithMode(part, inheritedMode),
          listMode: listMode,
        ),
      );
    }
    return concatenated;
  }

  Future<List<Object?>> evaluateAlternativesAsync(
    Object? context,
    String selector, {
    required bool listMode,
  }) async {
    final mode = _sourceExplicitRuleMode(selector);
    for (final fallback in splitSourceRuleTopLevel(selector, '||')) {
      final interleaved = splitSourceRuleTopLevel(fallback, '%%');
      if (interleaved.length > 1) {
        final groups = <List<Object?>>[];
        for (final part in interleaved) {
          final values = await evaluateConcatenatedAsync(
            context,
            part,
            listMode: listMode,
            inheritedMode: mode,
          );
          if (values.isNotEmpty) groups.add(values);
        }
        if (groups.isNotEmpty) return interleaveSourceRuleValues(groups);
        continue;
      }
      final concatenated = await evaluateConcatenatedAsync(
        context,
        fallback,
        listMode: listMode,
        inheritedMode: mode,
      );
      if (concatenated.any(
        (value) => sourceRuleStringValue(value).isNotEmpty,
      )) {
        return concatenated;
      }
    }
    return const [];
  }

  Future<List<Object?>> evaluateConcatenatedAsync(
    Object? context,
    String selector, {
    required bool listMode,
    String inheritedMode = '',
  }) async {
    final concatenated = <Object?>[];
    for (final part in splitSourceRuleTopLevel(selector, '&&')) {
      concatenated.addAll(
        await evaluateSingleAsync(
          context,
          _sourceRuleWithMode(part, inheritedMode),
          listMode: listMode,
        ),
      );
    }
    return concatenated;
  }

  String interpolate(String template, Object? context) {
    return template.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (
      match,
    ) {
      final expression = match.group(1)!;
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        return expression.substring(1, expression.length - 1);
      }
      if (_sourceIsEmbeddedSelector(expression)) {
        return evaluateEmbeddedRule(context, expression);
      }
      final selected = evaluateSourceJsonPath(
        context,
        expression,
      ).map(sourceRuleStringValue).join();
      if (selected.isNotEmpty || !looksLikeSourceScriptExpression(expression)) {
        return selected;
      }
      return sourceRuleStringValue(evaluateScript(context, expression));
    });
  }

  Future<String> interpolateAsync(String template, Object? context) async {
    final output = StringBuffer();
    var offset = 0;
    for (final match in RegExp(
      r'\{\{\s*([^{}]+?)\s*\}\}',
    ).allMatches(template)) {
      output.write(template.substring(offset, match.start));
      final expression = match.group(1)!;
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        output.write(expression.substring(1, expression.length - 1));
      } else if (_sourceIsEmbeddedSelector(expression)) {
        output.write(await evaluateEmbeddedRuleAsync(context, expression));
      } else {
        final selected = evaluateSourceJsonPath(
          context,
          expression,
        ).map(sourceRuleStringValue).join();
        if (selected.isNotEmpty ||
            !looksLikeSourceScriptExpression(expression)) {
          output.write(selected);
        } else {
          output.write(
            sourceRuleStringValue(
              await evaluateScriptAsync(context, expression),
            ),
          );
        }
      }
      offset = match.end;
    }
    output.write(template.substring(offset));
    return output.toString();
  }
}

String _sourceExplicitRuleMode(String rule) =>
    RegExp(
      r'^\+?\s*(@(?:css|json|xpath):)',
      caseSensitive: false,
    ).firstMatch(rule.trimLeft())?.group(1) ??
    '';

bool _sourceIsEmbeddedSelector(String expression) =>
    expression.startsWith('@') ||
    expression.startsWith(r'$.') ||
    expression.startsWith(r'$[') ||
    expression.startsWith('//');

String _sourceRuleWithMode(String rule, String inheritedMode) {
  final trimmed = rule.trim();
  return inheritedMode.isEmpty || _sourceExplicitRuleMode(trimmed).isNotEmpty
      ? trimmed
      : '$inheritedMode$trimmed';
}
