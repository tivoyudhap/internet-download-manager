import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    let item = NSStatusBar.system.statusItem(withLength: 54)
    let trayImage = NSImage(
      systemSymbolName: "arrow.down.circle.fill",
      accessibilityDescription: "Internet Download Manager"
    ) ?? NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 16, height: 16))
    trayImage.size = NSSize(width: 16, height: 16)
    trayImage.isTemplate = true
    if let button = item.button {
      button.image = trayImage
      button.imageScaling = .scaleProportionallyDown
      button.attributedTitle = NSAttributedString(
        string: " IDM",
        attributes: [
          .foregroundColor: NSColor.labelColor,
          .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ]
      )
      button.imagePosition = .imageLeading
      button.toolTip = "Internet Download Manager"
    }
    item.isVisible = true

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
