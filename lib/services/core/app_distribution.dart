import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Distinguishes App Store commerce from website / GitHub distribution.
///
/// iOS always uses StoreKit. macOS uses StoreKit only for Mac App Store
/// builds, identified by `--dart-define=OPEN_READING_MACOS_APP_STORE=true`
/// or a live `_MASReceipt`. Direct Developer ID / notarized builds keep the
/// website redemption-code flow and do not pay Apple commission on those
/// sales.
class AppDistribution {
  AppDistribution._();

  static const _channelName = 'com.niki.xxread/app_distribution';
  static const _macosAppStoreDefine = bool.fromEnvironment(
    'OPEN_READING_MACOS_APP_STORE',
  );

  static const MethodChannel _channel = MethodChannel(_channelName);

  static bool? _debugOverrideUsesAppleBilling;
  static bool? _runtimeMacAppStore;

  /// Test-only override. `null` restores production detection.
  @visibleForTesting
  static void debugOverride({bool? usesAppleBilling}) {
    _debugOverrideUsesAppleBilling = usesAppleBilling;
  }

  @visibleForTesting
  static void debugReset() {
    _debugOverrideUsesAppleBilling = null;
    _runtimeMacAppStore = null;
  }

  static bool get usesAppleBilling {
    if (_debugOverrideUsesAppleBilling != null) {
      return _debugOverrideUsesAppleBilling!;
    }
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => true,
      TargetPlatform.macOS =>
        _macosAppStoreDefine || (_runtimeMacAppStore ?? false),
      _ => false,
    };
  }

  /// Mac App Store Guideline 2.4.5(vii): store builds may not ship a
  /// separate update mechanism.
  static bool get suppressesExternalUpdates =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      usesAppleBilling;

  static Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      _runtimeMacAppStore = false;
      return;
    }
    if (_macosAppStoreDefine) {
      _runtimeMacAppStore = true;
      return;
    }
    try {
      final value = await _channel.invokeMethod<bool>('isMacAppStore');
      _runtimeMacAppStore = value == true;
    } on MissingPluginException {
      _runtimeMacAppStore = false;
    } on PlatformException {
      _runtimeMacAppStore = false;
    }
  }
}
