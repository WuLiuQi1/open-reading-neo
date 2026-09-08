import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:xxread/services/core/app_build_info.dart';
import 'package:xxread/services/core/changelog_service.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';

class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key, this.service});

  final ChangelogService? service;

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final ChangelogService _service = widget.service ?? ChangelogService();
  Locale? _locale;
  Future<_ChangelogPageData>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_locale == locale) return;
    _locale = locale;
    _data = _load(locale);
  }

  Future<_ChangelogPageData> _load(Locale locale) async {
    final entries = await _service.load(locale);
    final packageInfo = await PackageInfo.fromPlatform();
    final buildNumber = await readAppReleaseBuildNumber(packageInfo);
    return _ChangelogPageData(
      entries: entries,
      version: packageInfo.version,
      buildNumber: buildNumber,
    );
  }

  void _retry() {
    final locale = _locale;
    if (locale == null) return;
    setState(() => _data = _load(locale));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.changelogPageTitle,
      body: FutureBuilder<_ChangelogPageData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(semanticsLabel: l10n.loading),
            );
          }
          final data = snapshot.data;
          if (snapshot.hasError || data == null || data.entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 32),
                  const SizedBox(height: 12),
                  Text(l10n.changelogLoadFailed),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(l10n.retry),
                  ),
                ],
              ),
            );
          }
          final entries = data.entries;
          return ListView.separated(
            padding: floatingSubpagePadding(context),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _VersionCard(
              key: ValueKey('changelog-entry-${entries[index].identity}'),
              entry: entries[index],
              current: data.isCurrent(entries[index]),
              currentLabel: l10n.changelogCurrentVersion,
            ),
          );
        },
      ),
    );
  }
}

class _ChangelogPageData {
  const _ChangelogPageData({
    required this.entries,
    required this.version,
    required this.buildNumber,
  });

  final List<ChangelogEntry> entries;
  final String version;
  final String buildNumber;

  bool isCurrent(ChangelogEntry entry) {
    if (entry.version != version.trim()) return false;
    if (entry.buildNumber case final buildNumber?) {
      return buildNumber == this.buildNumber;
    }
    return !entries.any(
      (candidate) =>
          candidate.version == entry.version && candidate.buildNumber != null,
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    super.key,
    required this.entry,
    required this.current,
    required this.currentLabel,
  });

  final ChangelogEntry entry;
  final bool current;
  final String currentLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = PageStyleHelper.palette(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 17),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                entry.buildNumber == null
                    ? 'v${entry.version}'
                    : 'v${entry.version} (${entry.buildNumber})',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              if (current) ...[
                const SizedBox(width: 9),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    currentLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          for (final item in entry.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      item,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
