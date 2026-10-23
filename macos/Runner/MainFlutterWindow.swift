import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func performClose(_ sender: Any?) {
    orderOut(sender)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    DownloadDirectoryBookmarks.shared.register(
      with: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

private final class DownloadDirectoryBookmarks {
  static let shared = DownloadDirectoryBookmarks()

  private let bookmarkKey = "downloadDirectorySecurityBookmark"
  private var activeDirectory: URL?

  func register(with messenger: FlutterBinaryMessenger) {
    restoreAccess()
    let channel = FlutterMethodChannel(
      name: "internet_download_manager/download_directory",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "pickDirectory":
        self.pickDirectory(result: result)
      case "clearAccess":
        self.clearAccess()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickDirectory(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "Choose download folder"
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else {
      result(nil)
      return
    }

    do {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
      replaceActiveDirectory(with: url)
      result(url.path)
    } catch {
      result(
        FlutterError(
          code: "BOOKMARK_FAILED",
          message: "Could not remember access to the selected folder.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func restoreAccess() {
    guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
      return
    }
    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      replaceActiveDirectory(with: url)
      if isStale {
        let refreshedBookmark = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
      }
    } catch {
      NSLog("Could not restore download folder access: %@", error.localizedDescription)
    }
  }

  private func clearAccess() {
    UserDefaults.standard.removeObject(forKey: bookmarkKey)
    if let activeDirectory {
      activeDirectory.stopAccessingSecurityScopedResource()
    }
    activeDirectory = nil
  }

  private func replaceActiveDirectory(with url: URL) {
    if let activeDirectory {
      activeDirectory.stopAccessingSecurityScopedResource()
    }
    _ = url.startAccessingSecurityScopedResource()
    activeDirectory = url
  }
}
