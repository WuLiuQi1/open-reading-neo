import XCTest

class RunnerTests: XCTestCase {
  func testMacAppStoreReceiptRequiresAnExistingReceiptFile() {
    let receiptURL = URL(
      fileURLWithPath: "/Applications/OpenReading.app/Contents/_MASReceipt/receipt"
    )
    XCTAssertTrue(macAppStoreReceiptExists(receiptURL: receiptURL) { $0 == receiptURL.path })
    XCTAssertFalse(macAppStoreReceiptExists(receiptURL: receiptURL) { _ in false })
    XCTAssertFalse(macAppStoreReceiptExists(receiptURL: nil) { _ in true })
  }
}

/// Keep this aligned with `MacAppStoreReceipt.exists` in AppDistributionBridge.swift.
private func macAppStoreReceiptExists(
  receiptURL: URL?,
  fileExists: (String) -> Bool
) -> Bool {
  guard let receiptURL else { return false }
  return fileExists(receiptURL.path)
}
