import Flutter
import UIKit
import PDFKit

/// Show PDF (#115): the project's screenplay in PDFKit as a Flutter platform view, with page / continuous reading (#120).
/// Apple Pencil markup (#119) is drawn by Flutter over the page (lib/phone/ink_layer.dart); this view only has to show one
/// page, fitted to the screen, and say where on screen that page is (`geometry`). Channel and view names must match
/// lib/phone/pdf_view.dart.
///
/// `tableread/pdf`            pageTexts(path) -> [String]   (the text of every page, to line the script up with its pages)
/// `tableread/pdfview`        the platform view; creation args: path, dark
/// `tableread/pdfview_<id>`   per view. Dart -> native: state, goToPage, setMode, search, searchStep, clearSearch, lockFit.
///                            Native -> Dart: page, geometry.
final class PdfPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tableread/pdf", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PdfPlugin(), channel: channel)
    registrar.register(PdfViewFactory(messenger: registrar.messenger()), withId: "tableread/pdfview")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pageTexts":
      let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        let texts: [String]? = PDFDocument(url: URL(fileURLWithPath: path)).map { doc in
          (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        }
        DispatchQueue.main.async {
          if let texts = texts {
            result(texts)
          } else {
            result(FlutterError(code: "pdf", message: "Couldn't open the PDF", details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class PdfViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    PdfPlatformView(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
  }
}

/// Holds the PDFView and says when it has been laid out (rotation, a new size), so the page's place can be reported again.
private final class PdfHost: UIView {
  let pdfView = PDFView()
  var onLayout: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(pdfView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    pdfView.frame = bounds
    onLayout?()
  }
}

final class PdfPlatformView: NSObject, FlutterPlatformView {
  private let host = PdfHost()
  private var pdfView: PDFView { host.pdfView }
  private let channel: FlutterMethodChannel
  private let created = Date()

  private var continuous = true
  private var fitLocked = false
  private var results: [PDFSelection] = []
  private var resultIndex = 0

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "tableread/pdfview_\(viewId)", binaryMessenger: messenger)
    super.init()
    host.frame = frame
    if let path = args["path"] as? String { pdfView.document = PDFDocument(url: URL(fileURLWithPath: path)) }
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.pageBreakMargins = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    pdfView.backgroundColor = (args["dark"] as? Bool ?? false) ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.9, alpha: 1)
    NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
    NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
    host.onLayout = { [weak self] in self?.laidOut() }
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  func view() -> UIView { host }

  private var pageIndex: Int {
    guard let doc = pdfView.document, let p = pdfView.currentPage else { return 0 }
    return doc.index(for: p)
  }

  @objc private func pageChanged() {
    channel.invokeMethod("page", arguments: ["page": pageIndex + 1, "count": pdfView.document?.pageCount ?? 0])
    sendGeometry()
  }

  @objc private func scaleChanged() { sendGeometry() }

  private func laidOut() {
    if fitLocked { applyFit() }
    sendGeometry()
  }

  /// Where the current page is in this view (points, top left origin) and how big it is on paper, for Flutter's ink layer.
  private func sendGeometry() {
    guard let page = pdfView.currentPage else { return }
    let box = page.bounds(for: .cropBox)
    let r = pdfView.convert(box, from: page)
    channel.invokeMethod(
      "geometry",
      arguments: ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height, "pageW": box.width, "pageH": box.height]
    )
  }

  /// While marking up the whole page stays in view at one size: the ink is drawn over it.
  private func applyFit() {
    pdfView.autoScales = true
    let fit = pdfView.scaleFactorForSizeToFit
    if fit > 0 {
      pdfView.minScaleFactor = fit
      pdfView.maxScaleFactor = fit
      pdfView.scaleFactor = fit
    }
  }

  private func go(toPage n: Int) {
    guard let doc = pdfView.document, n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { return }
    pdfView.go(to: page)
    // A view that has only just been created has no size yet, and PDFView puts itself back on page 1 as it lays out:
    // during its first seconds, say it again a few times.
    if Date().timeIntervalSince(created) < 3 {
      for delay in [0.15, 0.5, 1.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          if let self = self, self.pdfView.currentPage != page { self.pdfView.go(to: page) }
        }
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "state":
      result(["page": pageIndex + 1, "count": pdfView.document?.pageCount ?? 0])
      sendGeometry()
    case "goToPage":
      go(toPage: args["page"] as? Int ?? 1)
      result(nil)
    case "setMode":
      setContinuous(args["continuous"] as? Bool ?? true)
      result(nil)
    case "lockFit":
      fitLocked = args["on"] as? Bool ?? false
      if fitLocked {
        applyFit()
      } else {
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5
        pdfView.autoScales = true
      }
      sendGeometry()
      result(nil)
    case "search":
      result(search(args["query"] as? String ?? "", reveal: args["reveal"] as? Bool ?? true))
    case "searchStep":
      result(stepSearch(forward: args["forward"] as? Bool ?? true))
    case "clearSearch":
      results = []
      pdfView.highlightedSelections = nil
      pdfView.clearSelection()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Reading

  /// One page at a time (Flutter turns the pages: swipes and buttons) or one continuous scroll; the page being read stays.
  private func setContinuous(_ on: Bool) {
    guard on != continuous else { return }
    continuous = on
    let here = pdfView.currentPage
    pdfView.displayMode = on ? .singlePageContinuous : .singlePage
    pdfView.autoScales = true
    if let here = here { pdfView.go(to: here) }
    if fitLocked { applyFit() }
    sendGeometry()
  }

  private func search(_ query: String, reveal: Bool) -> [String: Any] {
    results = []
    resultIndex = 0
    pdfView.highlightedSelections = nil
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty, let doc = pdfView.document else { return ["count": 0, "index": 0] }
    results = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
    for r in results { r.color = UIColor.systemYellow.withAlphaComponent(0.55) }
    pdfView.highlightedSelections = results
    if reveal { showResult() }
    return ["count": results.count, "index": results.isEmpty ? 0 : 1]
  }

  private func stepSearch(forward: Bool) -> [String: Any] {
    guard !results.isEmpty else { return ["count": 0, "index": 0] }
    resultIndex = (resultIndex + (forward ? 1 : results.count - 1)) % results.count
    showResult()
    return ["count": results.count, "index": resultIndex + 1]
  }

  private func showResult() {
    guard resultIndex < results.count else { return }
    let r = results[resultIndex]
    pdfView.setCurrentSelection(r, animate: true)
    pdfView.go(to: r)
  }
}
