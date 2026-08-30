import AppKit
import PDFKit
import SwiftUI

// MARK: - CalibrationBox

/// A user-drawn calibration box. Geometry (`rect`) is always current and is
/// edited purely locally (create/move/resize never touch the backend). `tag`
/// is nil until a successful `analyzeRegion` call — triggered only by tapping
/// a role pill in `CalibrationActionBar` — fills it in; any subsequent move
/// or resize clears it back to nil, since the analysis it held described the
/// box's old position.
struct CalibrationBox: Identifiable, Equatable {
    struct Tag: Equatable {
        var role: String          // CalibrationItem.rawValue
        var x0: Double
        var x1: Double            // from RegionStyle — the real text extent, not the drawn rect
        var capsRatio: Double
        var isBold: Bool
        var isItalic: Bool
        var text: String
    }

    let id: UUID
    var page: Int                 // 0-indexed
    var rect: CGRect               // PDF point-space, top-left origin, y-down
    var tag: Tag?

    init(id: UUID = UUID(), page: Int, rect: CGRect, tag: Tag? = nil) {
        self.id = id
        self.page = page
        self.rect = rect
        self.tag = tag
    }
}

// MARK: - PageCoordinateConverter

/// Converts between PDF point-space (top-left origin, y-down — the same
/// convention `analyze_region` and `_extract_blocks` use) and the rendered
/// page image's view-space, given a fit-to-container scale plus the user's
/// current zoom/pan. Every box position and gesture goes through this one
/// converter, so zoom and pan never need special-casing anywhere else.
struct PageCoordinateConverter {
    var pageSize: CGSize
    var containerSize: CGSize
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero

    private var fitScale: CGFloat {
        guard pageSize.width > 0, pageSize.height > 0 else { return 1 }
        return min(containerSize.width / pageSize.width, containerSize.height / pageSize.height)
    }

    var scale: CGFloat { fitScale * zoomScale }

    private var renderedSize: CGSize {
        CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }

    private var origin: CGPoint {
        CGPoint(x: (containerSize.width - renderedSize.width) / 2 + panOffset.width,
                y: (containerSize.height - renderedSize.height) / 2 + panOffset.height)
    }

    func viewRect(fromPagePoints rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale,
               y: origin.y + rect.minY * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }

    func pagePoints(fromView rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - origin.x) / scale,
               y: (rect.minY - origin.y) / scale,
               width: rect.width / scale,
               height: rect.height / scale)
    }

    func pageDelta(fromViewTranslation translation: CGSize) -> CGSize {
        CGSize(width: translation.width / scale, height: translation.height / scale)
    }
}

// MARK: - FormatCalibrationPageView

/// Renders one PDF page and hosts the rubber-band create gesture plus every
/// box's move/resize/tap-to-select interaction. Creating, moving, and
/// resizing a box are purely local `CGRect` edits — none of them call the
/// backend. Region analysis happens only when the user taps a role pill in
/// `CalibrationActionBar` (owned by `FormatCalibrationSheet`), not here.
struct FormatCalibrationPageView: View {
    var pdfDocument: PDFDocument?
    var pageIndex: Int
    @Binding var boxes: [CalibrationBox]
    @Binding var selectedBoxID: UUID?

    @State private var pageImage: NSImage?
    @State private var pageSize: CGSize = CGSize(width: 612, height: 792)

    @State private var dragAnchor: CGPoint?
    @State private var dragCurrent: CGPoint?

    // Zoom / pan
    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panDragStartOffset: CGSize?
    @State private var isPanToolActive = false
    @GestureState private var magnifyBy: CGFloat = 1

    private static let minBoxSide: CGFloat = 4
    private static let minZoom: CGFloat = 0.5
    private static let maxZoom: CGFloat = 8

    private var effectiveZoom: CGFloat {
        clampedZoom(zoomScale * magnifyBy)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minZoom), Self.maxZoom)
    }

    var body: some View {
        GeometryReader { geo in
            let converter = PageCoordinateConverter(
                pageSize: pageSize, containerSize: geo.size,
                zoomScale: effectiveZoom, panOffset: panOffset
            )
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .textBackgroundColor)
                        .frame(width: geo.size.width, height: geo.size.height)

                    if let pageImage {
                        // Must go through the SAME converter as every box, or
                        // zoom/pan would move boxes without moving the page
                        // underneath them.
                        let pageViewRect = converter.viewRect(fromPagePoints: CGRect(origin: .zero, size: pageSize))
                        Image(nsImage: pageImage)
                            .resizable()
                            .frame(width: pageViewRect.width, height: pageViewRect.height)
                            .offset(x: pageViewRect.minX, y: pageViewRect.minY)
                            .allowsHitTesting(false)
                    } else {
                        ProgressView()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }

                    // Background create-drag / pan layer. Sits behind every
                    // box, so a box's own gestures win hit-testing at its
                    // location — same layering trick ProjectGalleryView's
                    // rubber-band uses. Swaps between "draw a box" and "pan"
                    // depending on which tool is active.
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(backgroundGesture(converter: converter))

                    ForEach(boxes.indices.filter { boxes[$0].page == pageIndex }, id: \.self) { index in
                        CalibrationBoxView(
                            box: $boxes[index],
                            isSelected: selectedBoxID == boxes[index].id,
                            converter: converter,
                            onSelect: { selectedBoxID = boxes[index].id },
                            onDelete: {
                                let id = boxes[index].id
                                if selectedBoxID == id { selectedBoxID = nil }
                                boxes.removeAll { $0.id == id }
                            }
                        )
                    }

                    if let rect = liveDragRect {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.1))
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .coordinateSpace(name: "calibrationPage")
                .gesture(magnifyGesture)

                zoomControls
                    .padding(10)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: pdfDocument?.documentURL) { _, _ in renderCurrentPage() }
        .onChange(of: pageIndex) { _, _ in renderCurrentPage() }
        .onAppear { renderCurrentPage() }
    }

    // MARK: - Zoom / pan controls

    private var zoomControls: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { isPanToolActive.toggle() }
            } label: {
                Image(systemName: "hand.raised.fill")
                    .frame(width: 22, height: 22)
            }
            .foregroundStyle(isPanToolActive ? Color.white : Color.primary)
            .background(isPanToolActive ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .help("Grab to pan")

            Divider().frame(width: 22)

            Button { zoomScale = clampedZoom(zoomScale * 1.25) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 22, height: 22)
            }
            .help("Zoom in")

            Button { zoomScale = clampedZoom(zoomScale / 1.25) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 22, height: 22)
            }
            .help("Zoom out")

            Button {
                withAnimation(.snappy(duration: 0.2)) { zoomScale = 1; panOffset = .zero }
            } label: {
                Text("Fit").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 16)
            }
            .help("Reset zoom to fit the window")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($magnifyBy) { value, state, _ in state = value }
            .onEnded { value in
                zoomScale = clampedZoom(zoomScale * value)
            }
    }

    private var liveDragRect: CGRect? {
        guard let a = dragAnchor, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Swaps the background gesture between "draw a box" (default) and
    /// "pan" (when the hand tool is active) — type-erased since the two
    /// underlying `DragGesture`s are otherwise distinct generic types.
    private func backgroundGesture(converter: PageCoordinateConverter) -> AnyGesture<Void> {
        if isPanToolActive {
            return AnyGesture(panGesture().map { _ in })
        } else {
            return AnyGesture(createGesture(converter: converter).map { _ in })
        }
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("calibrationPage"))
            .onChanged { value in
                if panDragStartOffset == nil { panDragStartOffset = panOffset }
                guard let start = panDragStartOffset else { return }
                panOffset = CGSize(width: start.width + value.translation.width,
                                    height: start.height + value.translation.height)
            }
            .onEnded { _ in
                panDragStartOffset = nil
            }
    }

    private func createGesture(converter: PageCoordinateConverter) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("calibrationPage"))
            .onChanged { value in
                if dragAnchor == nil { dragAnchor = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { _ in
                defer {
                    dragAnchor = nil
                    dragCurrent = nil
                }
                guard let rect = liveDragRect,
                      rect.width > Self.minBoxSide, rect.height > Self.minBoxSide else { return }
                let pageRect = converter.pagePoints(fromView: rect)
                let newBox = CalibrationBox(page: pageIndex, rect: pageRect)
                boxes.append(newBox)
                selectedBoxID = newBox.id
            }
    }

    private func renderCurrentPage() {
        guard let pdfDocument, let page = pdfDocument.page(at: pageIndex) else {
            pageImage = nil
            return
        }
        let size = page.bounds(for: .mediaBox).size
        guard size.width > 0, size.height > 0 else {
            pageImage = nil
            return
        }
        pageSize = size
        let longEdge: CGFloat = 2200
        let scale = longEdge / max(size.width, size.height)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        pageImage = page.thumbnail(of: targetSize, for: .mediaBox)
    }
}

// MARK: - CalibrationBoxView

private struct CalibrationBoxView: View {
    @Binding var box: CalibrationBox
    var isSelected: Bool
    var converter: PageCoordinateConverter
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var moveStartRect: CGRect?
    @State private var resizeStartRect: CGRect?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private static let handleSize: CGFloat = 9
    private static let dragThreshold: CGFloat = 4
    private static let minRectSide: CGFloat = 6

    var body: some View {
        let frame = converter.viewRect(fromPagePoints: box.rect)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(fillColor)
                .overlay(Rectangle().stroke(strokeColor, style: strokeStyle))
                .frame(width: max(frame.width, 0), height: max(frame.height, 0))
                .contentShape(Rectangle())
                .gesture(moveGesture)

            if let tag = box.tag {
                let item = CalibrationItem(rawValue: tag.role)
                Text(item?.label ?? tag.role)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(item?.color ?? .accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 2, y: -16)
                    .allowsHitTesting(false)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: max(frame.width, 0) - 8, y: -8)

            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .position(handlePosition(for: corner, size: frame.size))
                    .gesture(resizeGesture(for: corner))
            }
        }
        .offset(x: frame.minX, y: frame.minY)
    }

    private var roleColor: Color {
        box.tag.flatMap { CalibrationItem(rawValue: $0.role)?.color } ?? .orange
    }

    private var fillColor: Color {
        roleColor.opacity(box.tag == nil ? 0.08 : 0.14)
    }

    private var strokeColor: Color {
        if isSelected { return Color.accentColor }
        return box.tag == nil ? roleColor.opacity(0.7) : roleColor
    }

    private var strokeStyle: StrokeStyle {
        if isSelected { return StrokeStyle(lineWidth: 2) }
        return box.tag == nil ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)
    }

    private func handlePosition(for corner: Corner, size: CGSize) -> CGPoint {
        switch corner {
        case .topLeft:     return CGPoint(x: 0, y: 0)
        case .topRight:    return CGPoint(x: size.width, y: 0)
        case .bottomLeft:  return CGPoint(x: 0, y: size.height)
        case .bottomRight: return CGPoint(x: size.width, y: size.height)
        }
    }

    /// A single drag recognizer handles both tap-to-select (negligible
    /// movement) and move (movement past the threshold) — avoids the
    /// ambiguity of stacking a separate tap gesture and drag gesture on the
    /// same view.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("calibrationPage"))
            .onChanged { value in
                guard didExceedThreshold(value.translation) else { return }
                if moveStartRect == nil { moveStartRect = box.rect }
                guard let start = moveStartRect else { return }
                let delta = converter.pageDelta(fromViewTranslation: value.translation)
                box.rect = start.offsetBy(dx: delta.width, dy: delta.height)
            }
            .onEnded { value in
                if didExceedThreshold(value.translation) {
                    if box.tag != nil { box.tag = nil }
                } else {
                    onSelect()
                }
                moveStartRect = nil
            }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("calibrationPage"))
            .onChanged { value in
                if resizeStartRect == nil { resizeStartRect = box.rect }
                guard let start = resizeStartRect else { return }
                let delta = converter.pageDelta(fromViewTranslation: value.translation)
                box.rect = Self.resizedRect(start, corner: corner, delta: delta)
            }
            .onEnded { _ in
                if box.tag != nil { box.tag = nil }
                resizeStartRect = nil
            }
    }

    private func didExceedThreshold(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > Self.dragThreshold
    }

    private static func resizedRect(_ rect: CGRect, corner: Corner, delta: CGSize) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch corner {
        case .topLeft:
            minX += delta.width
            minY += delta.height
        case .topRight:
            maxX += delta.width
            minY += delta.height
        case .bottomLeft:
            minX += delta.width
            maxY += delta.height
        case .bottomRight:
            maxX += delta.width
            maxY += delta.height
        }
        if maxX - minX < minRectSide {
            if corner == .topLeft || corner == .bottomLeft { minX = maxX - minRectSide } else { maxX = minX + minRectSide }
        }
        if maxY - minY < minRectSide {
            if corner == .topLeft || corner == .topRight { minY = maxY - minRectSide } else { maxY = minY + minRectSide }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - CalibrationActionBar

/// Bottom contextual toolbar — mirrors `SelectionActionsBar`'s visual recipe
/// (Views.swift). Shows one pill per unresolved `CalibrationItem` (each with
/// its own exclude "x") until every item is resolved, then switches to the
/// save/continue footer.
struct CalibrationActionBar: View {
    var allResolved: Bool
    var resolvedCount: Int
    var totalCount: Int
    var unresolvedItems: [CalibrationItem]
    var isAnalyzing: Bool
    var isDeriving: Bool
    var onTagRole: (CalibrationItem) -> Void
    var onExcludeItem: (CalibrationItem) -> Void
    var onSaveAs: () -> Void
    var onContinue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(resolvedCount) of \(totalCount) resolved")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()

            Divider().frame(height: 14)

            if allResolved {
                Spacer(minLength: 0)
                Button("Save to Library As…", action: onSaveAs)
                    .buttonStyle(.borderless)
                    .disabled(isDeriving)
                Button("Continue to Parse", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDeriving)
                    .keyboardShortcut(.defaultAction)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(unresolvedItems) { item in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 6, height: 6)
                                Button { onTagRole(item) } label: {
                                    Text(item.label)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(item.color)
                                }
                                .buttonStyle(.plain)
                                Button { onExcludeItem(item) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("This script doesn't use this element")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(item.color.opacity(0.15), in: Capsule())
                        }
                    }
                }
                .disabled(isAnalyzing)
                .opacity(isAnalyzing ? 0.5 : 1)

                if isAnalyzing {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 860)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
    }
}
