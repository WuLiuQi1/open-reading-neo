part of 'book_sources_page.dart';

extension _BookSourcesPageTablet on _BookSourcesPageState {
  double get _tabletSidebarWidth =>
      (240 + (MediaQuery.textScalerOf(context).scale(14) - 14) * 4).clamp(
        240.0,
        320.0,
      );

  bool get _usesDiscoverySidebar =>
      LayoutHelper.usesTabletLayout(context) &&
      _layoutController.layout.value == BookSourceDiscoverLayout.standard &&
      math.min(
            MediaQuery.sizeOf(context).width,
            LayoutHelper.tabletContentMaxWidth,
          ) >=
          _tabletSidebarWidth +
              24 +
              LayoutHelper.tabletPagePadding * 2 +
              360 *
                  (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
                    1.0,
                    1.5,
                  );

  double get _sectionHorizontalPadding => _usesDiscoverySidebar
      ? 0
      : LayoutHelper.usesTabletLayout(context)
      ? LayoutHelper.tabletPagePadding
      : 16;

  Widget _buildTabletDiscovery() {
    final chrome = HomeMobileChromeScope.of(context);
    final source = _state.organizedDiscoverySources
        .where((source) => source.id == _state.selectedSourceId)
        .firstOrNull;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: LayoutHelper.tabletContentMaxWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutHelper.tabletPagePadding,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const Key('bookSourceTabletSidebar'),
                  width: _tabletSidebarWidth,
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: chrome.pageTopPadding,
                      bottom: 24,
                    ),
                    child: BookSourceTabletSidebar(
                      sources: _state.organizedDiscoverySources,
                      selectedSourceId: _state.selectedSourceId,
                      includeAllSources: !_state.requiresScopedDiscovery,
                      organizationFilters: _tabletOrganizationFilters(),
                      matchesQuery: BookSourcesPage.listSourceMatchesQuery,
                      onSelected: (id) {
                        _pendingScrollOffset = 0;
                        unawaited(_controller.changeSourceScope(id));
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: RefreshIndicator(
                    key: const Key('bookSourceTabletContent'),
                    edgeOffset: chrome.topBarHeight,
                    onRefresh: _refreshCurrentLayout,
                    child: Scrollbar(
                      controller: _scrollController,
                      child: CustomScrollView(
                        key: const Key('bookSourceDiscoverScrollView'),
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.only(
                              top: chrome.pageTopPadding,
                              bottom: 16,
                            ),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                key: const Key('bookSourceTabletHeader'),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          source?.name ??
                                              context
                                                  .l10n
                                                  .bookSourcesMaintenanceScopeAll,
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      if (source != null)
                                        _sourceActions(source),
                                    ],
                                  ),
                                  if (_state.availableSections.length > 1) ...[
                                    const SizedBox(height: 16),
                                    BookSourceDiscoveryControls(
                                      sources: const [],
                                      includeAllSources: false,
                                      selectedSourceId: _state.selectedSourceId,
                                      sections: _state.availableSections,
                                      selectedSection: _state.section,
                                      allLabel: context.l10n.statsRangeAll,
                                      recommendedLabel:
                                          context.l10n.discoverRecommended,
                                      categoriesLabel:
                                          context.l10n.discoverCategories,
                                      latestLabel: context.l10n.discoverLatest,
                                      onSourceSelected: (_) {},
                                      onSectionSelected: (section) {
                                        _pendingScrollOffset = 0;
                                        unawaited(
                                          _controller.changeSection(section),
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          BookSourceSliverTransition(
                            key: const Key('bookSourceSectionTransition'),
                            identity: _sectionTransitionIdentity,
                            onSwap: _restorePendingScroll,
                            slivers: _buildSectionSlivers(
                              chrome.pageBottomPadding,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabletOrganizationFilters() {
    final copy = BookSourceOrganizationCopy.of(context);
    return Column(
      children: [
        BookSourceSidebarItem(
          key: const Key('bookSourceOrganizationAll'),
          label: copy.all,
          icon: Icons.apps_rounded,
          selected: !_state.hasOrganizationFilter,
          onTap: () {
            _pendingScrollOffset = 0;
            unawaited(_controller.changeOrganizationScope());
          },
        ),
        BookSourceSidebarItem(
          key: const Key('bookSourceOrganizationFavorites'),
          label: copy.favorites,
          icon: Icons.star_outline_rounded,
          selected: _state.favoritesOnly,
          onTap: () {
            _pendingScrollOffset = 0;
            unawaited(_controller.changeOrganizationScope(favoritesOnly: true));
          },
        ),
        BookSourceSidebarItem(
          key: const Key('bookSourceOrganizationGroups'),
          label: _state.selectedGroup ?? copy.groups,
          icon: Icons.folder_outlined,
          selected: _state.selectedGroup != null,
          onTap: _chooseOrganizationGroup,
        ),
      ],
    );
  }
}
