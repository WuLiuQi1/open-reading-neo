import Cocoa
import FlutterMacOS

enum MacAppStoreReceipt {
  static func exists(
    receiptURL: URL? = Bundle.main.appStoreReceiptURL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> Bool {
    guard let receiptURL else { return false }
    return fileExists(receiptURL.path)
  }
}

final class AppDistributionBridge {
  private static let channelName = "com.niki.xxread/app_distribution"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isMacAppStore":
        result(MacAppStoreReceipt.exists())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
