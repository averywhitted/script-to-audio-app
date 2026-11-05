import Flutter
import UIKit
import PDFKit
import PencilKit

/// Show PDF (#115) and Apple Pencil markup (#119).
///
/// Reading is a PDFKit view as a Flutter platform view (search, page / continuous reading #120). Marking up is not done
/// inside Flutter at all: `presentMarkup` opens a native full-screen PDFView with a PencilKit canvas on every page and
/// Apple's own tool palette (PKToolPicker), like Preview and Markup do, in continuous scroll. Drawings are PKDrawing data
/// (base64), one per page, saved by Dart into the project. Channel and view names must match lib/phone/pdf_view.dart.
///
/// `tableread/pdf`            pageTexts(path) -> [String]; presentMarkup(path, page, pages, dark) -> nil when closed.
///                            Native -> Dart while marking up: markup {page, data}.
/// `tableread/pdfview`        the platform view; creation args: path, dark
/// `tableread/pdfview_<id>`   per view. Dart -> native: state, goToPage, setMode, search, searchStep, clearSearch, loadMarkup.
///                            Native -> Dart: page.
final class PdfPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tableread/pdf", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PdfPlugin(channel: channel), channel: channel)
    registrar.register(PdfViewFactory(messenger: registrar.messenger()), withId: "tableread/pdfview")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pageTexts":
      let path = args["path"] as? String ?? ""
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
    case "presentMarkup":
      presentMarkup(args, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentMarkup(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard #available(iOS 16.0, *) else { return result(nil) }
    guard let path = args["path"] as? String, let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
      return result(FlutterError(code: "pdf", message: "Couldn't open the PDF", details: nil))
    }
    guard let host = Self.topViewController() else { return result(nil) }
    let vc = MarkupViewController(
      document: doc,
      page: args["page"] as? Int ?? 0,
      drawings: InkOverlays.decode(args["pages"] as? [String: String] ?? [:]),
      dark: args["dark"] as? Bool ?? false
    )
    vc.onSave = { [weak self] page, data in self?.channel.invokeMethod("markup", arguments: ["page": page, "data": data]) }
    vc.onClose = { result(nil) }
    vc.modalPresentationStyle = .fullScreen
    vc.modalTransitionStyle = .crossDissolve
    host.present(vc, animated: true)
  }

  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }
}

final class PdfViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    if #available(iOS 16.0, *) {
      return PdfPlatformView(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
    }
    return EmptyPlatformView()  // Markup overlays need iOS 16; the devices run 26+
  }
}

private final class EmptyPlatformView: NSObject, FlutterPlatformView {
  func view() -> UIView { UIView() }
}

// MARK: Ink

/// One PencilKit canvas laid over each PDF page (PDFKit's page overlay views), one drawing per page index.
/// Drawn on when [interactive] (markup viewer), otherwise only shows the ink (reading).
@available(iOS 16.0, *)
final class InkOverlays: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
  var drawings: [Int: PKDrawing]
  var interactive: Bool
  /// A drawing changed (page index, new drawing).
  var onChange: ((Int, PKDrawing) -> Void)?
  weak var pdfView: PDFView?
  let toolPicker = PKToolPicker()
  private var canvases: [PDFPage: PKCanvasView] = [:]
  private var loading = false

  init(drawings: [Int: PKDrawing] = [:], interactive: Bool) {
    self.drawings = drawings
    self.interactive = interactive
  }

  static func decode(_ pages: [String: String]) -> [Int: PKDrawing] {
    var out: [Int: PKDrawing] = [:]
    for (key, b64) in pages {
      if let i = Int(key), let data = Data(base64Encoded: b64), let d = try? PKDrawing(data: data) { out[i] = d }
    }
    return out
  }

  private func index(of page: PDFPage) -> Int? { pdfView?.document?.index(for: page) }

  /// Replaces the ink (after the markup viewer closed). Pages not mentioned lose theirs.
  func reload(_ new: [Int: PKDrawing]) {
    drawings = new
    loading = true
    for (page, c) in canvases { c.drawing = index(of: page).flatMap { new[$0] } ?? PKDrawing() }
    loading = false
  }

  func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    if let c = canvases[page] { return c }
    let c = PKCanvasView(frame: .zero)
    c.backgroundColor = .clear
    c.isOpaque = false
    c.isScrollEnabled = false
    // The page is white whatever the theme: ink must not turn light in dark mode.
    c.overrideUserInterfaceStyle = .light
    c.drawingPolicy = .default  // the system's "Only Draw with Apple Pencil" setting decides about fingers
    c.isUserInteractionEnabled = interactive
    c.delegate = self
    if let i = index(of: page), let d = drawings[i] {
      loading = true
      c.drawing = d
      loading = false
    }
    canvases[page] = c
    if interactive { toolPicker.addObserver(c) }
    return c
  }

  func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
    guard interactive, let c = overlayView as? PKCanvasView else { return }
    toolPicker.setVisible(true, forFirstResponder: c)
    if !canvases.values.contains(where: { $0.isFirstResponder }) { c.becomeFirstResponder() }
  }

  func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
    guard interactive, let c = overlayView as? PKCanvasView, c.isFirstResponder else { return }
    c.resignFirstResponder()
    // Hand the palette to a canvas still on screen.
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let next = self.canvases.values.first(where: { $0.window != nil && $0 !== c }) else { return }
      self.toolPicker.setVisible(true, forFirstResponder: next)
      next.becomeFirstResponder()
    }
  }

  /// The canvas being drawn on takes the palette (so Undo and Redo in it act on this page).
  func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    if interactive, !canvasView.isFirstResponder {
      toolPicker.setVisible(true, forFirstResponder: canvasView)
      canvasView.becomeFirstResponder()
    }
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !loading, let page = canvases.first(where: { $0.value === canvasView })?.key, let i = index(of: page) else { return }
    drawings[i] = canvasView.drawing
    onChange?(i, canvasView.drawing)
  }
}

/// Apple's way to mark up a PDF: a PDFView in continuous scroll, PencilKit on every page, the system tool palette.
@available(iOS 16.0, *)
final class MarkupViewController: UIViewController {
  private let document: PDFDocument
  private let startPage: Int
  private let dark: Bool
  private let pdfView = PDFView()
  private let overlays: InkOverlays
  private var pending: [Int: PKDrawing] = [:]
  private var timer: Timer?

  /// A page's drawing settled (page index, base64 data; '' = nothing left).
  var onSave: ((Int, String) -> Void)?
  var onClose: (() -> Void)?

  init(document: PDFDocument, page: Int, drawings: [Int: PKDrawing], dark: Bool) {
    self.document = document
    self.startPage = page
    self.dark = dark
    self.overlays = InkOverlays(drawings: drawings, interactive: true)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = dark ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.9, alpha: 1)
    pdfView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pdfView)
    NSLayoutConstraint.activate([
      pdfView.topAnchor.constraint(equalTo: view.topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    pdfView.document = document
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.pageBreakMargins = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    pdfView.backgroundColor = view.backgroundColor ?? .systemBackground
    overlays.pdfView = pdfView
    overlays.onChange = { [weak self] i, d in self?.changed(i, d) }
    pdfView.pageOverlayViewProvider = overlays
    pdfView.isInMarkupMode = true

    var config = UIButton.Configuration.filled()
    config.title = "Done"
    config.cornerStyle = .capsule
    config.baseBackgroundColor = .systemBlue
    config.baseForegroundColor = .white
    let done = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.close() })
    done.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(done)
    NSLayoutConstraint.activate([
      done.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      done.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    goToStart()
    // PDFView puts itself back on page 1 as it lays out for the first time: say it again.
    for delay in [0.15, 0.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.goToStart() } }
  }

  private func goToStart() {
    guard let page = document.page(at: min(max(startPage, 0), document.pageCount - 1)) else { return }
    pdfView.go(to: page)
  }

  private func changed(_ i: Int, _ d: PKDrawing) {
    pending[i] = d
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.flush() }
  }

  private func flush() {
    timer?.invalidate()
    for (i, d) in pending { onSave?(i, d.strokes.isEmpty ? "" : d.dataRepresentation().base64EncodedString()) }
    pending = [:]
  }

  private func close() {
    flush()
    overlays.toolPicker.setVisible(false, forFirstResponder: view)
    dismiss(animated: true) { [weak self] in self?.onClose?() }
  }
}

// MARK: Reading

@available(iOS 16.0, *)
final class PdfPlatformView: NSObject, FlutterPlatformView {
  private let pdfView = PDFView()
  private let channel: FlutterMethodChannel
  private let created = Date()
  private let overlays = InkOverlays(interactive: false)

  private var continuous = true
  private var results: [PDFSelection] = []
  private var resultIndex = 0

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "tableread/pdfview_\(viewId)", binaryMessenger: messenger)
    super.init()
    if let path = args["path"] as? String { pdfView.document = PDFDocument(url: URL(fileURLWithPath: path)) }
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.pageBreakMargins = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    pdfView.backgroundColor = (args["dark"] as? Bool ?? false) ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.9, alpha: 1)
    overlays.pdfView = pdfView
    pdfView.pageOverlayViewProvider = overlays
    NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
    // One page at a time: swipe to turn.
    for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
      let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
      swipe.direction = direction
      swipe.cancelsTouchesInView = false
      pdfView.addGestureRecognizer(swipe)
    }
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  func view() -> UIView { pdfView }

  private var pageIndex: Int {
    guard let doc = pdfView.document, let p = pdfView.currentPage else { return 0 }
    return doc.index(for: p)
  }

  @objc private func pageChanged() {
    channel.invokeMethod("page", arguments: ["page": pageIndex + 1, "count": pdfView.document?.pageCount ?? 0])
  }

  @objc private func swiped(_ g: UISwipeGestureRecognizer) {
    // Only when the page is at its fitted size (zoomed in, a swipe pans the page).
    guard !continuous, pdfView.scaleFactor <= pdfView.scaleFactorForSizeToFit * 1.05 else { return }
    if g.direction == .left, pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
    if g.direction == .right, pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
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
    case "goToPage":
      go(toPage: args["page"] as? Int ?? 1)
      result(nil)
    case "setMode":
      setContinuous(args["continuous"] as? Bool ?? true)
      result(nil)
    case "loadMarkup":
      overlays.reload(InkOverlays.decode(args["pages"] as? [String: String] ?? [:]))
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

  /// One page at a time (swipe or the toolbar's arrows) or one continuous scroll; the page being read stays.
  private func setContinuous(_ on: Bool) {
    guard on != continuous else { return }
    continuous = on
    let here = pdfView.currentPage
    pdfView.displayMode = on ? .singlePageContinuous : .singlePage
    pdfView.autoScales = true
    if let here = here { pdfView.go(to: here) }
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
