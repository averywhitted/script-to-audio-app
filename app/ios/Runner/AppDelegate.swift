import Flutter
import UIKit
import MediaPlayer
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NowPlayingPlugin") {
      NowPlayingPlugin.register(with: registrar)
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
  private var pendingPdf: FlutterResult?
  private var pdfPicker: UIDocumentPickerViewController?
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
    case "pickPdf":
      pickPdf(result)
    case "copyIn":
      let from = args["from"] as? String ?? ""
      let to = args["to"] as? String ?? ""
      background(result) { try self.copyIn(URL(fileURLWithPath: from), URL(fileURLWithPath: to)) }
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

  /// Choose a screenplay PDF in Files. The picker hands back a copy inside the app's own temporary folder, so no
  /// security scope is needed; Dart parses it from there.
  private func pickPdf(_ result: @escaping FlutterResult) {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
    picker.delegate = self
    pendingPdf = result
    pdfPicker = picker
    topViewController()?.present(picker, animated: true)
  }

  private func finishPdf(_ value: Any?) {
    pendingPdf?(value)
    pendingPdf = nil
    pdfPicker = nil
  }

  /// Copies a local file into the projects folder (coordinated, so iCloud picks it up cleanly).
  private func copyIn(_ from: URL, _ to: URL) throws -> Bool {
    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try Data(contentsOf: from)
    var coordError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: to, options: .forReplacing, error: &coordError) { u in
      do { try data.write(to: u, options: .atomic) } catch { writeError = error }
    }
    if let e = coordError ?? writeError { throw e }
    return true
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    if controller === pdfPicker { return finishPdf(urls.first?.path) }
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

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if controller === pdfPicker { finishPdf(nil) } else { finishPick(nil) }
  }

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

/// Lock screen, Control Center and headphone controls (#92). The Dart side
/// (lib/phone/now_playing.dart) sends what's playing ("update"/"clear") and
/// gets the buttons back as "command" calls: play, pause, toggle (an AirPods
/// press), next / previous (double / triple press), seek.
class NowPlayingPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tableread/nowplaying", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NowPlayingPlugin(channel: channel), channel: channel)
  }

  private let channel: FlutterMethodChannel
  private var targets: [(MPRemoteCommand, Any)] = []
  private lazy var artwork: MPMediaItemArtwork? = {
    let key = FlutterDartProject.lookupKey(forAsset: "assets/app_icon.png")
    guard let path = Bundle.main.path(forResource: key, ofType: nil), let image = UIImage(contentsOfFile: path) else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }()

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "update":
      enableCommands()
      let rate = args["rate"] as? Double ?? 1
      let playing = args["playing"] as? Bool ?? false
      var info: [String: Any] = [
        MPMediaItemPropertyTitle: args["title"] as? String ?? "",
        MPMediaItemPropertyArtist: args["artist"] as? String ?? "",
        MPMediaItemPropertyAlbumTitle: args["album"] as? String ?? "",
        MPMediaItemPropertyPlaybackDuration: args["duration"] as? Double ?? 0,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: args["position"] as? Double ?? 0,
        MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0.0,
        MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      ]
      if let art = artwork { info[MPMediaItemPropertyArtwork] = art }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      result(nil)
    case "clear":
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      for (command, target) in targets {
        command.removeTarget(target)
        command.isEnabled = false
      }
      targets = []
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func enableCommands() {
    guard targets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    func add(_ command: MPRemoteCommand, _ name: String) {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        self?.channel.invokeMethod("command", arguments: ["name": name])
        return .success
      }
      targets.append((command, target))
    }
    add(center.playCommand, "play")
    add(center.pauseCommand, "pause")
    add(center.togglePlayPauseCommand, "toggle")
    add(center.nextTrackCommand, "next")
    add(center.previousTrackCommand, "previous")
    let seek = center.changePlaybackPositionCommand
    seek.isEnabled = true
    let target = seek.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self?.channel.invokeMethod("command", arguments: ["name": "seek", "position": e.positionTime])
      return .success
    }
    targets.append((seek, target))
  }
}
