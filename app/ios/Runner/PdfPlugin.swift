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
      fraction: CGFloat(args["fraction"] as? Double ?? 0),
      drawings: InkOverlays.decode(args["pages"] as? [String: String] ?? [:]),
      dark: args["dark"] as? Bool ?? false
    )
    vc.onSave = { [weak self] page, data in self?.channel.invokeMethod("markup", arguments: ["page": page, "data": data]) }
    vc.onClose = { page, fraction in result(["page": page, "fraction": fraction]) }
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

/// Marking up, the standard PencilKit way: one PKCanvasView (itself a scroll view) holds all the pages stacked behind its ink,
/// and Apple's tool palette (PKToolPicker) belongs to that canvas. Ink is kept per page (PKDrawing in page points, like the
/// project files), and laid onto the stack here.
@available(iOS 16.0, *)
final class MarkupViewController: UIViewController, PKCanvasViewDelegate {
  private let document: PDFDocument
  private let startPage: Int
  private let startFraction: CGFloat
  private let dark: Bool
  private var userScrolled = false
  private let canvas = PKCanvasView()
  private let toolPicker = PKToolPicker()
  private let stack = UIView()
  private var pageViews: [UIImageView] = []

  /// Ink per page (page points, origin at the page's top left), as last saved or loaded.
  private var pageDrawings: [Int: PKDrawing]
  private var sent: [Int: String] = [:]
  private var timer: Timer?
  private var loading = false

  // Layout: page i sits at x = left, y = tops[i], scaled by `scale` from page points.
  private var tops: [CGFloat] = []
  private var scale: CGFloat = 1
  private var left: CGFloat = 0
  private var laidOutWidth: CGFloat = 0

  /// A page's drawing settled (page index, base64 data; '' = nothing left).
  var onSave: ((Int, String) -> Void)?
  var onClose: ((Int, Double) -> Void)?

  init(document: PDFDocument, page: Int, fraction: CGFloat, drawings: [Int: PKDrawing], dark: Bool) {
    self.document = document
    self.startPage = page
    self.startFraction = fraction
    self.pageDrawings = drawings
    self.dark = dark
    super.init(nibName: nil, bundle: nil)
    for (i, d) in drawings { sent[i] = Self.encode(d) }
  }

  required init?(coder: NSCoder) { fatalError() }

  private static func encode(_ d: PKDrawing) -> String { d.strokes.isEmpty ? "" : d.dataRepresentation().base64EncodedString() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = dark ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.88, alpha: 1)
    canvas.translatesAutoresizingMaskIntoConstraints = false
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.overrideUserInterfaceStyle = .light  // the pages are white: ink must not turn light in dark mode
    canvas.drawingPolicy = .default  // Apple's setting "Only Draw with Apple Pencil" decides about fingers
    canvas.alwaysBounceVertical = true
    canvas.delegate = self
    view.addSubview(canvas)
    NSLayoutConstraint.activate([
      canvas.topAnchor.constraint(equalTo: view.topAnchor),
      canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    stack.isUserInteractionEnabled = false
    canvas.insertSubview(stack, at: 0)  // behind the ink
    for _ in 0..<document.pageCount {
      let v = UIImageView()
      v.backgroundColor = .white
      v.layer.shadowOpacity = 0.25
      v.layer.shadowRadius = 4
      v.layer.shadowOffset = CGSize(width: 0, height: 1)
      stack.addSubview(v)
      pageViews.append(v)
    }
    toolPicker.addObserver(canvas)

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

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let w = view.bounds.width
    guard w > 0, abs(w - laidOutWidth) > 0.5 else { return }
    let first = laidOutWidth == 0
    if !first { pageDrawings = splitIntoPages() }  // rotation: keep the ink with its pages
    laidOutWidth = w
    layoutPages(width: w)
    if first || !userScrolled { goToStart() }
    renderVisible()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    showPalette()
    // The palette only attaches once the canvas is really on screen: say it again a moment later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPalette() }
    // The canvas settles its own scroll position as it appears: keep the place until a finger has moved it.
    for delay in [0.0, 0.1, 0.4] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        if let self = self, !self.userScrolled { self.goToStart() }
      }
    }
  }

  /// The place the reading view was at: the top of the screen on the same spot of the same page.
  private func goToStart() {
    guard !tops.isEmpty else { return }
    let i = min(max(startPage, 0), tops.count - 1)
    let y = tops[i] + startFraction * pageViews[i].frame.height
    let maxY = max(0, canvas.contentSize.height - canvas.bounds.height)
    canvas.setContentOffset(CGPoint(x: 0, y: min(max(0, y), maxY)), animated: false)
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrolled = true }

  /// The page at the top of the screen, and how far down it that is (0...1).
  private func topPosition() -> (Int, Double) {
    let y = canvas.contentOffset.y
    var page = 0
    for (i, top) in tops.enumerated() where top <= y + 1 { page = i }
    let h = pageViews[page].frame.height
    return (page, Double(min(max((y - tops[page]) / h, 0), 1)))
  }

  private func showPalette() {
    canvas.becomeFirstResponder()
    toolPicker.setVisible(true, forFirstResponder: canvas)
  }

  // MARK: Pages

  private func layoutPages(width w: CGFloat) {
    let margin: CGFloat = 12
    let pageWidth = min(w - 2 * margin, 1100)
    left = (w - pageWidth) / 2
    var y = margin
    tops = []
    var firstScale: CGFloat = 1
    for (i, v) in pageViews.enumerated() {
      let box = document.page(at: i)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
      let s = pageWidth / box.width
      if i == 0 { firstScale = s }
      tops.append(y)
      v.frame = CGRect(x: left, y: y, width: pageWidth, height: box.height * s)
      v.image = nil
      y += box.height * s + margin
    }
    scale = firstScale
    stack.frame = CGRect(x: 0, y: 0, width: w, height: y)
    loading = true
    canvas.contentSize = CGSize(width: w, height: y)
    canvas.drawing = combined()
    loading = false
  }

  /// Ink of all the pages as one drawing on the stack.
  private func combined() -> PKDrawing {
    var all = PKDrawing()
    for (i, d) in pageDrawings where i < tops.count && !d.strokes.isEmpty {
      let s = pageScale(i)
      let t = CGAffineTransform(translationX: left, y: tops[i]).scaledBy(x: s, y: s)
      all.append(d.transformed(using: t))
    }
    return all
  }

  private func pageScale(_ i: Int) -> CGFloat {
    let box = document.page(at: i)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
    return pageViews[i].frame.width / box.width
  }

  /// The canvas's ink back into pages (page points): each stroke goes to the page it mostly lies on.
  private func splitIntoPages() -> [Int: PKDrawing] {
    var buckets: [Int: [PKStroke]] = [:]
    for stroke in canvas.drawing.strokes {
      let y = stroke.renderBounds.midY
      var page = 0
      for (i, top) in tops.enumerated() where top <= y { page = i }
      buckets[page, default: []].append(stroke)
    }
    var out: [Int: PKDrawing] = [:]
    for (i, strokes) in buckets {
      let s = pageScale(i)
      let t = CGAffineTransform(scaleX: 1 / s, y: 1 / s).translatedBy(x: -left, y: -tops[i])
      out[i] = PKDrawing(strokes: strokes).transformed(using: t)
    }
    return out
  }

  /// Only the pages near the screen are drawn (a script can be 100 pages).
  private func renderVisible() {
    let h = canvas.bounds.height
    let lo = canvas.contentOffset.y - h, hi = canvas.contentOffset.y + 2 * h
    for (i, v) in pageViews.enumerated() {
      let near = v.frame.maxY >= lo && v.frame.minY <= hi
      if !near {
        v.image = nil
      } else if v.image == nil, let page = document.page(at: i) {
        let box = page.bounds(for: .cropBox)
        let s = v.frame.width / box.width
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = traitCollection.displayScale
        v.image = UIGraphicsImageRenderer(size: v.frame.size, format: fmt).image { ctx in
          UIColor.white.setFill()
          ctx.fill(CGRect(origin: .zero, size: v.frame.size))
          let c = ctx.cgContext
          c.translateBy(x: 0, y: v.frame.height)
          c.scaleBy(x: s, y: -s)
          c.translateBy(x: -box.minX, y: -box.minY)
          page.draw(with: .cropBox, to: c)
        }
      }
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { renderVisible() }

  // MARK: Saving

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !loading else { return }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.flush() }
  }

  private func flush() {
    timer?.invalidate()
    timer = nil
    let now = splitIntoPages()
    for i in Set(now.keys).union(sent.keys) {
      let data = now[i].map(Self.encode) ?? ""
      if sent[i] != data {
        sent[i] = data
        onSave?(i, data)
      }
    }
    pageDrawings = now
  }

  private func close() {
    flush()
    let (page, fraction) = topPosition()
    toolPicker.setVisible(false, forFirstResponder: canvas)
    dismiss(animated: true) { [weak self] in self?.onClose?(page, fraction) }
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

  /// The page at the top of the view, and how far down it the top edge is (0...1).
  private func position() -> [String: Any] {
    let top = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY + 1)
    guard let page = pdfView.page(for: top, nearest: true), let doc = pdfView.document else { return ["page": pageIndex, "fraction": 0.0] }
    let box = page.bounds(for: .cropBox)
    let inPage = pdfView.convert(top, to: page)
    let fraction = min(max(1 - (inPage.y - box.minY) / box.height, 0), 1)
    return ["page": doc.index(for: page), "fraction": Double(fraction)]
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "state":
      result(["page": pageIndex + 1, "count": pdfView.document?.pageCount ?? 0])
    case "goToPage":
      go(toPage: args["page"] as? Int ?? 1)
      result(nil)
    case "position":
      result(position())
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
