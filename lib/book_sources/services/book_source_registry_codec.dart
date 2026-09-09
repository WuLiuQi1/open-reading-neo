part of 'book_source_registry.dart';

List<RegisteredBookSource> _decodeRunnableSources(Map<String, Object> request) {
  final raw = request['raw']! as String;
  final additionalEnabled = request['additionalEnabled']! as bool;
  final sources = _decodeStoredSources(raw).where((source) {
    if (source.capabilities.isEmpty) return false;
    return additionalEnabled ||
        source.sourceProtocol == BookSourceProtocolKind.orsp;
  });
  return sources.toList(growable: false);
}

List<RegisteredBookSource> _decodeStoredSources(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return _decodeStoredRegistryValue(decoded).sources;
  } catch (_) {
    return const [];
  }
}

_StoredBookSourceRegistry _decodeStoredRegistryValue(Object? decoded) {
  final sourceItems = decoded is List
      ? decoded
      : decoded is Map && decoded['sources'] is List
      ? decoded['sources']! as List
      : const [];
  final explicitGroups = decoded is Map && decoded['groups'] is List
      ? _normalizeGroupNames((decoded['groups']! as List).whereType<String>())
      : const <String>[];
  final sources = <RegisteredBookSource>[];
  for (final item in sourceItems) {
    if (item is! Map) continue;
    try {
      final stored = RegisteredBookSource.fromJson(
        item.map((key, value) => MapEntry('$key', value)),
      );
      sources.add(_refreshStoredCompatibility(stored));
    } catch (_) {
      // One damaged record must not hide the remaining sources.
    }
  }
  sources.sort((a, b) => a.name.compareTo(b.name));
  return _StoredBookSourceRegistry(sources: sources, groups: explicitGroups);
}

List<String> _decodeStoredGroupNames(String raw) {
  try {
    final decoded = jsonDecode(raw);
    final sourceItems = decoded is List
        ? decoded
        : decoded is Map && decoded['sources'] is List
        ? decoded['sources']! as List
        : const [];
    final groups = decoded is Map && decoded['groups'] is List
        ? _normalizeGroupNames((decoded['groups']! as List).whereType<String>())
        : <String>[];
    final groupRecords = <({String name, List<String> groups})>[];
    for (final item in sourceItems) {
      if (item is! Map) continue;
      final name = item['name'];
      if (name is! String || name.trim().isEmpty) continue;
      final sourceGroups = item.containsKey('groups')
          ? _storedGroupList(item['groups'])
          : _legacyStoredGroupList(item['sourceConfig']);
      groupRecords.add((name: name.trim(), groups: sourceGroups));
    }
    groupRecords.sort((a, b) => a.name.compareTo(b.name));
    final seen = groups.toSet();
    for (final record in groupRecords) {
      for (final group in record.groups) {
        if (seen.add(group)) groups.add(group);
      }
    }
    return groups;
  } catch (_) {
    return const [];
  }
}

List<String> _decodeStoredGroupNamesForSync(String raw) {
  try {
    final decoded = jsonDecode(raw);
    final sourceItems = decoded is List
        ? decoded
        : decoded is Map && decoded['sources'] is List
        ? decoded['sources']! as List
        : throw const FormatException();
    final groups = <String>[];
    if (decoded is Map && decoded.containsKey('groups')) {
      final storedGroups = decoded['groups'];
      if (storedGroups is! List ||
          storedGroups.any((group) => group is! String)) {
        throw const FormatException();
      }
      groups.addAll(_normalizeGroupNames(storedGroups.cast<String>()));
    }
    final groupRecords = <({String name, List<String> groups})>[];
    for (final item in sourceItems) {
      if (item is! Map) throw const FormatException();
      final sourceJson = item.map((key, value) => MapEntry('$key', value));
      final source = RegisteredBookSource.fromJson(sourceJson);
      late final List<String> sourceGroups;
      if (sourceJson.containsKey('groups')) {
        final storedGroups = sourceJson['groups'];
        if (storedGroups is! List ||
            storedGroups.any((group) => group is! String)) {
          throw const FormatException();
        }
        sourceGroups = _normalizeGroupNames(storedGroups.cast<String>());
      } else {
        sourceGroups = _legacyStoredGroupList(sourceJson['sourceConfig']);
      }
      groupRecords.add((name: source.name, groups: sourceGroups));
    }
    groupRecords.sort((a, b) => a.name.compareTo(b.name));
    final seen = groups.toSet();
    for (final record in groupRecords) {
      for (final group in record.groups) {
        if (seen.add(group)) groups.add(group);
      }
    }
    return groups;
  } catch (_) {
    throw const FormatException('The local book source registry is damaged.');
  }
}

List<String> _storedGroupList(Object? value) =>
    value is List ? _normalizeGroupNames(value.whereType<String>()) : const [];

List<String> _legacyStoredGroupList(Object? sourceConfig) {
  if (sourceConfig is! Map) return const [];
  final value = sourceConfig['bookSourceGroup'];
  if (value is! String || value.trim().isEmpty) return const [];
  return _normalizeGroupNames(value.split(RegExp(r'[,;，；\n]')));
}

RegisteredBookSource _refreshStoredCompatibility(RegisteredBookSource source) {
  if (source.sourceProtocol != BookSourceProtocolKind.readingSource ||
      source.sourceConfig == null) {
    return source;
  }
  try {
    final compatible = ReadingSourceConfig.fromJson(source.sourceConfig!);
    // Compatibility is policy, not source data. Always rescan so upgrades
    // (for example image sources becoming supported) take effect immediately.
    final effectiveReport = const SourceCompatibilityScanner().scan(compatible);
    return compatible
        .toRegisteredSource(
          id: source.id,
          enabled: source.enabled,
          readingChainVerified: isReadingChainVerifiedSource(source),
          compatibilityReport: effectiveReport,
          addedAt: source.addedAt,
        )
        .copyWith(isFavorite: source.isFavorite, groups: source.groups);
  } on FormatException {
    // Keep a legacy record visible even if its raw configuration can no
    // longer be executed. The management page can still remove or replace it.
    return source;
  }
}

List<String> _normalizeGroupNames(Iterable<String> groups) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final group in groups) {
    final value = group.trim();
    if (value.isNotEmpty && seen.add(value)) normalized.add(value);
  }
  return normalized;
}

String _requiredGroupName(String name) {
  final normalized = name.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(name, 'name', 'Group name must not be empty.');
  }
  return normalized;
}

List<String> _mergeGroupOrder(
  Iterable<String> explicitGroups,
  Iterable<RegisteredBookSource> sources,
) {
  final groups = _normalizeGroupNames(explicitGroups);
  final seen = groups.toSet();
  for (final source in sources) {
    for (final group in source.groups) {
      if (seen.add(group)) groups.add(group);
    }
  }
  return groups;
}

String _encodeStoredRegistry(Map<String, Object> value) => jsonEncode(value);

class _StoredBookSourceRegistry {
  const _StoredBookSourceRegistry({
    required this.sources,
    required this.groups,
  });

  final List<RegisteredBookSource> sources;
  final List<String> groups;
}
