import SwiftUI

/// The checklist items a user works through in the calibration sheet.
/// `overlapIndicator` is a client-only pseudo-role: it's never sent to the
/// backend's `_BTYPES` role vocabulary — the derived FormatProfile's
/// `overlapMarkerDescription` is instead filled in locally from whichever
/// sample block the user points at (metadata only in v1, not machine-applied
/// — see backend/parser.py's derive_format_profile docstring).
private enum CalibrationItem: String, CaseIterable, Identifiable {
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

    var hint: String {
        switch self {
        case .characterCue: "The speaker's name above their line"
        case .dialog: "What a character says"
        case .stageDirection: "Action / narration, not spoken"
        case .parenthetical: "A short aside like (beat) or (to Dana)"
        case .sceneHeading: "A scene or location marker"
        case .overlapIndicator: "How simultaneous dialog is marked"
        }
    }
}

// MARK: - FormatCalibrationSheet

struct FormatCalibrationSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var templateLibrary: FormatTemplateLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var blocks: [SampleBlock] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var tags: [Int: String] = [:]          // block.index -> CalibrationItem rawValue
    @State private var excludedItems: Set<String> = []    // CalibrationItem rawValues
    @State private var isDeriving = false
    @State private var deriveError: String?
    @State private var showLibraryPicker = false
    @State private var showSaveAs = false
    @State private var newTemplateName = ""

    private func taggedCount(_ item: CalibrationItem) -> Int {
        tags.values.filter { $0 == item.rawValue }.count
    }

    private func isResolved(_ item: CalibrationItem) -> Bool {
        excludedItems.contains(item.rawValue) || taggedCount(item) > 0
    }

    private var allResolved: Bool {
        CalibrationItem.allCases.allSatisfy(isResolved)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView("Reading sample pages…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                HStack(spacing: 0) {
                    blockList
                    Divider()
                    checklistPanel
                        .frame(width: 240)
                }
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 580)
        .task { await loadBlocks() }
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
            Text("Tag a few example lines below for each item on the right — remove any that don't apply to this script.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let deriveError {
                Text(deriveError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sample block list

    private var blockList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(blocks) { block in
                    SampleBlockRow(
                        block: block,
                        selection: Binding(
                            get: { tags[block.index] ?? "" },
                            set: { newValue in
                                if newValue.isEmpty { tags.removeValue(forKey: block.index) }
                                else { tags[block.index] = newValue }
                            }
                        )
                    )
                }
            }
            .padding(12)
        }
    }

    // MARK: - Checklist panel

    private var checklistPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Items to Identify")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                ForEach(CalibrationItem.allCases) { item in
                    ChecklistRow(
                        item: item,
                        count: taggedCount(item),
                        isExcluded: excludedItems.contains(item.rawValue),
                        onToggleExclude: {
                            if excludedItems.contains(item.rawValue) {
                                excludedItems.remove(item.rawValue)
                            } else {
                                excludedItems.insert(item.rawValue)
                            }
                        }
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(.regularMaterial)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(CalibrationItem.allCases.filter(isResolved).count) of \(CalibrationItem.allCases.count) resolved")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Save to Library As…") {
                newTemplateName = state.script?.title ?? "New Template"
                showSaveAs = true
            }
            .buttonStyle(.borderless)
            .disabled(!allResolved || isDeriving)
            Button("Continue to Parse") { deriveAndApply() }
                .buttonStyle(.borderedProminent)
                .disabled(!allResolved || isDeriving)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func loadBlocks() async {
        guard let pdf = state.selectedPDF else {
            loadError = "No script is open."
            isLoading = false
            return
        }
        do {
            let (_, sampleBlocks) = try await state.bridge.sampleBlocks(pdf: pdf)
            blocks = sampleBlocks
            if sampleBlocks.isEmpty {
                loadError = "Couldn't find any sample lines in this script."
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Builds a FormatProfile from the current tags, then patches in the
    /// client-only overlap marker description before returning it.
    private func buildProfile() async throws -> FormatProfile {
        let examples: [TaggedBlockExample] = blocks.compactMap { block in
            guard let role = tags[block.index], role != CalibrationItem.overlapIndicator.rawValue else { return nil }
            return TaggedBlockExample(role: role, block: block)
        }
        var profile = try await state.bridge.deriveFormatProfile(
            pdf: state.selectedPDF ?? URL(fileURLWithPath: ""), examples: examples
        )
        if let overlapIndex = tags.first(where: { $0.value == CalibrationItem.overlapIndicator.rawValue })?.key,
           let overlapBlock = blocks.first(where: { $0.index == overlapIndex }) {
            profile.overlapMarkerDescription = overlapBlock.text
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

// MARK: - SampleBlockRow

private struct SampleBlockRow: View {
    var block: SampleBlock
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.text.isEmpty ? "(blank)" : block.text)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text("p\(block.page + 1) · x=\(Int(block.x0))")
                    if block.isBold { badge("B") }
                    if block.isItalic { badge("I") }
                    if block.capsRatio >= 0.9 { badge("CAPS") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Picker("Role", selection: $selection) {
                Text("Not Tagged").tag("")
                ForEach(CalibrationItem.allCases) { item in
                    Text(item.label).tag(item.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            selection.isEmpty ? Color.clear : Color.accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
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

// MARK: - ChecklistRow

private struct ChecklistRow: View {
    var item: CalibrationItem
    var count: Int
    var isExcluded: Bool
    var onToggleExclude: () -> Void

    private var isResolved: Bool { isExcluded || count > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isResolved ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isResolved ? Color.green : Color.secondary)
                .font(.system(size: 15))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.callout.weight(.medium))
                    .strikethrough(isExcluded)
                    .foregroundStyle(isExcluded ? Color.secondary : Color.primary)
                Text(isExcluded ? "Not used in this script" : (count > 0 ? "\(count) example\(count == 1 ? "" : "s") tagged" : item.hint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onToggleExclude) {
                Image(systemName: isExcluded ? "arrow.uturn.backward.circle" : "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExcluded ? "This script does use this element" : "This script doesn't use this element")
        }
        .padding(.vertical, 4)
    }
}
