import Flutter
import UIKit
import PDFKit
import PencilKit

/// Show PDF (#115): the project's screenplay in PDFKit, as a Flutter platform view, plus Apple Pencil markup on
/// iPad (#119, PencilKit overlay per page) and page / continuous reading (#120). Channel and view names must match
/// lib/phone/pdf_view.dart.
///
/// `tableread/pdf`            pageTexts(path) -> [String]   (the text of every page, to line the script up with its pages)
/// `tableread/pdfview`        the platform view; creation args: path, dark
/// `tableread/pdfview_<id>`   per view. Dart -> native: state, goToPage, setMode, search, searchStep, clearSearch,
///                            setMarkup, setTool, systemPalette, loadMarkup, undo, redo, clearPage.
///                            Native -> Dart: page, markup, history.
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
    if #available(iOS 16.0, *) {
      return PdfPlatformView(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
    }
    return EmptyPlatformView()  // Markup overlays need iOS 16; the phone runs 26+
  }
}

private final class EmptyPlatformView: NSObject, FlutterPlatformView {
  func view() -> UIView { UIView() }
}

@available(iOS 16.0, *)
final class PdfPlatformView: NSObject, FlutterPlatformView, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
  private let pdfView = PDFView()
  private let channel: FlutterMethodChannel
  private let created = Date()

  // Reading
  private var continuous = true
  private var results: [PDFSelection] = []
  private var resultIndex = 0

  // Markup: one PencilKit canvas per page shown, one saved drawing per page (by page index).
  private var drawings: [Int: PKDrawing] = [:]
  private var canvases: [PDFPage: PKCanvasView] = [:]
  private var markupOn = false
  private var fingerDraws = false
  private lazy var toolPicker = PKToolPicker()
  // The pen in hand (our own pen / highlighter / eraser strip drives it) and whether Apple's tool palette is up instead.
  private var tool: PKTool = PKInkingTool(.pen, color: UIColor(red: 0.11, green: 0.11, blue: 0.10, alpha: 1), width: 3)
  private var systemPalette = false
  private var saveTimers: [Int: Timer] = [:]
  private var loading = false
  // The canvas drawn on last: Undo, Redo and Clear page act on it.
  private weak var activeCanvas: PKCanvasView?

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "tableread/pdfview_\(viewId)", binaryMessenger: messenger)
    super.init()
    if let path = args["path"] as? String { pdfView.document = PDFDocument(url: URL(fileURLWithPath: path)) }
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.pageBreakMargins = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    pdfView.backgroundColor = (args["dark"] as? Bool ?? false) ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.9, alpha: 1)
    pdfView.pageOverlayViewProvider = self
    NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    saveTimers.values.forEach { $0.invalidate() }
  }

  func view() -> UIView { pdfView }

  private var pageIndex: Int {
    guard let doc = pdfView.document, let p = pdfView.currentPage else { return 0 }
    return doc.index(for: p)
  }

  @objc private func pageChanged() {
    channel.invokeMethod("page", arguments: ["page": pageIndex + 1, "count": pdfView.document?.pageCount ?? 0])
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
    case "search":
      result(search(args["query"] as? String ?? "", reveal: args["reveal"] as? Bool ?? true))
    case "searchStep":
      result(stepSearch(forward: args["forward"] as? Bool ?? true))
    case "clearSearch":
      results = []
      pdfView.highlightedSelections = nil
      pdfView.clearSelection()
      result(nil)
    case "setMarkup":
      markupOn = args["enabled"] as? Bool ?? false
      fingerDraws = args["finger"] as? Bool ?? false
      applyMarkupState()
      result(nil)
    case "setTool":
      tool = makeTool(args)
      for (_, c) in canvases { c.tool = tool }
      result(nil)
    case "systemPalette":
      systemPalette = args["on"] as? Bool ?? false
      applyMarkupState()
      result(nil)
    case "loadMarkup":
      loadMarkup(args["pages"] as? [String: String] ?? [:])
      result(nil)
    case "undo":
      editCanvas { $0.undoManager?.undo() }
      result(nil)
    case "redo":
      editCanvas { $0.undoManager?.redo() }
      result(nil)
    case "clearPage":
      // One undoable step, so a slip of the finger can be taken back.
      editCanvas { c in
        let old = c.drawing
        guard !old.strokes.isEmpty else { return }
        c.undoManager?.registerUndo(withTarget: c) { $0.drawing = old }
        c.drawing = PKDrawing()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Reading

  /// Page by page (swipe to turn) or one continuous scroll; the page being read stays.
  private func setContinuous(_ on: Bool) {
    guard on != continuous else { return }
    continuous = on
    let here = pdfView.currentPage
    if on {
      pdfView.usePageViewController(false)
      pdfView.displayMode = .singlePageContinuous
    } else {
      pdfView.displayMode = .singlePage
      pdfView.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 12])
    }
    pdfView.autoScales = true
    if let here = here { pdfView.go(to: here) }
    applyMarkupState()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.configureTouches() }
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

  // MARK: Markup

  private func policy() -> PKCanvasViewDrawingPolicy { fingerDraws ? .anyInput : .pencilOnly }

  /// Each canvas draws only while markup is on; off, touches pass through to scrolling and zooming.
  private func applyMarkupState() {
    if #available(iOS 16.0, *) { pdfView.isInMarkupMode = markupOn }
    for (_, c) in canvases {
      c.drawingPolicy = policy()
      c.isUserInteractionEnabled = markupOn
      if !systemPalette { c.tool = tool }
    }
    configureTouches()
    if markupOn && systemPalette {
      showToolPicker()
    } else {
      for (_, c) in canvases {
        toolPicker.setVisible(false, forFirstResponder: c)
        c.resignFirstResponder()
      }
    }
  }

  /// While marking up, the Pencil belongs to the drawing alone: the PDF's scrolling, text selection and zoom answer to fingers
  /// (or, when fingers draw, to two fingers). Off, everything answers to everything again.
  private func configureTouches() {
    let types: [UITouch.TouchType] = [.direct, .indirect, .pencil, .indirectPointer]
    let everything = types.map { NSNumber(value: $0.rawValue) }
    let noPencil = types.filter { $0 != .pencil }.map { NSNumber(value: $0.rawValue) }
    let pencilOnly = markupOn && !fingerDraws
    func walk(_ v: UIView) {
      for sub in v.subviews where !(sub is PKCanvasView) {
        for g in sub.gestureRecognizers ?? [] {
          g.allowedTouchTypes = pencilOnly ? noPencil : everything
          if let pan = g as? UIPanGestureRecognizer, sub is UIScrollView { pan.minimumNumberOfTouches = markupOn && fingerDraws ? 2 : 1 }
        }
        walk(sub)
      }
    }
    for g in pdfView.gestureRecognizers ?? [] { g.allowedTouchTypes = pencilOnly ? noPencil : everything }
    walk(pdfView)
  }

  private func makeTool(_ a: [String: Any]) -> PKTool {
    let kind = a["tool"] as? String ?? "pen"
    if kind == "eraser" { return PKEraserTool(.vector) }
    let argb = UInt32(truncatingIfNeeded: (a["color"] as? Int) ?? 0xFF1C1B19)
    let color = UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255, blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
    return PKInkingTool(kind == "marker" ? .marker : .pen, color: color, width: CGFloat((a["width"] as? Double) ?? 3))
  }

  private func showToolPicker() {
    guard markupOn else { return }
    let here = pdfView.currentPage.flatMap { canvases[$0] } ?? canvases.values.first
    guard let c = here else { return }
    for other in canvases.values { toolPicker.addObserver(other) }
    toolPicker.setVisible(true, forFirstResponder: c)
    c.becomeFirstResponder()
  }

  func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    if let c = canvases[page] { return c }
    let c = PKCanvasView(frame: .zero)
    c.backgroundColor = .clear
    c.isOpaque = false
    // The canvas must not scroll on its own: fingers belong to the PDF's scrolling and zooming.
    c.isScrollEnabled = false
    c.drawingPolicy = policy()
    c.isUserInteractionEnabled = markupOn
    // The page is white whatever the theme: ink must not turn light in dark mode.
    c.overrideUserInterfaceStyle = .light
    c.tool = tool
    c.delegate = self
    if let doc = pdfView.document, let d = drawings[doc.index(for: page)] {
      loading = true
      c.drawing = d
      loading = false
    }
    canvases[page] = c
    return c
  }

  func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
    guard let c = overlayView as? PKCanvasView else { return }
    configureTouches()
    guard systemPalette else { return }
    toolPicker.addObserver(c)
    if markupOn, !canvases.values.contains(where: { $0.isFirstResponder }) {
      toolPicker.setVisible(true, forFirstResponder: c)
      c.becomeFirstResponder()
    }
  }

  func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
    guard let c = overlayView as? PKCanvasView, let doc = pdfView.document else { return }
    drawings[doc.index(for: page)] = c.drawing
  }

  /// Runs an edit on the canvas drawn on last (or the one on the page showing).
  private func editCanvas(_ edit: (PKCanvasView) -> Void) {
    guard let c = activeCanvas ?? pdfView.currentPage.flatMap({ canvases[$0] }) else { return }
    activeCanvas = c
    edit(c)
    reportHistory()
  }

  private func reportHistory() {
    let m = activeCanvas?.undoManager
    channel.invokeMethod("history", arguments: ["undo": m?.canUndo ?? false, "redo": m?.canRedo ?? false])
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !loading, let page = canvases.first(where: { $0.value === canvasView })?.key, let doc = pdfView.document else { return }
    activeCanvas = canvasView
    // The undo manager is updated just after this callback.
    DispatchQueue.main.async { [weak self] in self?.reportHistory() }
    let i = doc.index(for: page)
    drawings[i] = canvasView.drawing
    // Tell Dart once the pen has paused: it saves the page into the project.
    saveTimers[i]?.invalidate()
    saveTimers[i] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
      guard let self = self, let d = self.drawings[i] else { return }
      let data = d.strokes.isEmpty ? "" : d.dataRepresentation().base64EncodedString()
      self.channel.invokeMethod("markup", arguments: ["page": i, "data": data])
    }
  }

  private func loadMarkup(_ pages: [String: String]) {
    loading = true
    defer { loading = false }
    for (key, b64) in pages {
      guard let i = Int(key) else { continue }
      if b64.isEmpty {
        drawings[i] = nil
      } else if let data = Data(base64Encoded: b64), let d = try? PKDrawing(data: data) {
        drawings[i] = d
      }
      if let doc = pdfView.document, i < doc.pageCount, let page = doc.page(at: i), let c = canvases[page] {
        c.drawing = drawings[i] ?? PKDrawing()
      }
    }
  }
}
