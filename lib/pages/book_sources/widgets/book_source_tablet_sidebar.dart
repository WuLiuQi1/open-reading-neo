import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../utils/localization_extension.dart';

/// Source navigation owns its search and scroll, independently of book results.
class BookSourceTabletSidebar extends StatefulWidget {
  const BookSourceTabletSidebar({
    super.key,
    required this.sources,
    required this.selectedSourceId,
    required this.includeAllSources,
    required this.organizationFilters,
    required this.matchesQuery,
    required this.onSelected,
  });

  final List<RegisteredBookSource> sources;
  final String? selectedSourceId;
  final bool includeAllSources;
  final Widget organizationFilters;
  final bool Function(RegisteredBookSource, String) matchesQuery;
  final ValueChanged<String?> onSelected;

  @override
  State<BookSourceTabletSidebar> createState() =>
      _BookSourceTabletSidebarState();
}

class _BookSourceTabletSidebarState extends State<BookSourceTabletSidebar> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sources = widget.sources
        .where((source) => widget.matchesQuery(source, _search.text))
        .toList(growable: false);
    final showAll = widget.includeAllSources && _search.text.trim().isEmpty;
    return Material(
      key: const Key('bookSourceTabletSidebarPanel'),
      color: scheme.surfaceContainerLow.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        controller: _scroll,
        child: CustomScrollView(
          key: const PageStorageKey('bookSourceTabletSourceList'),
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: widget.organizationFilters,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      key: const Key('bookSourceTabletSourceSearch'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: context.l10n.bookSourcesManagementSearchHint,
                        hintMaxLines: 1,
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surface.withValues(alpha: 0.7),
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: context.l10n.bookSourcesClearSearch,
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.bookSources,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        Text(
                          '${sources.length}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              sliver: SliverList.builder(
                itemCount: sources.isEmpty && !showAll
                    ? 1
                    : sources.length + (showAll ? 1 : 0),
                itemBuilder: (context, index) {
                  if (sources.isEmpty && !showAll) {
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        context.l10n.bookSourcesNoMatchingSources,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    );
                  }
                  if (showAll && index == 0) {
                    return BookSourceSidebarItem(
                      key: const Key('bookSourceTabletSourceAll'),
                      label: context.l10n.bookSourcesMaintenanceScopeAll,
                      icon: Icons.auto_stories_outlined,
                      selected: widget.selectedSourceId == null,
                      onTap: () => _select(null),
                    );
                  }
                  final source = sources[index - (showAll ? 1 : 0)];
                  return BookSourceSidebarItem(
                    key: Key('bookSourceTabletSource-${source.id}'),
                    label: source.name,
                    subtitle: source.websiteUrl?.host ?? source.apiBaseUrl.host,
                    icon: source.isFavorite
                        ? Icons.star_rounded
                        : Icons.language_rounded,
                    selected: widget.selectedSourceId == source.id,
                    onTap: () => _select(source.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _select(String? sourceId) {
    FocusScope.of(context).unfocus();
    widget.onSelected(sourceId);
  }
}

class BookSourceSidebarItem extends StatelessWidget {
  const BookSourceSidebarItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: label,
        child: Semantics(
          selected: selected,
          child: Material(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.7)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: selected
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurface,
                                ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
