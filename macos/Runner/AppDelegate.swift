import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let trayImage = NSImage(
      systemSymbolName: "arrow.down.circle.fill",
      accessibilityDescription: "Internet Download Manager"
    ) ?? NSApp.applicationIconImage
    item.button?.image = trayImage
    item.button?.image?.isTemplate = true
    item.button?.imagePosition = .imageOnly
    item.button?.toolTip = "Internet Download Manager"

    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: "Buka Internet Download Manager",
        action: #selector(showMainWindow),
        keyEquivalent: ""
      )
    )
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Keluar", action: #selector(terminateApp), keyEquivalent: "q"))
    for menuItem in menu.items {
      menuItem.target = self
    }
    item.menu = menu
    statusItem = item
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows: Bool
  ) -> Bool {
    showMainWindow()
    return true
  }

  @objc private func showMainWindow() {
    if let window = NSApp.windows.first {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }

  @objc private func terminateApp() {
    NSApp.terminate(nil)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
