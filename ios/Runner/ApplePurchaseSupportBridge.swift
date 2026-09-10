import Flutter
import StoreKit
import UIKit

final class ApplePurchaseSupportBridge {
  private static let channelName = "com.niki.xxread/apple_purchase_support"
  private static let premiumProductID = "com.niki.xxread.premium.lifetime"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "bridge_unavailable",
            message: "Apple purchase support is unavailable",
            details: nil
          )
        )
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "syncPurchases":
      Task { @MainActor in
        do {
          try await AppStore.sync()
          result(try await self.currentPremiumTransactionIDs())
        } catch StoreKitError.userCancelled {
          result(
            FlutterError(
              code: "purchase_cancelled",
              message: "App Store purchase restoration was cancelled",
              details: nil
            )
          )
        } catch {
          result(
            FlutterError(
              code: "purchase_sync_failed",
              message: error.localizedDescription,
              details: String(reflecting: error)
            )
          )
        }
      }
    case "requestRefund":
      guard let arguments = call.arguments as? [String: Any],
            let productID = arguments["productId"] as? String,
            !productID.isEmpty else {
        result(
          FlutterError(
            code: "invalid_args",
            message: "productId is required",
            details: nil
          )
        )
        return
      }
      Task { @MainActor in
        await self.requestRefund(productID: productID, result: result)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func currentPremiumTransactionIDs() async throws -> [String] {
    var transactionIDs: [String] = []
    for await entitlement in Transaction.currentEntitlements {
      switch entitlement {
      case .verified(let transaction) where transaction.productID == Self.premiumProductID:
        transactionIDs.append(String(transaction.id))
      case .unverified(let transaction, let verificationError)
        where transaction.productID == Self.premiumProductID:
        throw ApplePurchaseSupportError.unverifiedTransaction(verificationError)
      default:
        continue
      }
    }
    return transactionIDs
  }

  @MainActor
  private func requestRefund(productID: String, result: @escaping FlutterResult) async {
    guard productID == Self.premiumProductID else {
      result("notFound")
      return
    }
    guard let scene = Self.activeWindowScene() else {
      result("unavailable")
      return
    }

    do {
      for await entitlement in Transaction.currentEntitlements {
        switch entitlement {
        case .verified(let transaction) where transaction.productID == Self.premiumProductID:
          let status = try await transaction.beginRefundRequest(in: scene)
          switch status {
          case .success:
            result("submitted")
          case .userCancelled:
            result("cancelled")
          @unknown default:
            result("unavailable")
          }
          return
        case .unverified(let transaction, let verificationError)
          where transaction.productID == Self.premiumProductID:
          throw ApplePurchaseSupportError.unverifiedTransaction(verificationError)
        default:
          continue
        }
      }
      result("notFound")
    } catch {
      result(
        FlutterError(
          code: "refund_request_failed",
          message: error.localizedDescription,
          details: String(reflecting: error)
        )
      )
    }
  }

  @MainActor
  private static func activeWindowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { scene in
        scene.activationState == .foregroundActive
          && scene.windows.contains(where: { $0.isKeyWindow })
      }
  }
}

private enum ApplePurchaseSupportError: LocalizedError {
  case unverifiedTransaction(Error)

  var errorDescription: String? {
    switch self {
    case .unverifiedTransaction:
      return "The App Store transaction could not be verified"
    }
  }
}
