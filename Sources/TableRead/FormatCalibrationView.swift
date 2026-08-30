import PDFKit
import SwiftUI

/// The checklist items a user works through in the calibration sheet.
/// `overlapIndicator` is a client-only pseudo-role: it's never sent to the
/// backend's `_BTYPES` role vocabulary — the derived FormatProfile's
/// `overlapMarkerDescription` is instead filled in locally from whichever
/// box the user tags it with (metadata only in v1, not machine-applied —
/// see backend/parser.py's derive_format_profile docstring).
enum CalibrationItem: String, CaseIterable, Identifiable {
    case characterCue = "character_cue"
    case dialog = "dialog"
    case stageDirection = "stage_direction"
    case parenthetical = "parenthetical"
    case sceneHeading = "scene_heading"
    case overlapIndicator = "overlap_indicator"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .characterCue: "Character Cue"
        case .dialog: "Dialog"
        case .stageDirection: "Stage Direction"
        case .parenthetical: "Parenthetical"
        case .sceneHeading: "Scene Heading"
        case .overlapIndicator: "Overlap Indicator"
        }
    }

    /// Fixed, stable color per role — used for both the bottom bar's pills
    /// and the boxes drawn on the page, so a role reads at a glance no
    /// matter how many are on screen at once.
    var color: Color {
        switch self {
        case .characterCue: .blue
        case .dialog: .green
        case .stageDirection: .orange
        case .parenthetical: .purple
        case .sceneHeading: .pink
        case .overlapIndicator: .teal
        }
    }
}

// MARK: - FormatCalibrationSheet

struct FormatCalibrationSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var templateLibrary: FormatTemplateLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var boxes: [CalibrationBox] = []
    @State private var selectedBoxID: UUID?
    @State private var isAnalyzing = false
    @State private var regionError: String?
    @State private var excludedItems: Set<String> = []    // CalibrationItem rawValues
    @State private var isDeriving = false
    @State private var deriveError: String?
    @State private var showLibraryPicker = false
    @State private var showSaveAs = false
    @State private var newTemplateName = ""
    @State private var showPrimer = true

    private func isResolved(_ item: CalibrationItem) -> Bool {
        excludedItems.contains(item.rawValue) || boxes.contains { $0.tag?.role == item.rawValue }
    }

    private var unresolvedItems: [CalibrationItem] {
        CalibrationItem.allCases.filter { !isResolved($0) }
    }

    private var allResolved: Bool {
        CalibrationItem.allCases.allSatisfy(isResolved)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                pageNavigationBar
                Divider()
                ZStack(alignment: .bottom) {
                    FormatCalibrationPageView(
                        pdfDocument: pdfDocument,
                        pageIndex: currentPageIndex,
                        boxes: $boxes,
                        selectedBoxID: $selectedBoxID
                    )
                    if !boxes.isEmpty {
                        CalibrationActionBar(
                            allResolved: allResolved,
                            resolvedCount: CalibrationItem.allCases.filter(isResolved).count,
                            totalCount: CalibrationItem.allCases.count,
                            unresolvedItems: unresolvedItems,
                            isAnalyzing: isAnalyzing,
                            isDeriving: isDeriving,
                            onTagRole: { tagSelectedBox(as: $0) },
                            onExcludeItem: { toggleExcluded($0) },
                            onSaveAs: {
                                newTemplateName = state.script?.title ?? "New Template"
                                showSaveAs = true
                            },
                            onContinue: { deriveAndApply() }
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: boxes.isEmpty)
            }

            if showPrimer {
                CalibrationPrimerOverlay(onDismiss: { withAnimation(.snappy(duration: 0.2)) { showPrimer = false } })
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: showPrimer)
        .frame(minWidth: 1100, idealWidth: 1500, maxWidth: .infinity,
               minHeight: 760, idealHeight: 960, maxHeight: .infinity)
        .task {
            if let pdf = state.selectedPDF {
                pdfDocument = PDFDocument(url: pdf)
            }
        }
        .sheet(isPresented: $showLibraryPicker) {
            FormatTemplateLibraryPickerView { profile in
                state.applyFormatProfile(profile)
                dismiss()
            }
        }
        .alert("Save Format Template", isPresented: $showSaveAs) {
            TextField("Template name", text: $newTemplateName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { deriveAndSave() }
        } message: {
            Text("Save this calibration so you can reuse it for other scripts with the same layout.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Help Table Read Read This Script")
                    .font(.title3.weight(.semibold))
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showPrimer = true }
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show instructions")
                Spacer()
                Button("Choose from Library…") { showLibraryPicker = true }
                    .buttonStyle(.borderless)
                Button("Skip — Use Automatic Detection") {
                    state.skipFormatCalibration()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            Text("Draw a box around an example of each item, then tag it from the bar at the bottom.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let deriveError {
                Text(deriveError).font(.caption).foregroundStyle(.red)
            }
            if let regionError {
                Text(regionError).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Page navigation

    private var pageNavigationBar: some View {
        HStack(spacing: 10) {
            Button {
                currentPageIndex -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(currentPageIndex <= 0)

            Text("Page \(currentPageIndex + 1) of \(pdfDocument?.pageCount ?? 0)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 110)

            Button {
                currentPageIndex += 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(currentPageIndex + 1 >= (pdfDocument?.pageCount ?? 0))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func toggleExcluded(_ item: CalibrationItem) {
        if excludedItems.contains(item.rawValue) {
            excludedItems.remove(item.rawValue)
        } else {
            excludedItems.insert(item.rawValue)
        }
    }

    /// Fires exactly one `analyzeRegion` call, against the selected box's
    /// CURRENT rect, tagging it with the given role on success. This is the
    /// only place region analysis happens — box create/move/resize never
    /// call the backend.
    private func tagSelectedBox(as item: CalibrationItem) {
        guard let id = selectedBoxID, !isAnalyzing else { return }
        guard let box = boxes.first(where: { $0.id == id }) else { return }
        guard let pdf = state.selectedPDF else { return }

        isAnalyzing = true
        state.dlog("[calibration] analyzing box on page \(box.page + 1) for \"\(item.label)\"…", .debug)
        Task {
            defer { isAnalyzing = false }
            do {
                let region = try await state.bridge.analyzeRegion(pdf: pdf, page: box.page, rect: box.rect)
                guard let region else {
                    state.dlog("[calibration] no text found under the box on page \(box.page + 1) for \"\(item.label)\"", .warning)
                    showTransientRegionError("Couldn't find any text there — try adjusting the box.")
                    return
                }
                // Re-locate by id: the box may have moved position in the
                // array (or been deleted) during this await.
                guard let idx = boxes.firstIndex(where: { $0.id == id }) else { return }
                boxes[idx].tag = CalibrationBox.Tag(
                    role: item.rawValue,
                    x0: region.x0, x1: region.x1,
                    capsRatio: region.capsRatio,
                    isBold: region.isBold, isItalic: region.isItalic,
                    text: region.text
                )
                selectedBoxID = nil
                state.dlog(
                    "[calibration] tagged \"\(item.label)\" — x=[\(Int(region.x0)),\(Int(region.x1))] "
                    + "caps=\(String(format: "%.2f", region.capsRatio)) bold=\(region.isBold) italic=\(region.isItalic) "
                    + "text=\"\(region.text.prefix(40))\"",
                    .success
                )
            } catch {
                state.dlog("[calibration] analyzeRegion failed — \(error.localizedDescription)", .error)
                showTransientRegionError(error.localizedDescription)
            }
        }
    }

    private func showTransientRegionError(_ message: String) {
        regionError = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if regionError == message { regionError = nil }
        }
    }

    /// Builds a FormatProfile from the current tags, then patches in the
    /// client-only overlap marker description before returning it.
    private func buildProfile() async throws -> FormatProfile {
        let examples: [TaggedBlockExample] = boxes.compactMap { box in
            guard let tag = box.tag, tag.role != CalibrationItem.overlapIndicator.rawValue else { return nil }
            return TaggedBlockExample(role: tag.role, region: RegionStyle(
                x0: tag.x0, x1: tag.x1, capsRatio: tag.capsRatio,
                isBold: tag.isBold, isItalic: tag.isItalic, text: tag.text
            ))
        }
        state.dlog("[calibration] deriving FormatProfile from \(examples.count) tagged example(s)…", .debug)
        var profile = try await state.bridge.deriveFormatProfile(
            pdf: state.selectedPDF ?? URL(fileURLWithPath: ""), examples: examples
        )
        if let overlapBox = boxes.first(where: { $0.tag?.role == CalibrationItem.overlapIndicator.rawValue }) {
            profile.overlapMarkerDescription = overlapBox.tag?.text
        }
        state.dlog("[calibration] profile covers roles: \(profile.roles.keys.sorted().joined(separator: ", "))", .info)
        return profile
    }

    private func deriveAndApply() {
        isDeriving = true
        deriveError = nil
        Task {
            do {
                let profile = try await buildProfile()
                state.dlog("[calibration] applying profile and re-parsing — check the lines above for how many blocks the profile actually overrode", .info)
                state.applyFormatProfile(profile)
                dismiss()
            } catch {
                state.dlog("[calibration] deriveAndApply failed — \(error.localizedDescription)", .error)
                deriveError = error.localizedDescription
            }
            isDeriving = false
        }
    }

    private func deriveAndSave() {
        isDeriving = true
        deriveError = nil
        Task {
            do {
                let profile = try await buildProfile()
                let item = FormatTemplateLibraryItem(
                    id: UUID(), name: newTemplateName.isEmpty ? "Untitled Template" : newTemplateName,
                    createdAt: Date(), originProjectName: state.script?.title ?? "Untitled",
                    profile: profile
                )
                try templateLibrary.save(item)
                state.dlog("[calibration] saved template \"\(item.name)\" and applying it — re-parsing…", .info)
                state.applyFormatProfile(profile)
                dismiss()
            } catch {
                state.dlog("[calibration] deriveAndSave failed — \(error.localizedDescription)", .error)
                deriveError = error.localizedDescription
            }
            isDeriving = false
        }
    }
}

// MARK: - CalibrationPrimerOverlay

/// Short primer shown automatically the moment the sheet opens, and
/// re-openable any time via the header's "i" button.
private struct CalibrationPrimerOverlay: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 16) {
                Text("Teach Table Read This Script's Layout")
                    .font(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Draw a box around one example of an element — drag directly on the page below.")
                    step(2, "Tap the matching label in the bar at the bottom to tag it. Table Read reads the real text under your box right then.")
                    step(3, "Move or resize a box any time — its tag clears automatically so it always matches what's actually inside it.")
                    step(4, "Once every item is tagged or excluded, hit Continue to Parse to re-parse the script with your corrections.")
                }

                HStack {
                    Spacer()
                    Button("Got it") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - FormatTemplateLibraryPickerView

struct FormatTemplateLibraryPickerView: View {
    @EnvironmentObject private var templateLibrary: FormatTemplateLibrary
    @Environment(\.dismiss) private var dismiss
    var onSelect: (FormatProfile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Format Template Library")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if templateLibrary.templates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No saved templates yet")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Templates you save from the calibration screen will appear here, labeled with the script they came from.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List {
                    ForEach(templateLibrary.templates) { item in
                        FormatTemplateRow(
                            item: item,
                            onUse: { onSelect(item.profile); dismiss() },
                            onDelete: { templateLibrary.delete(item.id) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 480, height: 420)
    }
}

private struct FormatTemplateRow: View {
    var item: FormatTemplateLibraryItem
    var onUse: () -> Void
    var onDelete: () -> Void

    private var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: item.createdAt)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.semibold))
                Text("From \(item.originProjectName) · \(dateText) · \(item.profile.roles.count) role\(item.profile.roles.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Use as Starting Point", action: onUse)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Use as Starting Point", action: onUse)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
