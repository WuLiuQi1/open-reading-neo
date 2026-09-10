# Apple membership purchase completion

Current product: com.niki.xxread.premium.lifetime, a non-consumable lifetime unlock. Do not introduce subscription/renewal claims or hard-coded prices.

Implementation plan:
1. Keep the verified membership gate from the previous change. Show both real benefits before purchase: additional source protocols and private-network book sources. Explain opt-in setup and that sources/content are not supplied.
2. Replace the old support/experimental paywall with a focused, adaptive member screen. Use StoreKit prices, a single purchase action, honest asynchronous status, and a restore action visible to all signed-in Apple users including existing members.
3. Preserve the existing StoreKit 2 purchase owner. Add native AppStore.sync on explicit restoration and StoreKit refund request UI; use Apple's system purchase sheet, never simulate payment success.
4. Add reachable membership terms, privacy details and Apple standard EULA, without an artificial recurring-subscription agreement. Existing app privacy/terms language is reused where applicable; disclose purchase verification data.
5. Protect behavior with service, channel and widget tests; validate phone/tablet, light/dark and large type, run Flutter analysis, and compile the iOS simulator build.
6. Remove replaced support-card/purchase-button code and obsolete generic-benefit notices. Preserve non-Apple redemption support and unrelated worktree edits.

Public release boundary: live requests to https://open.xxread.top/privacy and /terms returned 404 on 2026-09-10. Do not link users to those missing pages or claim the App Store public privacy URL is ready. Supply readable in-app policies and publishable documents; public hosting and actual sandbox purchase/refund approval are separate release checks.

References: Apple App Review Guidelines 2.3, 3.1.1; StoreKit AppStore.sync documentation; Transaction.beginRefundRequest(in:) documentation. Current Flutter in_app_purchase_storekit 0.4.11 defaults to StoreKit 2 and restores currentEntitlements without AppStore.sync, so the explicit sync bridge fills that gap.


Validation evidence (2026-09-10):
- Account service: 32 passed; Apple purchase service: 18 passed; native channel: 6 passed.
- Account page navigation: 4 passed, including logged-out access to offline privacy.
- Premium settings visibility: 2 passed (phone and tablet, grant and revoke).
- Full Flutter analysis: no issues.
- Xcode arm64 iPhone 18 Pro simulator build succeeded, including the complete Flutter application and ApplePurchaseSupportBridge.swift. Final log: /tmp/open-reading-membership-final-xcode.log.
- The generic Flutter simulator build with Xcode 27 failed in Flutter's framework-thinning step: it treated "arm64 x86_64" as a single architecture even though lipo reported both. Specifying ARCHS=arm64 / ONLY_ACTIVE_ARCH=YES in xcodebuild succeeds. This is not evidence of an App Store distribution build or real payment validation.
- Local Pods metadata predated the tracked SwiftPM/CocoaPods configuration. Validation used resolved local Pods; build-generated Podfile.lock and Package.resolved changes were restored after verification. No dependency or lock-file migration is included in the membership change.
- Release gaps remain: public privacy hosting, account deletion, server refund/revocation notifications and real sandbox/TestFlight purchase/restore/refund validation.


Final review corrections:
- Native restoration now returns a verified current-entitlement transaction-ID snapshot. The purchase service waits for matching transaction deliveries and verification; a delivery timeout is an error, not an empty restore. Platforms without a snapshot do not infer an empty restore from callback timing.
- A successful HTTP verification response that does not grant premium leaves the transaction unfinished and retryable.
- Android purchase consent and terms omit Apple-only EULA, billing, restore and refund statements.
- Phone light and tablet dark Flutter-rendered previews were inspected, including phone purchase/restore/legal controls. 8 UI tests passed; 2 optional screenshot tests also ran successfully. The screenshots use test account/product data.
- The final updated native snapshot bridge and Flutter application passed the arm64 Xcode simulator build again.

- Local App Store description drafts (Chinese and English) now disclose the optional one-time Premium purchase and the same benefits; no App Store Connect data was submitted.

Final acceptance: 70 related tests passed (18 purchase service, 32 account service, 6 native channel, 8 membership UI, 4 account page, 2 premium settings). Two optional screenshot tests ran separately for visual inspection. Full Flutter analysis and diff checks passed; independent re-review approved all three corrections.
