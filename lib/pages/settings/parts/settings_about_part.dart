part of '../settings_page.dart';

extension _SettingsAboutPart on _SettingsPageState {
  Widget _buildAboutCard() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final palette = PageStyleHelper.palette(context);
    return Container(
      key: const ValueKey('settings-about-card'),
      padding: const EdgeInsets.all(16),
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
              AppBrandIcon(
                size: 44,
                borderRadius: 12,
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.22),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsAppName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.settingsAboutTagline,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('settings-open-source-info'),
                tooltip: l10n.settingsOpenSourceTitle,
                onPressed: _showOpenSourceDetails,
                icon: const Icon(Icons.info_outline_rounded, size: 20),
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          _buildAboutLine(l10n.settingsVersionLabel, _appVersion),
          const SizedBox(height: 4),
          _buildAboutNavigationLink(
            key: const ValueKey('settings-open-source-licenses-link'),
            title: l10n.openSourceLicensesTitle,
            icon: Icons.balance_outlined,
            onTap: _openSourceLicenses,
          ),
          _buildAboutNavigationLink(
            key: const ValueKey('settings-changelog-link'),
            title: l10n.changelogHistoryTitle,
            icon: Icons.history_rounded,
            onTap: _openChangelogHistory,
          ),
          if (!AppDistribution.suppressesExternalUpdates)
            _buildAboutNavigationLink(
              key: const ValueKey('settings-check-updates-link'),
              title: l10n.updateCheckNow,
              icon: Icons.system_update_alt_rounded,
              onTap: _isCheckingForUpdates ? null : _checkForUpdates,
              trailing: _isCheckingForUpdates
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final stack =
                  constraints.maxWidth <
                  240 * MediaQuery.textScalerOf(context).scale(1);
              final width = stack
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: width,
                    child: _buildProjectButton(
                      key: const ValueKey('settings-github-link'),
                      onPressed: _openGithubRepo,
                      backgroundColor: const Color(0xFF181717),
                      icon: Image.asset(
                        'assets/icons/brand_github.png',
                        excludeFromSemantics: true,
                      ),
                      title: 'GitHub',
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _buildProjectButton(
                      key: const ValueKey('settings-website-link'),
                      onPressed: _openOfficialWebsite,
                      backgroundColor: const Color(0xFF2D6A4F),
                      icon: const AppBrandIcon(size: 20, borderRadius: 4),
                      title: l10n.settingsOfficialWebsite,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _buildCommunityButton(
                key: const ValueKey('settings-qq-group-link'),
                onPressed: _openQqGroup,
                icon: Image.asset(
                  'assets/icons/brand_qq.png',
                  excludeFromSemantics: true,
                ),
                title: l10n.settingsQqGroup,
              ),
              _buildCommunityButton(
                key: const ValueKey('settings-qq-channel-link'),
                onPressed: _openQqChannel,
                icon: Image.asset(
                  Theme.of(context).brightness == Brightness.dark
                      ? 'assets/icons/brand_qq_channel_dark.png'
                      : 'assets/icons/brand_qq_channel.png',
                  excludeFromSemantics: true,
                ),
                title: l10n.settingsQqChannel,
              ),
              _buildCommunityButton(
                key: const ValueKey('settings-telegram-link'),
                onPressed: _openTelegramChannel,
                icon: Image.asset(
                  'assets/icons/brand_telegram.png',
                  cacheWidth: 64,
                  excludeFromSemantics: true,
                ),
                title: l10n.settingsTelegramChannel,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showOpenSourceDetails() {
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsOpenSourceTitle),
        content: Text(l10n.settingsOpenSourceDetails),
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              MaterialLocalizations.of(dialogContext).closeButtonLabel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutNavigationLink({
    required Key key,
    required String title,
    required IconData icon,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                trailing ??
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openChangelogHistory() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ChangelogPage()));
  }

  void _openSourceLicenses() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OpenSourceLicensesPage(appVersion: _appVersion),
      ),
    );
  }

  Widget _buildProjectButton({
    required Key key,
    required VoidCallback onPressed,
    required Color backgroundColor,
    required Widget icon,
    required String title,
  }) {
    return FilledButton(
      key: key,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      child: Row(
        children: [
          SizedBox(width: 20, height: 20, child: icon),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_outward_rounded, size: 16),
        ],
      ),
    );
  }

  Widget _buildCommunityButton({
    required Key key,
    required VoidCallback onPressed,
    required Widget icon,
    required String title,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        side: BorderSide(color: PageStyleHelper.palette(context).border),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        visualDensity: VisualDensity.standard,
        textStyle: Theme.of(context).textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 16, height: 16, child: icon),
          const SizedBox(width: 4),
          Flexible(child: Text(title)),
        ],
      ),
    );
  }

  Widget _buildAboutLine(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openGithubRepo() async {
    final uri = Uri.parse('https://github.com/miloquinn/open-reading');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsGithubOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openOfficialWebsite() async {
    final ok = await launchUrl(
      Uri.parse('https://open.xxread.top/'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsOfficialWebsiteOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  void _showDonationDialog(DeveloperDonationMethod method) {
    showDialog<void>(
      context: context,
      builder: (_) => DeveloperDonationDialog(method: method),
    );
  }

  Future<void> _openTelegramChannel() async {
    final uri = Uri.parse('https://t.me/origoreading');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsTelegramOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openQqChannel() async {
    final uri = Uri.parse('https://pd.qq.com/s/diin97dya?b=9');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsQqChannelOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _checkForUpdates() async {
    if (_isCheckingForUpdates) return;
    _mutate(() => _isCheckingForUpdates = true);
    await UpdatePromptController.check(context, manual: true);
    if (mounted) {
      _mutate(() => _isCheckingForUpdates = false);
    }
  }

  Future<void> _openQqGroup() async {
    final uri = Uri.parse(
      'mqqapi://card/show_pslcard?src_type=internal&version=1&uin=1003560209&card_type=group&source=qrcode',
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsQqOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  // 构建操作设置
  Widget _buildActionSetting({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required IconData icon,
    String? badge,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.tertiary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    icon,
                    size: 16,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          if (badge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                badge,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing,
                ] else
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
