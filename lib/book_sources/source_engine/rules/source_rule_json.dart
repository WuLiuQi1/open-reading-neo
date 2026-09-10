import 'package:json_path/json_path.dart';

import 'package:xxread/book_sources/protocol/book_source_protocol.dart';

import 'source_rule_parser.dart';

/// Evaluates a JSONPath rule. When [listMode] is true and the path resolves
/// to exactly one match whose value is itself a `List`, that list's elements
/// are returned instead of the list-as-one-value, matching reading-source
/// JSONPath compatibility where a
/// bare list rule like `bookList: "$.data"` is expected to produce one
/// context per array element without requiring the caller to write
/// `$.data[*]`.
List<Object?> evaluateSourceJsonPath(
  Object? root,
  String path, {
  bool listMode = false,
}) {
  // Legado AnalyzeByJSonPath expands {$.path} inside literal metadata and
  // chapter URLs before evaluating a standalone path.
  if (path.contains(r'{$.')) {
    final output = StringBuffer();
    var offset = 0;
    while (true) {
      final start = path.indexOf(r'{$.', offset);
      if (start < 0) break;
      final parts = splitSourceRuleTopLevel(
        path.substring(start),
        '}',
        limit: 2,
      );
      if (parts.length != 2) break;
      output.write(path.substring(offset, start));
      final values = evaluateSourceJsonPath(
        root,
        parts.first.substring(1),
        listMode: true,
      );
      output.write(values.map((value) => value?.toString() ?? '').join('\n'));
      offset = start + parts.first.length + 1;
    }
    if (offset > 0) {
      output.write(path.substring(offset));
      return [output.toString()];
    }
  }
  final matches = _evaluateSourceJsonPathMatches(root, path);
  if (listMode && matches.length == 1 && matches.first is List) {
    return List<Object?>.from(matches.first as List);
  }
  return matches;
}

List<Object?> _evaluateSourceJsonPathMatches(Object? root, String path) {
  var normalized = path.trim();
  if (normalized == r'$') return [root];
  if (normalized.startsWith(r'$') || _usesJsonPathSyntax(normalized)) {
    if (!normalized.startsWith(r'$')) normalized = r'$.' + normalized;
    try {
      return JsonPath(
        normalizeLegacySourceJsonPath(normalized),
      ).read(root).map((match) => match.value).toList(growable: false);
    } on Object catch (error) {
      throw BookSourceProtocolException(
        'reading source JSONPath could not be evaluated: $error',
      );
    }
  }
  if (normalized.startsWith(r'$.')) normalized = normalized.substring(2);
  final tokens = RegExp(r'([^\.\[\]]+)|\[(-?\d+|\*)\]')
      .allMatches(normalized)
      .map((match) => match.group(1) ?? match.group(2)!)
      .toList();
  if (tokens.isEmpty || tokens.join().isEmpty) return const [];
  var values = <Object?>[root];
  for (final token in tokens) {
    final next = <Object?>[];
    for (final value in values) {
      if (token == '*' && value is List) {
        next.addAll(value);
      } else if (value is Map && value.containsKey(token)) {
        next.add(value[token]);
      } else if (value is List) {
        final rawIndex = int.tryParse(token);
        if (rawIndex != null) {
          final index = normalizeSourceIndex(rawIndex, value.length);
          if (index >= 0 && index < value.length) next.add(value[index]);
        }
      }
    }
    values = next;
  }
  return values;
}

bool _usesJsonPathSyntax(String path) {
  return path.contains('[?') ||
      path.contains('..') ||
      path.contains('[*]') ||
      path.contains("['") ||
      path.contains('["') ||
      RegExp(r'\[[^\]]*[:,][^\]]*\]').hasMatch(path);
}

String normalizeLegacySourceJsonPath(String input) {
  // Jayway accepts the legacy root-array spelling $.[*].
  final normalized = input.startsWith(r'$.[')
      ? r'$' + input.substring(2)
      : input;
  return normalized.replaceAllMapped(RegExp(r'\[\?\((.*?)\)\]'), (match) {
    return '[?${match.group(1)}]';
  });
}
