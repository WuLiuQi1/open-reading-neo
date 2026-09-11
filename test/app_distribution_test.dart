import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/core/app_distribution.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.niki.xxread/app_distribution');

  setUp(AppDistribution.debugReset);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppDistribution.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS always uses Apple billing', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(AppDistribution.usesAppleBilling, isTrue);
    expect(AppDistribution.suppressesExternalUpdates, isFalse);
  });

  test('Android never uses Apple billing', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(AppDistribution.usesAppleBilling, isFalse);
    expect(AppDistribution.suppressesExternalUpdates, isFalse);
  });

  test('macOS defaults to website billing before a receipt probe', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(AppDistribution.usesAppleBilling, isFalse);
    expect(AppDistribution.suppressesExternalUpdates, isFalse);
  });

  test('macOS website builds keep redemption and external updates', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    AppDistribution.debugOverride(usesAppleBilling: false);
    expect(AppDistribution.usesAppleBilling, isFalse);
    expect(AppDistribution.suppressesExternalUpdates, isFalse);
  });

  test('macOS App Store builds use Apple billing and hide website updates', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    AppDistribution.debugOverride(usesAppleBilling: true);
    expect(AppDistribution.usesAppleBilling, isTrue);
    expect(AppDistribution.suppressesExternalUpdates, isTrue);
  });

  test('macOS receipt probe enables App Store billing at runtime', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'isMacAppStore');
          return true;
        });

    await AppDistribution.initialize();

    expect(AppDistribution.usesAppleBilling, isTrue);
    expect(AppDistribution.suppressesExternalUpdates, isTrue);
  });

  test(
    'macOS website builds stay on redemption when no receipt exists',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'isMacAppStore');
            return false;
          });

      await AppDistribution.initialize();

      expect(AppDistribution.usesAppleBilling, isFalse);
      expect(AppDistribution.suppressesExternalUpdates, isFalse);
    },
  );
}
