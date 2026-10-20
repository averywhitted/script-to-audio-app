import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FolderAccessPlugin") {
      FolderAccessPlugin.register(with: registrar)
    }
  }
}

// Spike for issue #88: can a free-account app keep access to a folder picked
// in Files (iCloud Drive), read what the Mac wrote and write back?


class FolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tableread/folder", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(FolderAccessPlugin(), channel: channel)
  }

  private let bookmarkKey = "folderBookmark"
  private var pendingPick: FlutterResult?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pick":
      pick(result)
    case "status":
      guard let (url, stale) = resolve() else { return result(nil) }
      result(["path": url.path, "stale": stale])
    case "list":
      withFolder(result) { try self.list($0) }
    case "read":
      let name = args["name"] as? String ?? ""
      withFolder(result) { try self.read($0.appendingPathComponent(name)) }
    case "write":
      let name = args["name"] as? String ?? ""
      let text = args["text"] as? String ?? ""
      withFolder(result) { try self.write($0.appendingPathComponent(name), text) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Picking and remembering the folder

  private func pick(_ result: @escaping FlutterResult) {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    pendingPick = result
    topViewController()?.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return finishPick(nil) }
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(data, forKey: bookmarkKey)
      finishPick(["path": url.path, "scoped": ok])
    } catch {
      finishPick(FlutterError(code: "bookmark", message: "\(error)", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishPick(nil) }

  private func finishPick(_ value: Any?) {
    pendingPick?(value)
    pendingPick = nil
  }

  private func resolve() -> (URL, Bool)? {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
    if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(fresh, forKey: bookmarkKey)
    }
    return (url, stale)
  }

  /// Runs `body` with security-scoped access to the remembered folder.
  private func withFolder(_ result: @escaping FlutterResult, _ body: @escaping (URL) throws -> Any?) {
    guard let (url, _) = resolve() else {
      return result(FlutterError(code: "nofolder", message: "No folder picked yet", details: nil))
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let ok = url.startAccessingSecurityScopedResource()
      defer { if ok { url.stopAccessingSecurityScopedResource() } }
      let value: Any?
      do { value = try body(url) } catch { value = FlutterError(code: "io", message: "\(error)", details: nil) }
      DispatchQueue.main.async { result(value) }
    }
  }

  // MARK: File operations

  private func list(_ folder: URL) throws -> [[String: Any]] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
    let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
    return items.map { u in
      let v = try? u.resourceValues(forKeys: Set(keys))
      return [
        "name": u.lastPathComponent,
        "dir": v?.isDirectory ?? false,
        "size": v?.fileSize ?? -1,
        "download": v?.ubiquitousItemDownloadingStatus?.rawValue ?? "local",
      ]
    }
  }

  /// Coordinated read: asks iCloud to fetch the file first if it isn't on the phone yet.
  private func read(_ url: URL) throws -> [String: Any] {
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    var coordError: NSError?
    var out: [String: Any] = [:]
    var readError: Error?
    let started = Date()
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
      do {
        let data = try Data(contentsOf: u)
        out = ["bytes": data.count, "text": String(decoding: data.prefix(400), as: UTF8.self)]
      } catch { readError = error }
    }
    if let e = coordError ?? readError { throw e }
    out["seconds"] = Date().timeIntervalSince(started)
    return out
  }

  private func write(_ url: URL, _ text: String) throws -> Bool {
    var coordError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
      do { try Data(text.utf8).write(to: u, options: .atomic) } catch { writeError = error }
    }
    if let e = coordError ?? writeError { throw e }
    return true
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var vc = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
