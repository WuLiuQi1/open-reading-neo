import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AppleRefundOutcome { submitted, cancelled, notFound, unavailable }

class ApplePurchaseSupport {
  ApplePurchaseSupport({MethodChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? const MethodChannel(_channelName),
      _platform = platform ?? defaultTargetPlatform;

  static const _channelName = 'com.niki.xxread/apple_purchase_support';

  final MethodChannel _channel;
  final TargetPlatform _platform;

  bool get supportsNativeRefund => !kIsWeb && _platform == TargetPlatform.iOS;

  Future<Set<String>?> syncPurchases() async {
    if (!supportsNativeRefund) return null;

    final value = await _channel.invokeMethod<Object?>('syncPurchases');
    if (value is! List || value.any((item) => item is! String)) {
      throw PlatformException(
        code: 'invalid_response',
        message: 'Unexpected Apple purchase sync response: $value',
      );
    }
    return value.cast<String>().toSet();
  }

  Future<AppleRefundOutcome> requestRefund(String productId) async {
    if (!supportsNativeRefund) return AppleRefundOutcome.unavailable;

    final value = await _channel.invokeMethod<String>('requestRefund', {
      'productId': productId,
    });
    return switch (value) {
      'submitted' => AppleRefundOutcome.submitted,
      'cancelled' => AppleRefundOutcome.cancelled,
      'notFound' => AppleRefundOutcome.notFound,
      'unavailable' => AppleRefundOutcome.unavailable,
      _ => throw PlatformException(
        code: 'invalid_response',
        message: 'Unexpected Apple refund response: $value',
      ),
    };
  }
}
