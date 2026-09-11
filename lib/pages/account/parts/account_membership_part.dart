// 文件说明：登录方式摘要、账号操作、会员支持与推荐关系界面。
// 技术要点：同一账号功能库内的私有实现拆分，不扩大公开 API。

part of '../account_page.dart';

class _LoginMethodsCard extends StatelessWidget {
  const _LoginMethodsCard({required this.user});

  final MemberUser user;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: context.l10n.accountSignInMethodsTitle,
    icon: Icons.shield_outlined,
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: user.authMethods
          .map(
            (method) => Chip(
              avatar: const Icon(Icons.check_circle_rounded, size: 17),
              label: Text(_methodLabel(context, method)),
            ),
          )
          .toList(growable: false),
    ),
  );

  String _methodLabel(BuildContext context, String method) => switch (method) {
    'github' => 'GitHub',
    'google' => 'Google',
    'passkey' => 'Passkey',
    'password' => context.l10n.accountPassword,
    'email_code' => context.l10n.accountEmail,
    _ => method,
  };
}

class _AccountActionsCard extends StatelessWidget {
  const _AccountActionsCard({
    required this.user,
    required this.onEditProfile,
    required this.onOpenSecurity,
    required this.onOpenReferral,
    required this.onOpenSupport,
  });

  final MemberUser user;
  final VoidCallback onEditProfile;
  final VoidCallback onOpenSecurity;
  final VoidCallback onOpenReferral;
  final VoidCallback onOpenSupport;

  @override
  Widget build(BuildContext context) => _SectionCard(
    child: Column(
      children: [
        _AccountActionTile(
          key: const ValueKey('account-edit-profile'),
          icon: Icons.person_outline_rounded,
          title: context.l10n.accountEditProfile,
          subtitle: '@${user.username}',
          onTap: onEditProfile,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-security'),
          icon: Icons.shield_outlined,
          title: context.l10n.accountSecurityTitle,
          subtitle: user.email,
          onTap: onOpenSecurity,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-referral'),
          icon: Icons.group_add_rounded,
          title: context.l10n.accountInviteTitle,
          subtitle: context.l10n.accountInviteSubtitle,
          onTap: onOpenReferral,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-support'),
          icon: Icons.volunteer_activism_rounded,
          title: context.l10n.accountSupportTitle,
          subtitle: context.l10n.accountSupportFreeSubtitle,
          onTap: onOpenSupport,
        ),
      ],
    ),
  );
}

class _AccountReferralPage extends StatelessWidget {
  const _AccountReferralPage();

  @override
  Widget build(BuildContext context) => Consumer<MemberAccountController>(
    builder: (context, account, child) => FloatingSubpageScaffold(
      title: context.l10n.accountInviteTitle,
      body: ListView(
        padding: floatingSubpagePadding(context, bottom: 40),
        children: [
          if (account.referral != null)
            _ReferralCard(account: account)
          else
            _SectionCard(child: Text(context.l10n.accountInviteSubtitle)),
        ],
      ),
    ),
  );
}

class _AccountActionTile extends StatelessWidget {
  const _AccountActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  /// 破坏性入口用错误色标出来，避免和普通设置项看起来一样。
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = destructive
        ? scheme.errorContainer
        : scheme.primaryContainer;
    final foreground = destructive
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
        leading: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: Icon(icon, size: 21, color: foreground),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: destructive ? scheme.error : null,
          ),
        ),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

class _ReferralCard extends StatefulWidget {
  const _ReferralCard({required this.account});

  final MemberAccountController account;

  @override
  State<_ReferralCard> createState() => _ReferralCardState();
}

class _ReferralCardState extends State<_ReferralCard> {
  final _inviteCode = TextEditingController();

  @override
  void dispose() {
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showSideToast(context, context.l10n.accountInviteCopied);
  }

  Future<void> _bind() async {
    try {
      await widget.account.bindReferral(_inviteCode.text);
      _inviteCode.clear();
      if (mounted) showSideToast(context, context.l10n.accountInviteBound);
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final referral = widget.account.referral;
    if (referral == null) return const SizedBox.shrink();
    final inviter = referral.inviter;
    final colors = Theme.of(context).colorScheme;
    return _SectionCard(
      title: context.l10n.accountInviteTitle,
      icon: Icons.group_add_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.accountInviteSubtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            key: const ValueKey('account-invite-ticket'),
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            decoration: BoxDecoration(
              color: colors.tertiaryContainer.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.tertiary.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.accountInviteMyCode,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colors.onTertiaryContainer.withValues(
                                alpha: 0.7,
                              ),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        referral.inviteCode,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: colors.onTertiaryContainer,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('account-copy-invite-code'),
                  tooltip: context.l10n.accountInviteCopyCode,
                  onPressed: () => _copy(referral.inviteCode),
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('account-share-invite'),
            onPressed: () => _copy(referral.inviteUrl.toString()),
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(context.l10n.accountInviteShareAction),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _InviteStat(
                  value: referral.invitedCount,
                  label: context.l10n.accountInviteStatsInvited,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InviteStat(
                  value: referral.rewardedCount,
                  label: context.l10n.accountInviteStatsRewarded,
                  highlighted: referral.rewardedCount > 0,
                ),
              ),
            ],
          ),
          if (referral.recentInvites.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '最近邀请',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            ...referral.recentInvites
                .take(5)
                .map(
                  (item) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      child: Text(item.name.characters.first.toUpperCase()),
                    ),
                    title: Text(item.name),
                    subtitle: Text(
                      '绑定于 ${MaterialLocalizations.of(context).formatCompactDate(item.boundAt)}',
                    ),
                    trailing: Text(
                      item.status == 'rewarded' ? '已解锁奖励' : '等待兑换',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: item.status == 'rewarded'
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 20),
          Text(
            context.l10n.accountInviteHowItWorks,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _InviteStep(
            number: 1,
            title: context.l10n.accountInviteStepShareTitle,
            body: context.l10n.accountInviteStepShareBody,
          ),
          _InviteStep(
            number: 2,
            title: context.l10n.accountInviteStepBindTitle,
            body: context.l10n.accountInviteStepBindBody,
          ),
          _InviteStep(
            number: 3,
            title: context.l10n.accountInviteStepRedeemTitle,
            body: context.l10n.accountInviteStepRedeemBody,
            last: true,
          ),
          const Divider(height: 30),
          Text(
            context.l10n.accountInviteMyBinding,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (inviter != null)
            Container(
              key: const ValueKey('account-inviter-bound'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    inviter.status == 'rewarded'
                        ? Icons.verified_rounded
                        : Icons.hourglass_top_rounded,
                    color: inviter.status == 'rewarded'
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.accountInviterBound(inviter.name),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${inviter.code} · ${inviter.status == 'rewarded' ? context.l10n.accountInviteRewarded : context.l10n.accountInviteWaiting}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else if (widget.account.membership?.premium != true) ...[
            Text(
              context.l10n.accountInviteBindIntro,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('account-invite-code'),
              controller: _inviteCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: context.l10n.accountInviteBindLabel,
                helperText: context.l10n.accountInviteBindHint,
                prefixIcon: const Icon(Icons.person_add_alt_1_rounded),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('account-bind-invite'),
              onPressed: widget.account.loading ? null : _bind,
              child: Text(context.l10n.accountInviteBindAction),
            ),
          ] else
            Text(
              context.l10n.accountInviteBindingNotNeeded,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _InviteStat extends StatelessWidget {
  const _InviteStat({
    required this.value,
    required this.label,
    this.highlighted = false,
  });

  final int value;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primaryContainer.withValues(alpha: 0.62)
            : colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: highlighted ? colors.primary : colors.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InviteStep extends StatelessWidget {
  const _InviteStep({
    required this.number,
    required this.title,
    required this.body,
    this.last = false,
  });

  final int number;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$number',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: colors.outlineVariant.withValues(alpha: 0.72),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.user, required this.size});

  final MemberUser user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        (user.effectiveName.trim().isEmpty ? user.username : user.effectiveName)
            .characters
            .first
            .toUpperCase(),
        style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w800),
      ),
    );
    return ClipOval(
      child: user.avatarUrl == null
          ? fallback
          : AccountAvatarImage(
              url: Uri.parse(user.avatarUrl!),
              fallback: fallback,
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
    );
  }
}
