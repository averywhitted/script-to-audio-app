import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Content runs under a transparent title bar so the app's own top bar sits
    // beside the traffic lights, as in the design.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = false
    self.title = "Table Read"
    self.minSize = NSSize(width: 1040, height: 680)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1320, screen.width - 80), height: min(860, screen.height - 60))
    self.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                         width: size.width, height: size.height), display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    PlatformChannel.register(with: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// Small native helpers the Dart side can't do on its own: Trash, Keychain, Finder.
/// Channel name and method names must match lib/services/platform.dart.
enum PlatformChannel {
  static func register(with messenger: FlutterBinaryMessenger, window: NSWindow) {
    let channel = FlutterMethodChannel(name: "tableread/platform", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "trashItem":
        guard let path = args["path"] as? String else { return result(nil) }
        var resulting: NSURL?
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
          result(resulting?.path)
        } catch {
          result(FlutterError(code: "trash", message: error.localizedDescription, details: nil))
        }
      case "startWindowDrag":
        // The Flutter view covers the title bar, so the app's top bar asks to drag.
        if let event = NSApp.currentEvent { window.performDrag(with: event) }
        result(nil)
      case "zoomWindow":
        window.zoom(nil)
        result(nil)
      case "revealInFinder":
        if let path = args["path"] as? String {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        result(nil)
      case "openPath":
        if let path = args["path"] as? String {
          NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        result(nil)
      case "openURL":
        if let s = args["url"] as? String, let url = URL(string: s) {
          NSWorkspace.shared.open(url)
          result(true)
        } else {
          result(false)
        }
      case "keychainRead":
        result(Keychain.read(account: args["account"] as? String ?? ""))
      case "keychainWrite":
        Keychain.write(account: args["account"] as? String ?? "", value: args["value"] as? String ?? "")
        result(nil)
      case "keychainDelete":
        Keychain.delete(account: args["account"] as? String ?? "")
        result(nil)
      case "appVersion":
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        result(["version": v, "build": b, "os": ProcessInfo.processInfo.operatingSystemVersionString])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Same service name as the Swift app ("com.tableread"), so an existing OpenAI key is found.
enum Keychain {
  static let service = "com.tableread"

  static func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func write(account: String, value: String) {
    delete(account: account)
    guard let data = value.data(using: .utf8) else { return }
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      kSecValueData as String: data,
    ]
    SecItemAdd(add as CFDictionary, nil)
  }

  static func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
