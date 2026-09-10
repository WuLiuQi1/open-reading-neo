import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'account_api_client.dart';
import 'account_models.dart';
import 'apple_purchase_support.dart';

abstract interface class ApplePurchaseStore {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers);
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<Set<String>?> restorePurchases({String? applicationUserName});
  Future<void> completePurchase(PurchaseDetails purchase);
}

class InAppPurchaseStore implements ApplePurchaseStore {
  const InAppPurchaseStore(this._store);

  final InAppPurchase _store;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _store.purchaseStream;
  @override
  Future<bool> isAvailable() => _store.isAvailable();
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) =>
      _store.queryProductDetails(identifiers);
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _store.buyNonConsumable(purchaseParam: purchaseParam);
  @override
  Future<Set<String>?> restorePurchases({String? applicationUserName}) async {
    final transactionIds = await ApplePurchaseSupport().syncPurchases();
    await _store.restorePurchases(applicationUserName: applicationUserName);
    return transactionIds;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) =>
      _store.completePurchase(purchase);
}

typedef ApplePurchaseVerifier =
    Future<MemberMembership> Function(PurchaseDetails purchase);

enum ApplePurchasePhase {
  idle,
  loadingProduct,
  purchasing,
  pending,
  verifying,
  restoring,
  purchased,
  restored,
  testVerified,
  revoked,
  nothingToRestore,
  canceled,
  failed,
}

/// StoreKit is only a payment channel. The verifier must be backed by the
/// account API so the server remains the source of truth for premium access.
class ApplePremiumPurchaseService extends ChangeNotifier {
  ApplePremiumPurchaseService({
    required this.productId,
    required this._verify,
    required this.accountIdProvider,
    this._store,
    this.onMembership,
    this.restoreDeliveryTimeout = const Duration(seconds: 20),
  });

  final String productId;
  final ApplePurchaseVerifier _verify;
  final ValueGetter<String?> accountIdProvider;
  ApplePurchaseStore? _store;
  final ValueChanged<MemberMembership>? onMembership;
  @visibleForTesting
  final Duration restoreDeliveryTimeout;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final Map<String, Future<bool>> _transactionsInFlight = {};
  ProductDetails? _product;
  Future<void>? _productLoad;
  Future<void>? _restoreOperation;
  _RestoreSession? _restoreSession;
  String? _purchaseAccountId;
  ApplePurchasePhase _phase = ApplePurchasePhase.idle;
  String? _error;
  bool _disposed = false;
  int _verificationCount = 0;
  bool _verificationBatchFailed = false;
  ApplePurchasePhase _verificationSuccessPhase = ApplePurchasePhase.purchased;

  ApplePurchasePhase get phase => _phase;
  bool get busy => switch (_phase) {
    ApplePurchasePhase.loadingProduct ||
    ApplePurchasePhase.purchasing ||
    ApplePurchasePhase.verifying ||
    ApplePurchasePhase.restoring => true,
    _ => false,
  };

  /// Kept for existing callers. New UI can use [phase] for precise feedback.
  bool get loading => busy;
  String? get error => _error;
  ProductDetails? get product => _product;

  ApplePurchaseStore get _activeStore =>
      _store ??= InAppPurchaseStore(InAppPurchase.instance);

  void _ensureListening() {
    _subscription ??= _activeStore.purchaseStream.listen(
      _handlePurchases,
      onError: _handleStreamError,
    );
  }

  /// Attaches the transaction listener once and loads display product data.
  /// Transaction listening and restore do not depend on a successful product
  /// query, so already-owned purchases remain recoverable during storefront
  /// configuration or network failures.
  Future<void> initialize() async {
    _ensureListening();
    if (_product != null) return;
    final existingLoad = _productLoad;
    if (existingLoad != null) return existingLoad;

    final load = _initializeProduct();
    _productLoad = load;
    try {
      await load;
    } finally {
      if (identical(_productLoad, load)) _productLoad = null;
    }
  }

  Future<void> _initializeProduct() async {
    _setPhase(ApplePurchasePhase.loadingProduct);
    try {
      await _loadProduct();
      if (_phase == ApplePurchasePhase.loadingProduct) {
        _setError(null);
        _setPhase(ApplePurchasePhase.idle);
      }
    } catch (error) {
      if (_phase == ApplePurchasePhase.loadingProduct) {
        _setError(error);
        _setPhase(ApplePurchasePhase.failed);
      }
    }
  }

  Future<void> _loadProduct() async {
    const timeout = Duration(seconds: 8);
    if (!await _activeStore.isAvailable().timeout(timeout)) {
      throw const MemberAccountException('App Store 内购暂不可用');
    }
    final response = await _activeStore
        .queryProductDetails({productId})
        .timeout(timeout);
    if (response.error != null) {
      throw MemberAccountException(response.error!.message);
    }
    if (response.productDetails.isEmpty) {
      throw const MemberAccountException('App Store 商品尚未配置或不可用');
    }
    _product = response.productDetails.first;
    _notifyListeners();
  }

  Future<void> purchase() async {
    final accountId = _requireAccountId();
    await initialize();
    _ensureSameAccount(accountId);
    _setPhase(ApplePurchasePhase.purchasing);
    _setError(null);
    try {
      final product = _product;
      if (product == null) throw const MemberAccountException('商品信息未加载');
      _purchaseAccountId = accountId;
      final started = await _activeStore.buyNonConsumable(
        purchaseParam: PurchaseParam(
          productDetails: product,
          applicationUserName: accountId,
        ),
      );
      if (!started) throw const MemberAccountException('无法启动 App Store 购买');
    } catch (error) {
      _purchaseAccountId = null;
      if (_isCancellation(error)) {
        _setError(null);
        _setPhase(ApplePurchasePhase.canceled);
        return;
      }
      _setError(error);
      _setPhase(ApplePurchasePhase.failed);
      rethrow;
    }
  }

  Future<void> restore() {
    final existingRestore = _restoreOperation;
    if (existingRestore != null) return existingRestore;

    final operation = _restore();
    _restoreOperation = operation;
    return operation.whenComplete(() {
      if (identical(_restoreOperation, operation)) _restoreOperation = null;
    });
  }

  Future<void> _restore() async {
    final accountId = _requireAccountId();
    _ensureListening();
    final session = _RestoreSession(accountId);
    _restoreSession = session;
    _setError(null);
    _setPhase(ApplePurchasePhase.restoring);

    Set<String>? expectedTransactionIds;
    Object? storeError;
    StackTrace? storeStackTrace;
    try {
      _ensureSameAccount(accountId);
      expectedTransactionIds = await _activeStore.restorePurchases(
        applicationUserName: accountId,
      );
    } catch (error, stackTrace) {
      storeError = error;
      storeStackTrace = stackTrace;
    }

    bool verified;
    try {
      verified = await session.waitForVerification(
        expectedTransactionIds: expectedTransactionIds,
        deliveryTimeout: restoreDeliveryTimeout,
      );
    } catch (error) {
      if (identical(_restoreSession, session)) _restoreSession = null;
      _setError(error);
      _setPhase(ApplePurchasePhase.failed);
      rethrow;
    }
    if (identical(_restoreSession, session)) _restoreSession = null;

    if ((storeError != null && _isCancellation(storeError)) ||
        session.canceled) {
      _setError(null);
      _setPhase(ApplePurchasePhase.canceled);
      return;
    }
    if (storeError != null) {
      _setError(storeError);
      _setPhase(ApplePurchasePhase.failed);
      Error.throwWithStackTrace(storeError, storeStackTrace!);
    }
    final streamError = session.error;
    if (streamError != null) {
      _setError(streamError);
      _setPhase(ApplePurchasePhase.failed);
      throw MemberAccountException(_error ?? '恢复购买失败');
    }
    if (!verified) {
      _setPhase(ApplePurchasePhase.failed);
      throw MemberAccountException(_error ?? '恢复购买验证失败');
    }

    _setError(null);
    if (session.sawPurchase) {
      _setPhase(
        session.sawFormalPurchase
            ? ApplePurchasePhase.restored
            : session.sawTestPurchase
            ? ApplePurchasePhase.testVerified
            : session.sawRevokedPurchase
            ? ApplePurchasePhase.revoked
            : ApplePurchasePhase.failed,
      );
    } else if (expectedTransactionIds == null) {
      _setPhase(ApplePurchasePhase.idle);
    } else {
      _setPhase(ApplePurchasePhase.nothingToRestore);
    }
  }

  void _handlePurchases(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      if (purchase.productID != productId) continue;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _setError(null);
          _setPhase(ApplePurchasePhase.pending);
        case PurchaseStatus.canceled:
          _purchaseAccountId = null;
          _restoreSession?.markCanceled();
          _setError(null);
          _setPhase(ApplePurchasePhase.canceled);
        case PurchaseStatus.error:
          _purchaseAccountId = null;
          final error = purchase.error?.message ?? 'App Store 购买未完成';
          _restoreSession?.markError(error);
          _setError(error);
          _setPhase(ApplePurchasePhase.failed);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          if (_purchaseAccountId case final purchaseAccountId?
              when accountIdProvider() != purchaseAccountId) {
            _purchaseAccountId = null;
          }
          final accountId =
              _restoreSession?.accountId ??
              _purchaseAccountId ??
              accountIdProvider();
          final transaction = _processTransaction(purchase, accountId);
          if (_restoreSession != null) {
            _restoreSession?.track(
              transactionId: purchase.purchaseID,
              transaction: transaction,
            );
          }
          unawaited(transaction);
      }
    }
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    if (_isCancellation(error)) {
      _restoreSession?.markCanceled();
      _setError(null);
      _setPhase(ApplePurchasePhase.canceled);
      return;
    }
    _restoreSession?.markError(error);
    _setError(error);
    _setPhase(ApplePurchasePhase.failed);
  }

  Future<bool> _processTransaction(
    PurchaseDetails purchase,
    String? accountId,
  ) {
    final key = _transactionKey(purchase);
    final existing = _transactionsInFlight[key];
    if (existing != null) return existing;

    late final Future<bool> transaction;
    transaction = _verifyAndComplete(purchase, accountId).whenComplete(() {
      if (identical(_transactionsInFlight[key], transaction)) {
        _transactionsInFlight.remove(key);
      }
    });
    _transactionsInFlight[key] = transaction;
    return transaction;
  }

  Future<bool> _verifyAndComplete(
    PurchaseDetails purchase,
    String? accountId,
  ) async {
    if (_verificationCount == 0) {
      _verificationBatchFailed = false;
    }
    _verificationCount++;
    _verificationSuccessPhase = purchase.status == PurchaseStatus.restored
        ? ApplePurchasePhase.restored
        : ApplePurchasePhase.purchased;
    _setPhase(ApplePurchasePhase.verifying);

    var succeeded = false;
    try {
      if (accountId == null) {
        throw const MemberAccountException('请先登录账号');
      }
      _ensureSameAccount(accountId);
      final membership = await _verify(purchase);
      _ensureSameAccount(accountId);
      final revoked = membership.purchaseStatus == 'revoked';
      if (!revoked && !membership.premium && !membership.testPurchase) {
        throw const MemberAccountException('App Store 购买尚未解锁高级会员，请重试');
      }
      if (purchase.pendingCompletePurchase) {
        await _activeStore.completePurchase(purchase);
      }
      _ensureSameAccount(accountId);
      if (_purchaseAccountId == accountId) {
        _purchaseAccountId = null;
      }
      if (!_disposed) onMembership?.call(membership);
      if (revoked) {
        _verificationSuccessPhase = ApplePurchasePhase.revoked;
      } else if (membership.testPurchase) {
        _verificationSuccessPhase = ApplePurchasePhase.testVerified;
      }
      _restoreSession?.markVerified(
        testPurchase: membership.testPurchase,
        revoked: revoked,
      );
      succeeded = true;
      return true;
    } catch (error) {
      // Keep the transaction unfinished so a later stream delivery can retry
      // authoritative server verification and StoreKit completion.
      _verificationBatchFailed = true;
      _setError(error);
      return false;
    } finally {
      _verificationCount--;
      if (_verificationCount == 0) {
        if (_verificationBatchFailed || !succeeded) {
          _setPhase(ApplePurchasePhase.failed);
        } else {
          _setError(null);
          if (_restoreSession == null) {
            _setPhase(_verificationSuccessPhase);
          }
        }
      }
    }
  }

  String _transactionKey(PurchaseDetails purchase) {
    final purchaseId = purchase.purchaseID;
    if (purchaseId != null && purchaseId.isNotEmpty) {
      return '${purchase.productID}:$purchaseId';
    }
    return '${purchase.productID}:${purchase.transactionDate ?? ''}:'
        '${purchase.verificationData.serverVerificationData}';
  }

  bool _isCancellation(Object error) {
    return error is PlatformException && error.code == 'purchase_cancelled';
  }

  String _requireAccountId() {
    final accountId = accountIdProvider();
    if (accountId == null || accountId.isEmpty) {
      throw const MemberAccountException('请先登录账号');
    }
    if (!_uuidPattern.hasMatch(accountId)) {
      throw const MemberAccountException('账号标识无效，请重新登录');
    }
    return accountId;
  }

  void _ensureSameAccount(String expectedAccountId) {
    if (accountIdProvider() != expectedAccountId) {
      throw const MemberAccountException('账号已切换，请重新验证购买');
    }
  }

  void _setPhase(ApplePurchasePhase value) {
    if (_disposed || _phase == value) return;
    _phase = value;
    notifyListeners();
  }

  void _setError(Object? error) {
    if (_disposed) return;
    final message = error == null
        ? null
        : error is MemberAccountException
        ? error.message
        : error is PlatformException
        ? (error.message?.trim().isNotEmpty == true
              ? error.message!.trim()
              : 'App Store 操作暂未完成，请重试')
        : error.toString();
    if (_error == message) return;
    _error = message;
    notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

class _RestoreSession {
  _RestoreSession(this.accountId);

  final String accountId;
  final Map<String, Future<bool>> _transactionsById = {};
  final Set<Future<bool>> _transactionsWithoutId = {};
  final Map<String, Completer<void>> _arrivals = {};
  bool _canceled = false;
  bool _sawFormalPurchase = false;
  bool _sawTestPurchase = false;
  bool _sawRevokedPurchase = false;
  Object? _error;

  bool get sawPurchase =>
      _transactionsById.isNotEmpty || _transactionsWithoutId.isNotEmpty;
  bool get canceled => _canceled;
  bool get sawFormalPurchase => _sawFormalPurchase;
  bool get sawTestPurchase => _sawTestPurchase;
  bool get sawRevokedPurchase => _sawRevokedPurchase;
  Object? get error => _error;

  void track({
    required String? transactionId,
    required Future<bool> transaction,
  }) {
    if (transactionId == null || transactionId.isEmpty) {
      _transactionsWithoutId.add(transaction);
      return;
    }
    _transactionsById.putIfAbsent(transactionId, () => transaction);
    final arrival = _arrivals[transactionId];
    if (arrival != null && !arrival.isCompleted) arrival.complete();
  }

  void markCanceled() {
    _canceled = true;
    _completePendingArrivals();
  }

  void markError(Object error) {
    _error = error;
    _completePendingArrivals();
  }

  void markVerified({required bool testPurchase, required bool revoked}) {
    if (revoked) {
      _sawRevokedPurchase = true;
    } else if (testPurchase) {
      _sawTestPurchase = true;
    } else {
      _sawFormalPurchase = true;
    }
  }

  Future<bool> waitForVerification({
    required Set<String>? expectedTransactionIds,
    required Duration deliveryTimeout,
  }) async {
    final expectedIds = expectedTransactionIds;
    if (expectedIds != null && !_canceled && _error == null) {
      final missingIds = expectedIds.difference(_transactionsById.keys.toSet());
      if (missingIds.isNotEmpty) {
        final arrivals = missingIds
            .map((id) => _arrivals.putIfAbsent(id, Completer<void>.new).future)
            .toList();
        try {
          await Future.wait(arrivals).timeout(deliveryTimeout);
        } on TimeoutException {
          final stillMissing = expectedIds.difference(
            _transactionsById.keys.toSet(),
          );
          throw MemberAccountException(
            'App Store 恢复结果接收超时，请重试'
            '${stillMissing.isEmpty ? '' : '（缺少 ${stillMissing.length} 笔交易）'}',
          );
        }
      }
    }

    if (_canceled || _error != null) return true;
    final transactions = <Future<bool>>{
      ..._transactionsWithoutId,
      ..._transactionsById.values,
    };
    final results = await Future.wait(transactions);
    return results.every((result) => result);
  }

  void _completePendingArrivals() {
    for (final arrival in _arrivals.values) {
      if (!arrival.isCompleted) arrival.complete();
    }
  }
}
