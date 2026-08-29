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
        .frame(width: 900, height: 640)
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
        Task {
            defer { isAnalyzing = false }
            do {
                let region = try await state.bridge.analyzeRegion(pdf: pdf, page: box.page, rect: box.rect)
                guard let region else {
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
            } catch {
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
        var profile = try await state.bridge.deriveFormatProfile(
            pdf: state.selectedPDF ?? URL(fileURLWithPath: ""), examples: examples
        )
        if let overlapBox = boxes.first(where: { $0.tag?.role == CalibrationItem.overlapIndicator.rawValue }) {
            profile.overlapMarkerDescription = overlapBox.tag?.text
        }
        return profile
    }

    private func deriveAndApply() {
        isDeriving = true
        deriveError = nil
        Task {
            do {
                let profile = try await buildProfile()
                state.applyFormatProfile(profile)
                dismiss()
            } catch {
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
                state.applyFormatProfile(profile)
                dismiss()
            } catch {
                deriveError = error.localizedDescription
            }
            isDeriving = false
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
