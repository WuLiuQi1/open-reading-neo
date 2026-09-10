import 'package:html/dom.dart';

import 'package:xxread/book_sources/protocol/book_source_protocol.dart';

import 'source_rule_parser.dart';
import 'source_rule_xpath.dart';

const sourceHtmlAttributeNames = {
  'href',
  'src',
  'content',
  'value',
  'title',
  'alt',
  'data',
  'action',
};

List<Object?> evaluateSourceHtmlRule(
  List<Element> roots,
  String rule, {
  required bool listMode,
  bool allAttributes = false,
}) {
  final isCss = rule.toLowerCase().startsWith('@css:');
  if (isCss) rule = rule.substring(5).trimLeft();
  // Compatible RuleAnalyzer semantics keep separators inside quoted selectors
  // and predicates intact (for example, URLs containing `@`).
  final segments = splitSourceRuleTopLevel(
    rule,
    '@',
  ).where((part) => part.isNotEmpty).toList();
  if (segments.isEmpty) return roots;
  var current = roots;
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index].trim();
    final isLast = index == segments.length - 1;
    final terminal = sourceHtmlTerminalValue(
      current,
      segment,
      singleValue: isLast && !listMode && !allAttributes,
    );
    if (terminal != null && isLast && (!isCss || index > 0)) return terminal;
    current = selectSourceHtml(
      current,
      segment,
      includeRoots: index == 0,
      legacy: !isCss,
    );
    if (current.isEmpty) return const [];
  }
  return listMode ? current : current.map((node) => node.text).toList();
}

List<Object?>? sourceHtmlTerminalValue(
  List<Element> nodes,
  String segment, {
  required bool singleValue,
}) {
  return switch (segment) {
    'text' => nodes.map((node) => node.text).toList(),
    'ownText' => nodes.map(sourceOwnText).toList(),
    'textNodes' => nodes.map(sourceDirectTextNodes).toList(),
    'html' => nodes.map(_sourceCleanHtml).toList(),
    'all' => [nodes.map((node) => node.outerHtml).join()],
    _ when _isNumericHtmlAttributeName(segment) =>
      singleValue
          ? _sourceAttributeValues(
              nodes,
              segment,
            ).take(1).toList(growable: false)
          : _sourceAttributeValues(nodes, segment).toList(growable: false),
    _
        when sourceHtmlAttributeNames.contains(segment.toLowerCase()) ||
            nodes.any((node) => node.attributes.containsKey(segment)) =>
      singleValue
          ? [_sourceAttributeValues(nodes, segment).firstOrNull ?? '']
          : _sourceAttributeValues(nodes, segment).toList(growable: false),
    _ => null,
  };
}

bool _isNumericHtmlAttributeName(String value) =>
    RegExp(r'^[0-9][A-Za-z0-9_.:-]*$').hasMatch(value);

String _sourceCleanHtml(Element node) {
  final clone = node.clone(true);
  clone
      .querySelectorAll('script, style')
      .forEach((element) => element.remove());
  return clone.outerHtml;
}

// Share ordered, nonblank attribute extraction between scalar metadata and
// joined content. Scalar callers stop after the first value, avoiding a scan
// of the remaining nodes; list callers follow the compatibility URL order.
Iterable<String> _sourceAttributeValues(
  List<Element> nodes,
  String segment,
) sync* {
  final seen = <String>{};
  for (final node in nodes) {
    final value = node.attributes[segment];
    if (value != null && value.trim().isNotEmpty && seen.add(value)) {
      yield value;
    }
  }
}

List<Element> selectSourceHtml(
  List<Element> roots,
  String raw, {
  required bool includeRoots,
  bool legacy = true,
}) {
  final parsed = legacy
      ? parseSourceLegacySelector(raw)
      : SourceLegacySelector(css: raw);
  final selected = <Element>[];
  for (final root in roots) {
    final candidates = parsed.directChildren
        ? root.children.toList()
        : parsed.text != null
        ? <Element>[root, ...root.querySelectorAll('*')]
              .where(
                (element) => sourceOwnText(
                  element,
                ).toLowerCase().contains(parsed.text!.toLowerCase()),
              )
              .toList()
        : _selectSourceCss(root, parsed.css, includeRoot: includeRoots);
    // Indexes belong to each parent context, including exclusion and ranges.
    // Combining first would discard entries from later catalog sections.
    if (parsed.excludedSelection != null) {
      final excluded = sourceSelectionIndexes(
        parsed.excludedSelection!,
        candidates.length,
      ).toSet();
      selected.addAll([
        for (var index = 0; index < candidates.length; index++)
          if (!excluded.contains(index)) candidates[index],
      ]);
    } else if (parsed.selection != null) {
      selected.addAll(
        sourceSelectionIndexes(
          parsed.selection!,
          candidates.length,
        ).map((index) => candidates[index]),
      );
    } else {
      selected.addAll(candidates);
    }
  }
  return selected;
}

List<Element> _selectSourceCss(
  Element root,
  String selector, {
  required bool includeRoot,
}) {
  final compatible = selectSourceHtmlWithJsoupExtensions(
    root,
    selector,
    includeRoot: includeRoot,
  );
  if (compatible != null) return compatible;
  try {
    return [
      if (includeRoot && sourceHtmlMatches(root, selector)) root,
      ...root.querySelectorAll(selector),
    ];
  } on FormatException {
    throw BookSourceProtocolException(
      'Unsupported reading source CSS selector: $selector.',
    );
  } on UnimplementedError {
    throw BookSourceProtocolException(
      'Unsupported reading source CSS selector: $selector.',
    );
  }
}

List<Element>? selectSourceHtmlWithJsoupExtensions(
  Element root,
  String selector, {
  required bool includeRoot,
}) {
  final attributeMatches = _findJsoupAttributeRegexes(selector);
  if (attributeMatches.isEmpty && _findInnermostJsoupPseudo(selector) == null) {
    return null;
  }
  final candidates = <Element>[root, ...root.querySelectorAll('*')];
  final markers = <String>[];
  Map<Element, int>? siblingIndexes;
  var rewritten = selector;
  var markerSuffix = 0;
  String nextMarker() {
    late String marker;
    do {
      marker = 'data-open-reading-compat-${markerSuffix++}';
    } while (markers.contains(marker) ||
        candidates.any(
          (candidate) => candidate.attributes.containsKey(marker),
        ));
    markers.add(marker);
    return marker;
  }

  try {
    for (final match in attributeMatches.reversed) {
      final attribute = match.attribute.toLowerCase();
      final pattern = sourceJsoupAttributeRegExp(
        stripSourceRuleQuotes(match.pattern.trim()),
      );
      final marker = nextMarker();
      for (final candidate in candidates) {
        final value = candidate.attributes[attribute];
        if (value != null && pattern.hasMatch(value)) {
          candidate.attributes[marker] = '';
        }
      }
      rewritten = rewritten.replaceRange(match.start, match.end, '[$marker]');
    }
    while (true) {
      final pseudo = _findInnermostJsoupPseudo(rewritten);
      if (pseudo == null) break;
      final marker = nextMarker();
      if (_isJsoupPositionPseudo(pseudo.name)) {
        siblingIndexes ??= _sourceSiblingIndexes(candidates);
      }
      final argument = stripSourceRuleQuotes(pseudo.argument.trim());
      final nthChild = pseudo.name.toLowerCase() == 'nth-child'
          ? _sourceNthChildFormula(argument)
          : null;
      for (final candidate in candidates) {
        if (_matchesJsoupPseudo(
          candidate,
          pseudo.name,
          argument,
          siblingIndexes: siblingIndexes,
          nthChild: nthChild,
        )) {
          candidate.attributes[marker] = '';
        }
      }
      rewritten = rewritten.replaceRange(pseudo.start, pseudo.end, '[$marker]');
    }
    if (markers.isEmpty) return null;
    if (rewritten.trimLeft().startsWith('>')) {
      return _selectRelativeElements(root, rewritten);
    }
    return <Element>[
      if (includeRoot && sourceHtmlMatches(root, rewritten)) root,
      ...root.querySelectorAll(rewritten),
    ];
  } on FormatException {
    return null;
  } on UnimplementedError {
    return null;
  } finally {
    for (final candidate in candidates) {
      for (final marker in markers) {
        candidate.attributes.remove(marker);
      }
    }
  }
}

bool _matchesJsoupPseudo(
  Element element,
  String name,
  String argument, {
  Map<Element, int>? siblingIndexes,
  (int, int)? nthChild,
}) {
  switch (name.toLowerCase()) {
    case 'contains':
      return sourceHtmlText(
        element,
      ).toLowerCase().contains(normalizeSourceHtmlText(argument).toLowerCase());
    case 'containsown':
      return sourceOwnText(
        element,
      ).toLowerCase().contains(normalizeSourceHtmlText(argument).toLowerCase());
    case 'matches':
      return sourceJsoupAttributeRegExp(
        argument,
      ).hasMatch(sourceHtmlText(element));
    case 'matchesown':
      return sourceJsoupAttributeRegExp(
        argument,
      ).hasMatch(sourceOwnText(element));
    case 'has':
      return _matchesRelativeSelector(element, argument);
    case 'nth-child':
      if (nthChild == null) return false;
      final (coefficient, offset) = nthChild;
      final position = (siblingIndexes?[element] ?? 0) + 1;
      if (coefficient == 0) return position == offset;
      final distance = position - offset;
      return distance % coefficient == 0 && distance ~/ coefficient >= 0;
    case 'eq':
    case 'lt':
    case 'gt':
      final index = siblingIndexes?[element] ?? 0;
      final expected = int.tryParse(argument);
      if (expected == null) return false;
      if (name.toLowerCase() == 'eq') return index == expected;
      if (name.toLowerCase() == 'lt') return index < expected;
      return index > expected;
  }
  return false;
}

bool _isJsoupPositionPseudo(String name) =>
    const {'eq', 'lt', 'gt', 'nth-child'}.contains(name.toLowerCase());

(int, int)? _sourceNthChildFormula(String argument) {
  final formula = argument.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (formula == 'odd') return (2, 1);
  if (formula == 'even') return (2, 0);
  final position = int.tryParse(formula);
  if (position != null) return (0, position);
  final match = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(formula);
  if (match == null) return null;
  final coefficient = switch (match.group(1)!) {
    '' || '+' => 1,
    '-' => -1,
    final value => int.parse(value),
  };
  return (coefficient, int.parse(match.group(2) ?? '0'));
}

Map<Element, int> _sourceSiblingIndexes(List<Element> candidates) {
  final indexes = <Element, int>{};
  final indexedParents = <Element>{};
  for (final candidate in candidates) {
    final parent = candidate.parent;
    if (parent is! Element || !indexedParents.add(parent)) continue;
    final siblings = parent.children.toList(growable: false);
    for (var index = 0; index < siblings.length; index++) {
      indexes[siblings[index]] = index;
    }
  }
  return indexes;
}

bool _matchesRelativeSelector(Element element, String selector) {
  final normalized = selector.trim();
  if (normalized.startsWith('>')) {
    return _selectRelativeElements(element, normalized).isNotEmpty;
  }
  return element.querySelector(normalized) != null;
}

List<Element> _selectRelativeElements(Element element, String selector) {
  return _selectRelativeFrom(<Element>[element], selector);
}

List<Element> _selectRelativeFrom(List<Element> anchors, String selector) {
  final trimmed = selector.trimLeft();
  if (trimmed.isEmpty) return anchors;
  final relation = const {'>', '+', '~'}.contains(trimmed[0])
      ? trimmed[0]
      : ' ';
  final rule = relation == ' ' ? trimmed : trimmed.substring(1).trimLeft();
  final boundary = _firstTopLevelCombinator(rule);
  final compound = boundary < 0
      ? rule
      : rule.substring(0, boundary).trimRight();
  final remainder = boundary < 0 ? '' : rule.substring(boundary);
  final selected = <Element>[];
  for (final anchor in anchors) {
    final related = switch (relation) {
      '>' => anchor.children,
      '+' => _sourceAdjacentSibling(anchor),
      '~' => sourceFollowingSiblings(anchor),
      _ => anchor.querySelectorAll(compound),
    };
    if (relation == ' ') {
      selected.addAll(related);
    } else {
      selected.addAll(
        related.where((element) => sourceHtmlMatches(element, compound)),
      );
    }
  }
  if (remainder.isEmpty || selected.isEmpty) return selected;
  return _selectRelativeFrom(selected, remainder);
}

Iterable<Element> _sourceAdjacentSibling(Element element) sync* {
  final siblings = element.parent?.children;
  if (siblings == null) return;
  final index = siblings.indexOf(element);
  if (index >= 0 && index + 1 < siblings.length) yield siblings[index + 1];
}

int _firstTopLevelCombinator(String selector) {
  var squareDepth = 0;
  var roundDepth = 0;
  String? quote;
  for (var index = 0; index < selector.length; index++) {
    final char = selector[index];
    if (quote != null) {
      if (char == quote &&
          (index == 0 || selector.codeUnitAt(index - 1) != 92)) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '[') {
      squareDepth++;
    } else if (char == ']') {
      squareDepth--;
    } else if (char == '(') {
      roundDepth++;
    } else if (char == ')') {
      roundDepth--;
    } else if (squareDepth == 0 &&
        roundDepth == 0 &&
        (char == '>' || char == '+' || char == '~' || char.trim().isEmpty)) {
      return index;
    }
  }
  return -1;
}

_SourceJsoupPseudo? _findInnermostJsoupPseudo(String selector) {
  for (var index = 0; index < selector.length; index++) {
    final char = selector[index];
    if (char == '[') {
      final end = _balancedSelectorEnd(selector, index, '[', ']');
      if (end < 0) return null;
      index = end;
      continue;
    }
    if (char != ':') continue;
    final nameMatch = RegExp(
      r'^(containsOwn|contains|matchesOwn|matches|has|eq|lt|gt|nth-child)\(',
      caseSensitive: false,
    ).firstMatch(selector.substring(index + 1));
    if (nameMatch == null) continue;
    final name = nameMatch.group(1)!;
    final open = index + 1 + nameMatch.end - 1;
    final end = _balancedSelectorEnd(selector, open, '(', ')');
    if (end < 0) return null;
    final argument = selector.substring(open + 1, end);
    if (name.toLowerCase() == 'has') {
      final nested = _findInnermostJsoupPseudo(argument);
      if (nested != null) {
        return _SourceJsoupPseudo(
          start: open + 1 + nested.start,
          end: open + 1 + nested.end,
          name: nested.name,
          argument: nested.argument,
        );
      }
    }
    return _SourceJsoupPseudo(
      start: index,
      end: end + 1,
      name: name,
      argument: argument,
    );
  }
  return null;
}

int _balancedSelectorEnd(
  String selector,
  int start,
  String open,
  String close,
) {
  var depth = 1;
  String? quote;
  var escaped = false;
  for (var index = start + 1; index < selector.length; index++) {
    final char = selector[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char.codeUnitAt(0) == 92) {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == open) {
      depth++;
    } else if (char == close && --depth == 0) {
      return index;
    }
  }
  return -1;
}

class _SourceJsoupPseudo {
  const _SourceJsoupPseudo({
    required this.start,
    required this.end,
    required this.name,
    required this.argument,
  });

  final int start;
  final int end;
  final String name;
  final String argument;
}

List<_SourceJsoupAttributeRegex> _findJsoupAttributeRegexes(String selector) {
  final matches = <_SourceJsoupAttributeRegex>[];
  for (var start = 0; start < selector.length; start++) {
    if (selector[start] != '[') continue;
    var depth = 1;
    String? quote;
    var escaped = false;
    for (var index = start + 1; index < selector.length; index++) {
      final char = selector[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char.codeUnitAt(0) == 92) {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (char == quote) quote = null;
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '[') {
        depth++;
      } else if (char == ']' && --depth == 0) {
        final body = selector.substring(start + 1, index);
        final parsed = RegExp(
          r'^\s*([A-Za-z_][A-Za-z0-9_.:-]*)\s*~=\s*([\s\S]+?)\s*$',
        ).firstMatch(body);
        if (parsed != null) {
          matches.add(
            _SourceJsoupAttributeRegex(
              start: start,
              end: index + 1,
              attribute: parsed.group(1)!,
              pattern: parsed.group(2)!,
            ),
          );
        }
        start = index;
        break;
      }
    }
  }
  return matches;
}

class _SourceJsoupAttributeRegex {
  const _SourceJsoupAttributeRegex({
    required this.start,
    required this.end,
    required this.attribute,
    required this.pattern,
  });

  final int start;
  final int end;
  final String attribute;
  final String pattern;
}

RegExp sourceJsoupAttributeRegExp(String source) {
  var pattern = source;
  var caseSensitive = true;
  var multiLine = false;
  var dotAll = false;
  final flags = RegExp(r'^\(\?([ims]+)\)').firstMatch(pattern);
  if (flags != null) {
    final enabled = flags.group(1)!;
    caseSensitive = !enabled.contains('i');
    multiLine = enabled.contains('m');
    dotAll = enabled.contains('s');
    pattern = pattern.substring(flags.end);
  }
  return RegExp(
    pattern,
    caseSensitive: caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
  );
}

bool sourceHtmlMatches(Element element, String selector) {
  final parent = element.parent;
  if (parent != null) {
    return parent.querySelectorAll(selector).contains(element);
  }
  return selector == '*' || selector == element.localName;
}
