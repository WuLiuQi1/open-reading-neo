# Premium advanced features

## Scope and behavior lock

Gate the existing Advanced features section (additional source protocols and private book-source networking) with authenticated, server-confirmed Premium. Preserve ordinary reading, ORSP sources, WebDAV, AI settings and stored user preferences. Hide the whole section and its spacing in phone and tablet settings before unlock. No reviewer-specific behavior.

Before implementation run existing account, settings preference and background registry regressions. Add tests for unverified/cache-only membership, unlock/revoke/logout/account switch, saved flags without membership, both settings layouts, and foreground/background/runtime protocol enforcement.

## Cleanup sequence

1. Introduce one shared effective protocol access check for registry and backend; retain saved preferences but require live verified membership.
2. Bind account changes to existing AppSettingsNotifier, gate effective getters and setters, and update the existing network policy synchronously.
3. Conditionally include the settings section in both layouts; remove redundant settings persistence for the protocol switch.
4. Replace obsolete free-all-features/purchase-experiment/donation membership copy in all locales; keep payment, restore, pricing and lifetime terms intact.
5. Run targeted regressions in isolated processes for stateful widgets, localization generation, Dart analysis and diff checks. Review independently after implementation.

## Fallback findings

- Raw saved protocol flags in runtime consumers bypass membership: replace with common effective check.
- Cached account summary is UI-only: never authorize from cached premium.
- Account switch with failed membership fetch must not inherit old account rights.
- Existing optional-provider default-off embedding behavior and network deny-by-default behavior are grounded fail-safe boundaries; preserve.
- Existing auth callback polling, font restoration and release version fallbacks are outside this change.

## Release limitation

Requested generic purchase copy does not enumerate the two benefits. Apple guidelines 2.3.1 and 3.1.2(c) require clear functionality and paid benefits. Settings visibility is identical for users and reviewers; this code change does not establish App Store readiness. Real StoreKit purchase/restore/revocation and review disclosures still need release validation.

## Implementation and evidence

- `lib/services/core/advanced_feature_access.dart`: common runtime protocol gate and preference keys; no entitlement is saved locally.
- `lib/services/core/app_settings_service.dart` and `lib/main.dart`: bind settings to the current account, derive effective flags, update network access, and preserve user preferences while locked.
- `lib/services/account/member_account_controller.dart`: authenticated server membership is authoritative; announce identity/revocation changes immediately, and verify StoreKit results against the account that began verification. Delayed results for another account leave the transaction unfinished for retry.
- `lib/pages/settings/parts/settings_layout_part.dart`: omit advanced section and its spacing in both layouts; remove redundant generic preference saving from the protocol toggle.
- Registry, reading backend and add-source dialog: reuse the effective access check; a dialog opened before logout cannot authorize a later import.
- Four ARB locales and generated localizations: replace experiment/donation/all-features-free membership claims with generic Premium copy; make donation copy purely voluntary development support. Generic unavailable-source errors do not enumerate hidden settings.
- Tests: new phone/tablet visibility and runtime revocation tests, plus preference/account/StoreKit replay/import regressions. Existing search fixture now uses the current source selector instead of the removed ChoiceChip UI.

Validation collected locally:

- 32 account service tests, including cached identity, live revoke, slow account switching, StoreKit replay without manual restore, in-flight switch and logout.
- 9 app-settings tests; 29 source configuration/background registry tests; 10 network policy tests; 1 direct reading-runtime gate test.
- Stateful widget processes: 4 account page, 2 Premium settings (phone/tablet), 1 donation card, 13 source management, 3 settings preferences, 2 settings navigation/layout, 2 tablet settings layout.
- Search core: 14 tests pass with the repository's isolated-process exclusion; the affected discovery/search case passes alone. The affected reading-source discovery case also passes alone.
- Full discovery/search files initially failed when stateful cases ran together. The existing CI already runs discovery cases in fresh processes and excludes the tagged search case from its core run; use that existing isolation policy. Product code was not changed to mask those timeouts.
- Localization regenerated; no new localization keys or package dependencies added. Existing Japanese/Traditional Chinese missing-translation fallbacks outside this scope remain unchanged.
- Full Flutter analysis and diff whitespace check passed before final import-dialog verification; final verification recorded below.

Not tested: actual App Store sandbox purchase/restore/refund, iPhone/iPad hardware, production account server membership revocation delivery, App Store review acceptance. Verified membership must be re-established after cold start; display-only cached Premium does not unlock offline access by itself.

Final checks: all 14 add-source flow tests passed, including revoked access refusing commit and valid membership reaching commit. Final full `flutter analyze --no-pub` reports no issues; `git diff --check` passes. Final account (32), account page (4), premium settings (2), donation (1) regressions also pass. Independent review findings (stale donation copy and stale dialog entitlement) are resolved. Existing parallel tablet/about-page work was preserved. No commit, App Store upload or production change was performed.
