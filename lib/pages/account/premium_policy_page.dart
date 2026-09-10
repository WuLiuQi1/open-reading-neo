import 'package:flutter/material.dart';

import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';

enum PremiumPolicy { terms, privacy }

/// Readable offline: legal information never depends on a successful web load.
class PremiumPolicyPage extends StatelessWidget {
  const PremiumPolicyPage({
    super.key,
    required this.policy,
    this.usesAppleBilling = true,
  });

  static final appleEulaUri = Uri.parse(
    'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
  );
  final PremiumPolicy policy;
  final bool usesAppleBilling;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sections = policy == PremiumPolicy.terms
        ? [
            (
              l10n.premiumBenefitsTitle,
              '${l10n.settingsAdditionalSourceProtocolsTitle}\n${l10n.premiumProtocolsBenefit}\n\n${l10n.settingsPrivateBookSourceNetworkTitle}\n${l10n.premiumPrivateNetworkBenefit}\n\n${l10n.premiumSourceNotice}\n${l10n.premiumSetupHint}',
            ),
            (
              l10n.premiumBillingTitle,
              usesAppleBilling
                  ? l10n.premiumBillingBody
                  : l10n.premiumBillingBodyOther,
            ),
            (l10n.premiumAccountBindingTitle, l10n.premiumAccountBindingBody),
            if (usesAppleBilling) ...[
              (l10n.accountAppleRestore, l10n.premiumRestoreHelp),
              (l10n.premiumRefundTitle, l10n.premiumRefundTerms),
            ],
          ]
        : [
            (l10n.agreementV2Section6Title, l10n.agreementV2Section6Body),
            (l10n.premiumPrivacyAccountTitle, l10n.premiumPrivacyAccountBody),
            (l10n.premiumPrivacyPurchaseTitle, l10n.premiumPrivacyPurchaseBody),
          ];
    return FloatingSubpageScaffold(
      title: policy == PremiumPolicy.terms
          ? l10n.premiumMembershipTerms
          : l10n.premiumPrivacyPolicy,
      body: SingleChildScrollView(
        padding: floatingSubpagePadding(context, bottom: 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (title, body) in sections) ...[
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      body,
                      style: const TextStyle(fontSize: 16, height: 1.65),
                    ),
                    const SizedBox(height: 28),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
