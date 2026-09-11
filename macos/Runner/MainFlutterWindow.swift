import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appDistributionBridge: AppDistributionBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    appDistributionBridge = AppDistributionBridge(
      messenger: flutterViewController.engine.binaryMessenger
    )
    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
