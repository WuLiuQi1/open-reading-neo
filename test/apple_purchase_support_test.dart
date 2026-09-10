import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/account/apple_purchase_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/apple_purchase_support');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('iOS restore invokes the native sync method', () async {
    MethodCall? receivedCall;
    messenger.setMockMethodCallHandler(channel, (call) async {
      receivedCall = call;
      return ['101', '202', '101'];
    });
    final support = ApplePurchaseSupport(
      channel: channel,
      platform: TargetPlatform.iOS,
    );

    final transactionIds = await support.syncPurchases();

    expect(receivedCall?.method, 'syncPurchases');
    expect(receivedCall?.arguments, isNull);
    expect(transactionIds, {'101', '202'});
  });

  test('iOS restore surfaces native cancellation unchanged', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'purchase_cancelled');
    });
    final support = ApplePurchaseSupport(
      channel: channel,
      platform: TargetPlatform.iOS,
    );

    await expectLater(
      support.syncPurchases(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'purchase_cancelled',
        ),
      ),
    );
  });

  test('iOS restore rejects null or malformed native snapshots', () async {
    final support = ApplePurchaseSupport(
      channel: channel,
      platform: TargetPlatform.iOS,
    );

    for (final response in <Object?>[
      null,
      '101',
      <Object>[101],
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);

      await expectLater(
        support.syncPurchases(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    }
  });

  test(
    'iOS refund sends the product ID and maps every native outcome',
    () async {
      const expected = {
        'submitted': AppleRefundOutcome.submitted,
        'cancelled': AppleRefundOutcome.cancelled,
        'notFound': AppleRefundOutcome.notFound,
        'unavailable': AppleRefundOutcome.unavailable,
      };
      final support = ApplePurchaseSupport(
        channel: channel,
        platform: TargetPlatform.iOS,
      );

      for (final entry in expected.entries) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestRefund');
          expect(call.arguments, {
            'productId': 'com.niki.xxread.premium.lifetime',
          });
          return entry.key;
        });

        expect(
          await support.requestRefund('com.niki.xxread.premium.lifetime'),
          entry.value,
        );
      }
    },
  );

  test('unexpected native refund values are surfaced as an error', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'unknown');
    final support = ApplePurchaseSupport(
      channel: channel,
      platform: TargetPlatform.iOS,
    );

    await expectLater(
      support.requestRefund('com.niki.xxread.premium.lifetime'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('non-iOS platforms do not invoke the native bridge', () async {
    var invocationCount = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      invocationCount += 1;
      return 'submitted';
    });
    final support = ApplePurchaseSupport(
      channel: channel,
      platform: TargetPlatform.android,
    );

    expect(support.supportsNativeRefund, isFalse);
    expect(await support.syncPurchases(), isNull);
    expect(
      await support.requestRefund('com.niki.xxread.premium.lifetime'),
      AppleRefundOutcome.unavailable,
    );
    expect(invocationCount, 0);
  });
}
