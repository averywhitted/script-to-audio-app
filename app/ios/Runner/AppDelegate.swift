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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ProjectsFolderPlugin") {
      ProjectsFolderPlugin.register(with: registrar)
    }
  }
}

/// The projects folder the user picked in Files (normally iCloud Drive › Table
/// Read). Channel and method names must match lib/phone/folder_access.dart.
/// Access is kept for the whole session once resolved, so Dart reads the
/// files directly; files iCloud hasn't brought to the phone yet are fetched
/// with coordinated reads first ("download").
class ProjectsFolderPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tableread/folder", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ProjectsFolderPlugin(), channel: channel)
  }

  private let bookmarkKey = "projectsFolderBookmark"
  private var pendingPick: FlutterResult?
  private var accessed: URL?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pick":
      pick(result)
    case "folder":
      result(open()?.path)
    case "forget":
      accessed?.stopAccessingSecurityScopedResource()
      accessed = nil
      UserDefaults.standard.removeObject(forKey: bookmarkKey)
      result(nil)
    case "list":
      let path = args["path"] as? String ?? ""
      background(result) { try self.list(URL(fileURLWithPath: path)) }
    case "download":
      let paths = args["paths"] as? [String] ?? []
      background(result) { try self.download(paths.map { URL(fileURLWithPath: $0) }) }
    case "write":
      let path = args["path"] as? String ?? ""
      let text = args["text"] as? String ?? ""
      background(result) { try self.write(URL(fileURLWithPath: path), text) }
    case "delete":
      let path = args["path"] as? String ?? ""
      background(result) { try self.delete(URL(fileURLWithPath: path)) }
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
      accessed?.stopAccessingSecurityScopedResource()
      accessed = nil
      finishPick(open()?.path)
    } catch {
      finishPick(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishPick(nil) }

  private func finishPick(_ value: Any?) {
    pendingPick?(value)
    pendingPick = nil
  }

  /// The remembered folder, with access started (kept until "forget").
  private func open() -> URL? {
    if let url = accessed { return url }
    #if targetEnvironment(simulator)
    // Simulator testing without the picker: until a folder is picked, the
    // app's own Documents/Table Read (On My iPhone › Table Read), if present.
    if UserDefaults.standard.data(forKey: bookmarkKey) == nil,
       let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      let own = docs.appendingPathComponent("Table Read")
      if FileManager.default.fileExists(atPath: own.path) { return own }
    }
    #endif
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
    guard url.startAccessingSecurityScopedResource() else { return nil }
    if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(fresh, forKey: bookmarkKey)
    }
    accessed = url
    return url
  }

  private func background(_ result: @escaping FlutterResult, _ body: @escaping () throws -> Any?) {
    guard open() != nil else {
      return result(FlutterError(code: "nofolder", message: "No projects folder picked yet", details: nil))
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let value: Any?
      do { value = try body() } catch { value = FlutterError(code: "io", message: error.localizedDescription, details: nil) }
      DispatchQueue.main.async { result(value) }
    }
  }

  // MARK: Files

  /// Entries of a folder. iCloud may show a file that isn't on the phone yet
  /// as a ".Name.icloud" placeholder: reported under its real name.
  private func list(_ folder: URL) throws -> [[String: Any]] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .ubiquitousItemDownloadingStatusKey]
    let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
    return items.compactMap { u in
      var name = u.lastPathComponent
      var downloaded = true
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        name = String(name.dropFirst().dropLast(".icloud".count))
        downloaded = false
      } else if name.hasPrefix(".") {
        return nil
      }
      let v = try? u.resourceValues(forKeys: Set(keys))
      if let s = v?.ubiquitousItemDownloadingStatus, s != .current { downloaded = false }
      return ["name": name, "dir": v?.isDirectory ?? false, "downloaded": downloaded]
    }
  }

  /// Brings each file onto the phone (coordinated reads wait for iCloud).
  private func download(_ urls: [URL]) throws -> Int {
    var done = 0
    for url in urls {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      var coordError: NSError?
      var readError: Error?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
        do { _ = try Data(contentsOf: u, options: .mappedIfSafe) } catch { readError = error }
      }
      if let e = coordError ?? readError { throw e }
      done += 1
    }
    return done
  }

  private func write(_ url: URL, _ text: String) throws -> Bool {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var coordError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
      do { try Data(text.utf8).write(to: u, options: .atomic) } catch { writeError = error }
    }
    if let e = coordError ?? writeError { throw e }
    return true
  }

  private func delete(_ url: URL) throws -> Bool {
    var coordError: NSError?
    var deleteError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { u in
      do {
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
      } catch { deleteError = error }
    }
    if let e = coordError ?? deleteError { throw e }
    return true
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var vc = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
