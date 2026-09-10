import 'package:shared_preferences/shared_preferences.dart';

const String additionalSourceProtocolsPreferenceKey =
    'additional_source_protocols_v1';
const String privateBookSourceNetworkPreferenceKey =
    'private_book_source_network_v1';

/// Shared runtime gate for consumers outside the widget/provider tree.
/// AppSettingsNotifier keeps this in sync with verified account membership.
/// Never persist the entitlement or restore it from the account UI cache.
class AdvancedFeatureAccess {
  static bool premiumUnlocked = false;

  static Future<bool> additionalProtocolsEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return premiumUnlocked &&
        preferences.getBool(additionalSourceProtocolsPreferenceKey) == true;
  }
}
