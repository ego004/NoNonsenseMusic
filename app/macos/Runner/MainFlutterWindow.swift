import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // the Mac app's default window (Flutter's template opened 800 × 600), never smaller than the layout needs
    self.setContentSize(NSSize(width: 1180, height: 760))
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
