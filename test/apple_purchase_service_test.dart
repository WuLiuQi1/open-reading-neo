import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:xxread/services/account/account.dart';

void main() {
  test('verified Apple purchase completes and publishes membership', () async {
    final store = _FakeAppleStore();
    MemberMembership? membership;
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (purchase) async {
        expect(purchase.verificationData.serverVerificationData, 'signed-jws');
        return _premiumMembership();
      },
      onMembership: (value) => membership = value,
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.initialize();
    await service.purchase();
    expect(store.purchaseStarted, isTrue);
    expect(service.phase, ApplePurchasePhase.purchasing);

    store.emit(_purchase(PurchaseStatus.purchased));
    await pumpEventQueue();

    expect(membership?.premium, isTrue);
    expect(store.completed, hasLength(1));
    expect(service.phase, ApplePurchasePhase.purchased);
    expect(service.error, isNull);
  });

  test('purchase binds the authenticated account UUID to StoreKit', () async {
    final store = _FakeAppleStore();
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.purchase();

    expect(store.purchaseParam?.applicationUserName, _accountId);
  });

  for (final accountId in <String?>[null, '', 'not-a-uuid']) {
    test(
      'purchase rejects missing or invalid account id: $accountId',
      () async {
        final store = _FakeAppleStore();
        final service = ApplePremiumPurchaseService(
          productId: _productId,
          accountIdProvider: () => accountId,
          store: store,
          verify: (_) async => _premiumMembership(),
        );
        addTearDown(store.close);
        addTearDown(service.dispose);

        await expectLater(
          service.purchase(),
          throwsA(isA<MemberAccountException>()),
        );

        expect(store.productQueryCount, 0);
        expect(store.purchaseParam, isNull);
      },
    );
  }

  test('account switch while product loads cannot start a purchase', () async {
    var accountId = _accountId;
    final products = Completer<ProductDetailsResponse>();
    final store = _FakeAppleStore(queryResponse: () => products.future);
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: () => accountId,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    final purchase = service.purchase();
    await pumpEventQueue();
    accountId = _otherAccountId;
    products.complete(_availableProducts());

    await expectLater(
      purchase,
      throwsA(
        isA<MemberAccountException>().having(
          (error) => error.message,
          'message',
          contains('账号已切换'),
        ),
      ),
    );
    expect(store.purchaseParam, isNull);
  });

  test(
    'account switch during verification cannot complete or publish',
    () async {
      var accountId = _accountId;
      final verification = Completer<MemberMembership>();
      final store = _FakeAppleStore();
      var published = false;
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: () => accountId,
        store: store,
        verify: (_) => verification.future,
        onMembership: (_) => published = true,
      );
      addTearDown(store.close);
      addTearDown(service.dispose);
      await service.purchase();

      store.emit(_purchase(PurchaseStatus.purchased));
      await pumpEventQueue();
      accountId = _otherAccountId;
      verification.complete(_premiumMembership());
      await pumpEventQueue();

      expect(store.completed, isEmpty);
      expect(published, isFalse);
      expect(service.phase, ApplePurchasePhase.failed);
      expect(service.error, contains('账号已切换'));
    },
  );

  test('restore binds the authenticated account UUID to StoreKit', () async {
    final store = _FakeAppleStore();
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(store.restoreApplicationUserName, _accountId);
  });

  test(
    'account switch during restore cannot complete the transaction',
    () async {
      var accountId = _accountId;
      final verification = Completer<MemberMembership>();
      final store = _FakeAppleStore(
        restoreTransactionIds: const {'restore-account-switch'},
        onRestore: (store) => store.emit(
          _purchase(
            PurchaseStatus.restored,
            purchaseID: 'restore-account-switch',
          ),
        ),
      );
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: () => accountId,
        store: store,
        verify: (_) => verification.future,
      );
      addTearDown(store.close);
      addTearDown(service.dispose);

      final restore = service.restore();
      await pumpEventQueue();
      accountId = _otherAccountId;
      verification.complete(_premiumMembership());

      await expectLater(restore, throwsA(isA<MemberAccountException>()));
      expect(store.completed, isEmpty);
      expect(service.phase, ApplePurchasePhase.failed);
      expect(service.error, contains('账号已切换'));
    },
  );

  test('verified sandbox purchase finishes without granting premium', () async {
    final store = _FakeAppleStore();
    MemberMembership? published;
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _testMembership(premium: false),
      onMembership: (membership) => published = membership,
    );
    addTearDown(store.close);
    addTearDown(service.dispose);
    await service.purchase();

    store.emit(_purchase(PurchaseStatus.purchased));
    await pumpEventQueue();

    expect(store.completed, hasLength(1));
    expect(published?.premium, isFalse);
    expect(published?.testPurchase, isTrue);
    expect(service.phase, ApplePurchasePhase.testVerified);
    expect(service.error, isNull);
  });

  test(
    'sandbox response preserves independent formal premium access',
    () async {
      final membership = _testMembership(premium: true);

      expect(membership.testPurchase, isTrue);
      expect(membership.premium, isTrue);
    },
  );

  for (final premium in [false, true]) {
    test(
      'revoked purchase completes and preserves aggregate premium=$premium',
      () async {
        final store = _FakeAppleStore();
        MemberMembership? published;
        final service = ApplePremiumPurchaseService(
          productId: _productId,
          accountIdProvider: _accountIdProvider,
          store: store,
          verify: (_) async => _revokedMembership(premium: premium),
          onMembership: (membership) => published = membership,
        );
        addTearDown(store.close);
        addTearDown(service.dispose);
        await service.purchase();

        store.emit(_purchase(PurchaseStatus.purchased));
        await pumpEventQueue();

        expect(store.completed, hasLength(1));
        expect(published?.premium, premium);
        expect(published?.purchaseStatus, 'revoked');
        expect(service.phase, ApplePurchasePhase.revoked);
        expect(service.error, isNull);
      },
    );
  }

  test(
    'account switch while StoreKit completion waits cannot publish',
    () async {
      var accountId = _accountId;
      final completionStarted = Completer<void>();
      final completionGate = Completer<void>();
      final store = _FakeAppleStore(
        completionStarted: completionStarted,
        completionGate: completionGate,
      );
      var published = false;
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: () => accountId,
        store: store,
        verify: (_) async => _premiumMembership(),
        onMembership: (_) => published = true,
      );
      addTearDown(store.close);
      addTearDown(service.dispose);
      await service.purchase();

      store.emit(_purchase(PurchaseStatus.purchased));
      await completionStarted.future;
      accountId = _otherAccountId;
      completionGate.complete();
      await pumpEventQueue();

      expect(store.completed, hasLength(1));
      expect(published, isFalse);
      expect(service.phase, ApplePurchasePhase.failed);
      expect(service.error, contains('账号已切换'));
    },
  );

  test('restored sandbox purchase reports test verification', () async {
    final store = _FakeAppleStore(
      restoreTransactionIds: const {'sandbox-transaction'},
      onRestore: (store) => store.emit(
        _purchase(PurchaseStatus.restored, purchaseID: 'sandbox-transaction'),
      ),
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _testMembership(premium: false),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(store.completed, hasLength(1));
    expect(service.phase, ApplePurchasePhase.testVerified);
  });

  test('restored revoked purchase completes without retrying', () async {
    final store = _FakeAppleStore(
      restoreTransactionIds: const {'revoked-transaction'},
      onRestore: (store) => store.emit(
        _purchase(PurchaseStatus.restored, purchaseID: 'revoked-transaction'),
      ),
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _revokedMembership(premium: false),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(store.completed, hasLength(1));
    expect(service.phase, ApplePurchasePhase.revoked);
    expect(service.error, isNull);
  });

  test('restore reports when there are no purchases to restore', () async {
    final store = _FakeAppleStore();
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(store.restoreCalled, isTrue);
    expect(store.productQueryCount, 0);
    expect(service.phase, ApplePurchasePhase.nothingToRestore);
    expect(service.loading, isFalse);
  });

  test('restore waits for all server verification before succeeding', () async {
    final delivery = Completer<void>();
    final verification = Completer<MemberMembership>();
    final store = _FakeAppleStore(
      restoreTransactionIds: const {'200000000000001'},
      onRestore: (store) {
        unawaited(
          delivery.future.then(
            (_) => store.emit(_purchase(PurchaseStatus.purchased)),
          ),
        );
      },
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) => verification.future,
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    var restoreCompleted = false;
    final restore = service.restore().whenComplete(
      () => restoreCompleted = true,
    );
    await pumpEventQueue();

    expect(service.phase, ApplePurchasePhase.restoring);
    expect(service.loading, isTrue);
    expect(restoreCompleted, isFalse);

    delivery.complete();
    await pumpEventQueue();
    expect(service.phase, ApplePurchasePhase.verifying);
    expect(restoreCompleted, isFalse);

    verification.complete(_premiumMembership());
    await restore;

    expect(restoreCompleted, isTrue);
    expect(store.completed, hasLength(1));
    expect(service.phase, ApplePurchasePhase.restored);
  });

  test('concurrent duplicate deliveries verify and finish only once', () async {
    final verification = Completer<MemberMembership>();
    final store = _FakeAppleStore();
    var verificationCount = 0;
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) {
        verificationCount++;
        return verification.future;
      },
    );
    addTearDown(store.close);
    addTearDown(service.dispose);
    await service.initialize();

    final purchase = _purchase(PurchaseStatus.purchased);
    store.emit(purchase);
    store.emit(purchase);
    await pumpEventQueue();

    expect(verificationCount, 1);
    expect(service.phase, ApplePurchasePhase.verifying);

    verification.complete(_premiumMembership());
    await pumpEventQueue();

    expect(store.completed, hasLength(1));
    expect(service.phase, ApplePurchasePhase.purchased);
  });

  test(
    'pending and canceled purchases have distinct non-error phases',
    () async {
      final store = _FakeAppleStore();
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: _accountIdProvider,
        store: store,
        verify: (_) async => _premiumMembership(),
      );
      addTearDown(store.close);
      addTearDown(service.dispose);
      await service.initialize();

      store.emit(_purchase(PurchaseStatus.pending));
      await pumpEventQueue();
      expect(service.phase, ApplePurchasePhase.pending);
      expect(service.loading, isFalse);
      expect(service.error, isNull);

      store.emit(_purchase(PurchaseStatus.canceled));
      await pumpEventQueue();
      expect(service.phase, ApplePurchasePhase.canceled);
      expect(service.error, isNull);
    },
  );

  test(
    'failed verification leaves transaction unfinished and retryable',
    () async {
      final store = _FakeAppleStore();
      var attempts = 0;
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: _accountIdProvider,
        store: store,
        verify: (_) async {
          attempts++;
          if (attempts == 1) {
            throw const MemberAccountException('交易验证失败');
          }
          return _premiumMembership();
        },
      );
      addTearDown(store.close);
      addTearDown(service.dispose);
      await service.initialize();

      final purchase = _purchase(PurchaseStatus.purchased);
      store.emit(purchase);
      await pumpEventQueue();

      expect(attempts, 1);
      expect(store.completed, isEmpty);
      expect(service.phase, ApplePurchasePhase.failed);
      expect(service.error, '交易验证失败');

      store.emit(purchase);
      await pumpEventQueue();

      expect(attempts, 2);
      expect(store.completed, hasLength(1));
      expect(service.phase, ApplePurchasePhase.purchased);
      expect(service.error, isNull);
    },
  );

  test('restore works without loading an unavailable product', () async {
    final store = _FakeAppleStore(
      available: false,
      restoreTransactionIds: const {'200000000000001'},
      onRestore: (store) => store.emit(_purchase(PurchaseStatus.restored)),
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(store.productQueryCount, 0);
    expect(store.completed, hasLength(1));
    expect(service.phase, ApplePurchasePhase.restored);
  });

  test(
    'product loading cannot overwrite an active verification phase',
    () async {
      final productResponse = Completer<ProductDetailsResponse>();
      final verification = Completer<MemberMembership>();
      final store = _FakeAppleStore(
        queryResponse: () => productResponse.future,
      );
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: _accountIdProvider,
        store: store,
        verify: (_) => verification.future,
      );
      addTearDown(store.close);
      addTearDown(service.dispose);

      final initialization = service.initialize();
      expect(service.phase, ApplePurchasePhase.loadingProduct);

      store.emit(_purchase(PurchaseStatus.purchased));
      await pumpEventQueue();
      expect(service.phase, ApplePurchasePhase.verifying);

      productResponse.complete(_availableProducts());
      await initialization;
      expect(service.phase, ApplePurchasePhase.verifying);

      verification.complete(_premiumMembership());
      await pumpEventQueue();
      expect(service.phase, ApplePurchasePhase.purchased);
    },
  );

  test(
    'restore includes transactions that arrive during verification',
    () async {
      final firstVerification = Completer<MemberMembership>();
      final secondVerification = Completer<MemberMembership>();
      final store = _FakeAppleStore(
        restoreTransactionIds: const {'first', 'second'},
        onRestore: (store) =>
            store.emit(_purchase(PurchaseStatus.restored, purchaseID: 'first')),
      );
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: _accountIdProvider,
        store: store,
        verify: (purchase) => purchase.purchaseID == 'first'
            ? firstVerification.future
            : secondVerification.future,
      );
      addTearDown(store.close);
      addTearDown(service.dispose);

      var completed = false;
      final restore = service.restore().whenComplete(() => completed = true);
      await pumpEventQueue();
      store.emit(_purchase(PurchaseStatus.restored, purchaseID: 'second'));
      await pumpEventQueue();

      firstVerification.complete(_premiumMembership());
      await pumpEventQueue();
      expect(completed, isFalse);

      secondVerification.complete(_premiumMembership());
      await restore;
      expect(store.completed, hasLength(2));
      expect(service.phase, ApplePurchasePhase.restored);
    },
  );

  test('restore cancellation is not reported as nothing to restore', () async {
    final store = _FakeAppleStore(
      restoreTransactionIds: const {'200000000000001'},
      onRestore: (store) => store.emit(_purchase(PurchaseStatus.canceled)),
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(service.phase, ApplePurchasePhase.canceled);
    expect(service.error, isNull);
  });

  test(
    'restore transaction error is not reported as nothing to restore',
    () async {
      final store = _FakeAppleStore(
        restoreTransactionIds: const {'200000000000001'},
        onRestore: (store) => store.emit(_purchase(PurchaseStatus.error)),
      );
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: _accountIdProvider,
        store: store,
        verify: (_) async => _premiumMembership(),
      );
      addTearDown(store.close);
      addTearDown(service.dispose);

      await expectLater(
        service.restore(),
        throwsA(isA<MemberAccountException>()),
      );

      expect(service.phase, ApplePurchasePhase.failed);
      expect(service.error, 'App Store 购买未完成');
    },
  );

  test('native AppStore sync user cancellation maps to canceled', () async {
    final store = _FakeAppleStore(
      restoreError: PlatformException(code: 'purchase_cancelled'),
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(service.phase, ApplePurchasePhase.canceled);
    expect(service.error, isNull);
  });

  test('AppStore sync failure remains a retryable failed state', () async {
    final store = _FakeAppleStore(
      restoreError: PlatformException(
        code: 'purchase_sync_failed',
        message: '无法同步 App Store 购买',
      ),
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await expectLater(service.restore(), throwsA(isA<PlatformException>()));

    expect(service.phase, ApplePurchasePhase.failed);
    expect(service.error, '无法同步 App Store 购买');
  });

  test('purchase stream errors enter failed phase', () async {
    final store = _FakeAppleStore();
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);
    await service.initialize();

    store.emitError(StateError('transaction stream stopped'));
    await pumpEventQueue();

    expect(service.phase, ApplePurchasePhase.failed);
    expect(service.error, contains('transaction stream stopped'));
  });

  test('in-flight completion does not notify after disposal', () async {
    final verification = Completer<MemberMembership>();
    final store = _FakeAppleStore();
    var membershipPublished = false;
    var notifications = 0;
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) => verification.future,
      onMembership: (_) => membershipPublished = true,
    )..addListener(() => notifications++);
    addTearDown(store.close);
    await service.initialize();

    store.emit(_purchase(PurchaseStatus.purchased));
    await pumpEventQueue();
    service.dispose();
    final notificationsAtDispose = notifications;

    verification.complete(_premiumMembership());
    await pumpEventQueue();

    expect(notifications, notificationsAtDispose);
    expect(membershipPublished, isFalse);
    expect(store.completed, hasLength(1));
  });

  test('non-iOS restore with no stream event returns to idle', () async {
    final store = _FakeAppleStore(restoreTransactionIds: null);
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await service.restore();

    expect(service.phase, ApplePurchasePhase.idle);
  });

  test('missing expected restore callback fails with retry guidance', () async {
    final store = _FakeAppleStore(
      restoreTransactionIds: const {'missing-transaction'},
    );
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      accountIdProvider: _accountIdProvider,
      store: store,
      verify: (_) async => _premiumMembership(),
      restoreDeliveryTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(store.close);
    addTearDown(service.dispose);

    await expectLater(
      service.restore(),
      throwsA(
        isA<MemberAccountException>().having(
          (error) => error.message,
          'message',
          contains('请重试'),
        ),
      ),
    );

    expect(service.phase, ApplePurchasePhase.failed);
    expect(service.error, contains('恢复结果接收超时'));
  });

  test(
    'non-premium verification response stays unfinished and retries',
    () async {
      final store = _FakeAppleStore();
      var attempts = 0;
      final service = ApplePremiumPurchaseService(
        productId: _productId,
        accountIdProvider: _accountIdProvider,
        store: store,
        verify: (_) async {
          attempts++;
          return attempts == 1
              ? MemberMembership.fromJson({
                  'premium': false,
                  'features': <String, bool>{},
                  'entitlements': <Object>[],
                })
              : _premiumMembership();
        },
      );
      addTearDown(store.close);
      addTearDown(service.dispose);
      await service.initialize();

      final purchase = _purchase(PurchaseStatus.purchased);
      store.emit(purchase);
      await pumpEventQueue();
      expect(store.completed, isEmpty);
      expect(service.phase, ApplePurchasePhase.failed);
      expect(service.error, contains('尚未解锁高级会员'));

      store.emit(purchase);
      await pumpEventQueue();
      expect(attempts, 2);
      expect(store.completed, hasLength(1));
      expect(service.phase, ApplePurchasePhase.purchased);
    },
  );
}

const _productId = 'com.niki.xxread.premium.lifetime';
const _accountId = '123e4567-e89b-42d3-a456-426614174000';
const _otherAccountId = '123e4567-e89b-42d3-a456-426614174001';

String? _accountIdProvider() => _accountId;

MemberMembership _premiumMembership() => MemberMembership.fromJson({
  'premium': true,
  'features': <String, bool>{},
  'entitlements': [
    {
      'feature_key': 'premium',
      'source': 'apple_app_store',
      'status': 'active',
      'granted_at': '2026-08-04T00:00:00Z',
      'expires_at': null,
    },
  ],
});

MemberMembership _testMembership({required bool premium}) =>
    MemberMembership.fromJson({
      'premium': premium,
      'test_purchase': true,
      'features': <String, bool>{'premium': true},
      'entitlements': <Object>[],
    });

MemberMembership _revokedMembership({required bool premium}) =>
    MemberMembership.fromJson({
      'premium': premium,
      'purchase_status': 'revoked',
      'features': <String, bool>{},
      'entitlements': <Object>[],
    });

ProductDetailsResponse _availableProducts() => ProductDetailsResponse(
  productDetails: [
    ProductDetails(
      id: _productId,
      title: '永久高级版',
      description: '永久解锁高级版',
      price: '¥28.00',
      rawPrice: 28,
      currencyCode: 'CNY',
      currencySymbol: '¥',
    ),
  ],
  notFoundIDs: const [],
);

PurchaseDetails _purchase(
  PurchaseStatus status, {
  String purchaseID = '200000000000001',
}) => _TestPurchaseDetails(
  purchaseID: purchaseID,
  productID: _productId,
  verificationData: PurchaseVerificationData(
    localVerificationData: '{}',
    serverVerificationData: 'signed-jws',
    source: 'app_store',
  ),
  transactionDate: '1785801600000',
  status: status,
);

class _TestPurchaseDetails extends PurchaseDetails {
  _TestPurchaseDetails({
    super.purchaseID,
    required super.productID,
    required super.verificationData,
    required super.transactionDate,
    required super.status,
  });

  @override
  bool get pendingCompletePurchase => true;
}

typedef _OnRestore = void Function(_FakeAppleStore store);
typedef _QueryResponse = Future<ProductDetailsResponse> Function();

class _FakeAppleStore implements ApplePurchaseStore {
  _FakeAppleStore({
    this.available = true,
    this.onRestore,
    this.restoreError,
    this.queryResponse,
    this.restoreTransactionIds = const <String>{},
    this.completionStarted,
    this.completionGate,
  });

  final bool available;
  final _OnRestore? onRestore;
  final Object? restoreError;
  final _QueryResponse? queryResponse;
  final Set<String>? restoreTransactionIds;
  final Completer<void>? completionStarted;
  final Completer<void>? completionGate;
  final _controller = StreamController<List<PurchaseDetails>>.broadcast();
  final completed = <PurchaseDetails>[];
  bool purchaseStarted = false;
  PurchaseParam? purchaseParam;
  bool restoreCalled = false;
  String? restoreApplicationUserName;
  int productQueryCount = 0;

  void emit(PurchaseDetails purchase) => _controller.add([purchase]);
  void emitError(Object error) => _controller.addError(error);
  Future<void> close() => _controller.close();

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _controller.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async {
    productQueryCount++;
    final response = queryResponse;
    if (response != null) return response();
    return _availableProducts();
  }

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    this.purchaseParam = purchaseParam;
    purchaseStarted = true;
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    final started = completionStarted;
    if (started != null && !started.isCompleted) started.complete();
    await completionGate?.future;
    completed.add(purchase);
  }

  @override
  Future<Set<String>?> restorePurchases({String? applicationUserName}) async {
    restoreCalled = true;
    restoreApplicationUserName = applicationUserName;
    final error = restoreError;
    if (error != null) throw error;
    onRestore?.call(this);
    return restoreTransactionIds;
  }
}
