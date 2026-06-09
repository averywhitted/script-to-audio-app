import SwiftUI
import AppKit

// Stable hue per speaker name — shared by Review and Cast tabs.
private func speakerColor(_ speaker: String) -> Color {
    let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]
    let index = abs(speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palette.count
    return palette[index]
}

// MARK: - Import

struct ImportView: View {
    @EnvironmentObject private var state: AppState
    var openImporter: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Step 1: Import a Script PDF")
                    .font(.largeTitle.weight(.semibold))
                Text("Choose the PDF you want to turn into scene-by-scene audio. The app will parse it first, then guide you through review, voices, and generation.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            Button {
                openImporter()
            } label: {
                Label("Choose PDF", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if !state.recentScripts.isEmpty {
                RecentScriptsSection()
                    .frame(maxWidth: 680)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .padding(48)
        .onAppear { state.pruneStaleRecentScripts() }
    }
}

private struct RecentScriptsSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Scripts")
                    .font(.headline)
                Spacer()
                Button("Clear") { state.clearRecentScripts() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(state.recentScripts) { script in
                    Button {
                        state.importPDF(script.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(script.url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    if script.id != state.recentScripts.last?.id {
                        Divider().padding(.leading, 32)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Review

/// Shared selection state for the review element list.
/// Lives at ReviewView level so the floating toolbar can overlay the whole scroll area.
final class ReviewSelectionState: ObservableObject {
    @Published var sceneNumber: Int? = nil
    @Published var pdfPath: String = ""
    @Published var keys: Set<String> = []
    @Published var addedKeys: Set<UUID> = []

    var isEmpty: Bool { keys.isEmpty && addedKeys.isEmpty }

    func toggle(key: String, sceneNumber: Int, pdfPath: String) {
        if self.sceneNumber != sceneNumber || self.pdfPath != pdfPath {
            keys = []
            addedKeys = []
            self.sceneNumber = sceneNumber
            self.pdfPath = pdfPath
        }
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        if keys.isEmpty && addedKeys.isEmpty { self.sceneNumber = nil }
    }

    func toggleAdded(_ id: UUID, sceneNumber: Int, pdfPath: String) {
        if self.sceneNumber != sceneNumber || self.pdfPath != pdfPath {
            keys = []
            addedKeys = []
            self.sceneNumber = sceneNumber
            self.pdfPath = pdfPath
        }
        if addedKeys.contains(id) { addedKeys.remove(id) } else { addedKeys.insert(id) }
        if keys.isEmpty && addedKeys.isEmpty { self.sceneNumber = nil }
    }

    func clear() { keys = []; addedKeys = []; sceneNumber = nil; pdfPath = "" }
}

struct ReviewView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var selection = ReviewSelectionState()

    var body: some View {
        if let script = state.script {
            StepPageFooter(
                leading: "\(state.selectedScenes.count) of \(script.sceneCount) scenes selected",
                backAction: { state.goTo(.importScript) },
                primaryTitle: "Continue to Voices",
                primarySystemImage: "arrow.right.circle",
                primaryDisabled: state.selectedScenes.isEmpty,
                primaryAction: { state.goTo(.cast) }
            ) {
                VStack(spacing: 0) {
                    // Compact summary strip — stats are context, not the hero
                    HStack(spacing: 16) {
                        Label("\(script.sceneCount) scenes", systemImage: "film.stack")
                        Label("\(script.characterCount) characters", systemImage: "person.2")
                        Label("\(script.lineCount) lines", systemImage: "text.bubble")
                        Spacer()
                        // Background activity indicator (voice fetching, etc.)
                        if state.isFetchingVoices {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Loading voices…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }
                        Button("Select All") { state.selectAllScenes() }
                            .buttonStyle(.borderless)
                        Button("Select None") { state.clearSceneSelection() }
                            .buttonStyle(.borderless)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .animation(.easeInOut(duration: 0.2), value: state.isFetchingVoices)
                    Divider()
                    // Scene list — floating selection toolbar overlays the whole scroll area
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(script.scenes) { scene in
                                    SceneReviewRow(
                                        scene: scene,
                                        pdfPath: state.selectedPDF?.path ?? "",
                                        allSpeakers: script.characters.map(\.name),
                                        isSelected: state.selectedScenes.contains(scene.number)
                                    ) {
                                        state.toggleScene(scene)
                                    }
                                }
                            }
                            .padding(16)
                            // Extra bottom padding so last items clear the floating bar
                            .padding(.bottom, selection.isEmpty ? 0 : 64)
                        }
                        .environmentObject(selection)

                        if !selection.isEmpty,
                           let sceneNum = selection.sceneNumber,
                           let scene = script.scenes.first(where: { $0.number == sceneNum }) {
                            SelectionActionsBar(
                                selectedKeys: selection.keys,
                                selectedAddedIds: selection.addedKeys,
                                scene: scene,
                                pdfPath: selection.pdfPath,
                                allSpeakers: script.characters.map(\.name),
                                onClearSelection: { selection.clear() }
                            )
                            .environmentObject(state)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .top) {
                        if state.canUndo || state.canRedo {
                            UndoRedoBar()
                                .environmentObject(state)
                                .padding(.top, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: selection.isEmpty)
                    .animation(.snappy(duration: 0.2), value: state.canUndo || state.canRedo)
                }
            }
        } else {
            EmptyState(title: "No script loaded", message: "Open a PDF to review parsed scenes and characters.")
        }
    }
}

private struct SceneReviewRow: View {
    var scene: SceneSummary
    var pdfPath: String
    var allSpeakers: [String]
    var isSelected: Bool
    var toggle: () -> Void
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var selection: ReviewSelectionState
    @State private var expanded = false
    @State private var showAllLines = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var isHoveringTitle = false

    private var isMyScene: Bool { selection.sceneNumber == scene.number && selection.pdfPath == pdfPath }
    private func isElementSelected(_ key: String) -> Bool { isMyScene && selection.keys.contains(key) }
    private func toggleElement(_ key: String) { selection.toggle(key: key, sceneNumber: scene.number, pdfPath: pdfPath) }

    private static let initialLineLimit = 30

    private var effectiveTitle: String {
        state.effectiveSceneTitle(pdfPath: pdfPath, scene: scene)
    }

    // Unique speaking characters in scene order
    private var speakers: [String] {
        var seen = Set<String>()
        return scene.elements
            .filter { $0.kind == "dialog" }
            .compactMap(\.speaker)
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Text(String(format: "%02d", scene.number))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)

                Group {
                    if editingTitle {
                        HStack(spacing: 6) {
                            TextField("Scene title", text: $titleDraft)
                                .font(.callout.weight(.medium))
                                .textFieldStyle(.plain)
                                .onSubmit { commitTitle() }
                                .onExitCommand { editingTitle = false }
                            Button("Save") { commitTitle() }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                                .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(effectiveTitle)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                            Button("Edit") { beginEditingTitle() }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                                .buttonStyle(.plain)
                                .opacity(isHoveringTitle ? 1 : 0)
                        }
                        .onHover { isHoveringTitle = $0 }
                    }
                }

                Spacer()

                // Character chips — who speaks in this scene
                HStack(spacing: 4) {
                    ForEach(speakers.prefix(5), id: \.self) { speaker in
                        Text(speaker)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(speakerColor(speaker).opacity(0.15), in: Capsule())
                            .foregroundStyle(speakerColor(speaker))
                            .lineLimit(1)
                    }
                    if speakers.count > 5 {
                        Text("+\(speakers.count - 5)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("\(scene.elementCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 48, alignment: .trailing)

                Button {
                    withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)   // larger hit target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())

            if expanded {
                Divider().padding(.horizontal, 14)

                let limit = showAllLines ? Int.max : Self.initialLineLimit
                let merged = state.mergedElements(for: scene, pdfPath: pdfPath, limit: limit)
                let hiddenCount = scene.elements.count - min(scene.elements.count, limit)

                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(merged) { item in
                        switch item {
                        case .parsed(let element):
                            let eKey = String(element.text.prefix(60))
                            SceneElementRow(
                                element: element,
                                pdfPath: pdfPath,
                                sceneNumber: scene.number,
                                allSpeakers: allSpeakers,
                                isSelected: isElementSelected(eKey),
                                onToggleSelect: { toggleElement(eKey) }
                            ) {
                                state.addElement(
                                    afterTextKey: eKey,
                                    speaker: element.kind == "dialog" ? (element.speaker ?? "") : "",
                                    kind: "dialog",
                                    sceneNumber: scene.number,
                                    pdfPath: pdfPath
                                )
                            }
                        case .manualOverlap(let primary, let secondary):
                            let pKey = String(primary.text.prefix(60))
                            ManualOverlapRow(
                                primary: primary,
                                secondary: secondary,
                                pdfPath: pdfPath,
                                sceneNumber: scene.number,
                                allSpeakers: allSpeakers,
                                isSelected: isElementSelected(pKey),
                                onToggleSelect: { toggleElement(pKey) }
                            ) {
                                state.addElement(
                                    afterTextKey: String(secondary.text.prefix(60)),
                                    speaker: primary.kind == "dialog" ? (primary.speaker ?? "") : "",
                                    kind: "dialog",
                                    sceneNumber: scene.number,
                                    pdfPath: pdfPath
                                )
                            }
                        case .added(let addedEl):
                            AddedElementRow(
                                element: addedEl,
                                sceneNumber: scene.number,
                                pdfPath: pdfPath,
                                allSpeakers: allSpeakers,
                                isSelected: selection.addedKeys.contains(addedEl.id),
                                onToggleSelect: { selection.toggleAdded(addedEl.id, sceneNumber: scene.number, pdfPath: pdfPath) }
                            )
                        }
                    }

                    // Show-more / show-fewer toggle
                    if scene.elements.count > Self.initialLineLimit {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showAllLines.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showAllLines ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                Text(showAllLines
                                     ? "Show fewer lines"
                                     : "Show all \(scene.elements.count) lines (\(hiddenCount) more)")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        }
        .onChange(of: expanded) { _, isExpanded in
            if !isExpanded {
                showAllLines = false
                if isMyScene { selection.clear() }
            }
        }
    }

    private func beginEditingTitle() {
        titleDraft = effectiveTitle
        editingTitle = true
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.setSceneTitle(trimmed, pdfPath: pdfPath, sceneNumber: scene.number)
        editingTitle = false
    }
}

// MARK: - Cast

struct CastView: View {
    @EnvironmentObject private var state: AppState
    @State private var enginePanelWidth: CGFloat = 300

    var body: some View {
        StepPageFooter(
            leading: state.installedEngines.contains(state.selectedEngine)
                ? ""
                : "\(state.selectedEngine.title) — click Install on the right to set up",
            backAction: { state.goTo(.review) },
            primaryTitle: "Continue to Generate",
            primarySystemImage: "arrow.right.circle",
            primaryDisabled: !state.installedEngines.contains(state.selectedEngine),
            primaryAction: { state.goTo(.generate) }
        ) {
            HStack(spacing: 0) {
                // Left: voice assignment — the primary task
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Voice Assignment")
                            .font(.title3.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 14)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if state.selectedEngine == .openAI {
                                OpenAISetupPanel()
                                    .padding(.horizontal, 20)
                                    .padding(.top, 18)
                            }
                            VoiceAssignmentList()
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                                .padding(.bottom, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                ResizableDivider(width: $enginePanelWidth, range: 230...520)

                // Right: engine selection — prerequisite, but secondary UI
                EnginePickerSidebar()
                    .frame(width: enginePanelWidth)
            }
        }
    }
}

private struct OpenAISetupPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI Setup")
                .font(.headline)
            SecureField("API key", text: $state.openAIAPIKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Saved securely in Keychain and restored on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save Key") { state.saveOpenAIAPIKey() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct VoiceAssignmentList: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.isFetchingVoices {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Loading voices…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else if state.voices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if state.installedEngines.contains(state.selectedEngine) {
                    Text("No voices found for \(state.selectedEngine.title).")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("No voice engine installed yet.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Choose an engine on the right and click Install.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                CharacterVoiceRow(
                    name: "Narrator",
                    genderHint: nil,
                    characterKey: NARRATOR_KEY,
                    voices: state.voices,
                    assignment: $state.voiceAssignment
                )
                if let script = state.script {
                    ForEach(script.characters) { character in
                        Divider()
                        CharacterVoiceRow(
                            name: character.name,
                            genderHint: character.genderHint,
                            characterKey: character.name,
                            voices: state.voices,
                            assignment: $state.voiceAssignment
                        )
                    }
                }
            }
        }
    }
}

private struct CharacterVoiceRow: View {
    @EnvironmentObject private var state: AppState
    var name: String
    var genderHint: String?
    var characterKey: String
    var voices: [VoiceSummary]
    @Binding var assignment: [String: String]

    private var selectedVoiceId: String { assignment[characterKey] ?? "" }
    private var selectedVoice: VoiceSummary? { voices.first { $0.id == selectedVoiceId } }
    private var engineReady: Bool { state.installedEngines.contains(state.selectedEngine) }

    /// Resolved gender: user override → parser hint → "N" (neutral)
    private var effectiveGender: String {
        state.characterGenderOverrides[characterKey] ?? genderHint ?? "N"
    }

    private var maleVoices:   [VoiceSummary] { voices.filter { $0.gender == "M" } }
    private var femaleVoices: [VoiceSummary] { voices.filter { $0.gender == "F" } }
    private var otherVoices:  [VoiceSummary] { voices.filter { $0.gender != "M" && $0.gender != "F" } }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(speakerColor(name))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).foregroundStyle(speakerColor(name))
                genderPicker
            }

            Spacer()

            voicePicker

            // Preview button — only when engine is ready
            if engineReady {
                Button {
                    if let selectedVoice { state.toggleVoicePreview(selectedVoice) }
                } label: {
                    if state.preparingPreviewVoiceId == selectedVoiceId {
                        ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: state.previewingVoiceId == selectedVoiceId ? "stop.fill" : "play.fill")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderless)
                .help(selectedVoice.map { "Preview \($0.label)" } ?? "Choose a voice before previewing")
                .disabled(selectedVoice == nil || state.preparingPreviewVoiceId != nil || state.isGenerating)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 2)
    }

    private var genderPicker: some View {
        HStack(spacing: 0) {
            ForEach([("M", "Male"), ("F", "Female"), ("N", "Neutral")], id: \.0) { code, label in
                Button {
                    state.setCharacterGender(code, for: characterKey)
                } label: {
                    Text(label)
                        .font(.system(size: 10, weight: effectiveGender == code ? .semibold : .regular))
                        .foregroundStyle(effectiveGender == code ? speakerColor(name) : Color(nsColor: .secondaryLabelColor))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            effectiveGender == code
                                ? speakerColor(name).opacity(0.15)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
                .help(code == "N" ? "Neutral / unspecified — any voice" : (code == "M" ? "Male voice" : "Female voice"))
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .fixedSize()
    }

    private var voicePicker: some View {
        Menu {
            if !maleVoices.isEmpty {
                Section("Male") {
                    ForEach(maleVoices) { voice in
                        Button {
                            assignment[characterKey] = voice.id
                        } label: {
                            if voice.id == selectedVoiceId {
                                Label(voice.display, systemImage: "checkmark")
                            } else {
                                Text(voice.display)
                            }
                        }
                    }
                }
            }
            if !femaleVoices.isEmpty {
                Section("Female") {
                    ForEach(femaleVoices) { voice in
                        Button {
                            assignment[characterKey] = voice.id
                        } label: {
                            if voice.id == selectedVoiceId {
                                Label(voice.display, systemImage: "checkmark")
                            } else {
                                Text(voice.display)
                            }
                        }
                    }
                }
            }
            if !otherVoices.isEmpty {
                Section("Other") {
                    ForEach(otherVoices) { voice in
                        Button {
                            assignment[characterKey] = voice.id
                        } label: {
                            if voice.id == selectedVoiceId {
                                Label(voice.display, systemImage: "checkmark")
                            } else {
                                Text(voice.display)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedVoice?.label ?? "Choose voice")
                    .font(.callout)
                    .foregroundStyle(selectedVoice == nil ? .secondary : .primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

}

// MARK: - Engine picker sidebar

private struct EnginePickerSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voice Engine")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(EngineKind.allCases) { engine in
                        EngineListCard(
                            engine: engine,
                            selected: state.selectedEngine == engine,
                            installed: state.installedEngines.contains(engine),
                            status: state.engineStatuses[engine],
                            isInstalling: state.installingEngine == engine,
                            isUninstalling: state.uninstallingEngine == engine,
                            installLogLines: state.installingEngine == engine
                                ? state.installLog.suffix(4).map(\.text)
                                : [],
                            installAction: { state.chooseEngine(engine) },
                            uninstallAction: { state.uninstallEngine(engine) }
                        )
                        .onTapGesture { state.selectEngine(engine) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
        }
        .background(.bar)
    }
}

private struct EngineListCard: View {
    var engine: EngineKind
    var selected: Bool
    var installed: Bool
    var status: EngineStatus?
    var isInstalling: Bool
    var isUninstalling: Bool
    var installLogLines: [String] = []
    var installAction: () -> Void
    var uninstallAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header row: icon + name + status badge
            HStack(spacing: 10) {
                Image(systemName: engine.symbol)
                    .font(.callout)
                    .foregroundStyle(engine.isSupported ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(engine.isSupported ? .primary : .secondary)
                    Text(engine.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                statusBadge
            }

            // Size + action row
            HStack(spacing: 6) {
                Label(status?.sizeLabel ?? engine.defaultSizeLabel, systemImage: "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if installed, status?.canUninstall == true {
                    Button(role: .destructive, action: uninstallAction) {
                        Text("Uninstall").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isUninstalling || isInstalling)
                } else if engine.isSupported, !installed {
                    Button(action: installAction) {
                        Label(engine == .openAI ? "Set Up" : "Install",
                              systemImage: "arrow.down.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(isInstalling || isUninstalling)
                }
            }

            // Inline install log
            if isInstalling || isUninstalling {
                if !installLogLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(installLogLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .opacity(engine.isSupported ? 1 : 0.5)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isInstalling {
            Label("Installing", systemImage: "arrow.down.circle")
                .font(.caption2).foregroundStyle(.tint)
        } else if isUninstalling {
            Label("Removing", systemImage: "trash")
                .font(.caption2).foregroundStyle(.orange)
        } else if !engine.isSupported {
            Text("Coming soon")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
        } else if installed {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        }
    }
}

// MARK: - Generate

struct GenerateView: View {
    @EnvironmentObject private var state: AppState
    @State private var showLog = false
    @State private var secondsElapsed: Int = 0

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var engineReady: Bool { state.installedEngines.contains(state.selectedEngine) }
    private var canRender: Bool { !state.isGenerating && !state.selectedScenes.isEmpty && engineReady }

    // Total estimated seconds for all selected scenes
    private var totalEstimatedSeconds: Int {
        guard let script = state.script else { return 0 }
        return script.scenes
            .filter { state.selectedScenes.contains($0.number) }
            .reduce(0) { $0 + $1.estimatedSeconds(engine: state.selectedEngine) }
    }

    // Time remaining extrapolated from effective elapsed + progress (paused time excluded)
    private var estimatedRemainingSeconds: Int? {
        guard state.isGenerating, !state.isPaused,
              state.generationProgress > 0.04 else { return nil }
        let elapsed = Double(state.effectiveElapsedSeconds)
        let total = elapsed / state.generationProgress
        return max(0, Int(total - elapsed))
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.generationComplete {
                GenerationCompletePanel()
            } else {
                HStack(spacing: 0) {
                    SceneQueuePanel(engine: state.selectedEngine).frame(width: 260)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Order: confirm → output → estimate → progress → render (last)
                            statusStrip
                            outputCard
                            if state.selectedEngine == .openAI { openAICard }
                            if state.isGenerating || !state.generationLog.isEmpty { progressCard }
                            renderCard     // always last — final action after reviewing above
                        }
                        .padding(20)
                    }
                }
                Divider()
                HStack {
                    if state.isGenerating {
                        if state.isPaused {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Paused").font(.caption).foregroundStyle(.orange)
                        } else {
                            ProgressView().controlSize(.small)
                            Text(runningCaption).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button { state.goTo(.cast) } label: {
                            Label("Back to Voices", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Text(idleCaption).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isGenerating {
                        Button {
                            if state.isPaused { state.resumeGeneration() }
                            else { state.pauseGeneration() }
                        } label: {
                            Label(
                                state.isPaused ? "Resume" : "Pause",
                                systemImage: state.isPaused ? "play.circle" : "pause.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(state.isPaused ? .green : .orange)
                    }
                    Button(role: .cancel) { state.cancelGeneration() } label: {
                        Label("Cancel Render", systemImage: "xmark.circle")
                    }
                    .disabled(!state.isGenerating)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.bar)
            }
        }
        .onReceive(clock) { _ in
            guard state.isGenerating else { return }
            secondsElapsed = state.effectiveElapsedSeconds
        }
        .onChange(of: state.isGenerating) { _, generating in
            if !generating { secondsElapsed = 0 }
        }
    }

    // MARK: Output folder picker

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Output Folder"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            state.setOutputDirectory(url)
        }
    }

    // MARK: Status strip

    private var statusStrip: some View {
        HStack(spacing: 8) {
            Label(state.selectedEngine.title, systemImage: state.selectedEngine.symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(engineReady ? Color.green.opacity(0.1) : Color.orange.opacity(0.1), in: Capsule())
                .foregroundStyle(engineReady ? Color.green : Color.orange)

            Label("\(state.selectedScenes.count) scenes", systemImage: "film.stack")
                .font(.subheadline)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(.secondary)

            if totalEstimatedSeconds > 0 {
                Label("~\(formatSeconds(totalEstimatedSeconds)) estimated", systemImage: "clock")
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if engineReady && !state.selectedScenes.isEmpty {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.green)
            } else if !engineReady {
                Label("Engine not set up", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Output card

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output Folder")
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(state.outputDirectory?.abbreviatingWithTilde ?? "Next to the PDF (default)")
                    .font(.callout)
                    .foregroundStyle(state.outputDirectory == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { chooseOutputFolder() }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: OpenAI estimate card

    private var openAICard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenAI Request Estimate").font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { state.refreshOpenAIEstimate() }.font(.callout)
            }
            if let estimate = state.openAIEstimate {
                OpenAIEstimatePanel(estimate: estimate)
            } else {
                Text("Estimates help you gauge time and request quota before a long render.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Run Estimate") { state.refreshOpenAIEstimate() }.buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Progress card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.isPaused ? "Render Paused" : state.isGenerating ? "Rendering…" : "Render Progress")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(state.isPaused ? .orange : .primary)
                Spacer()
                if state.isGenerating && !state.isPaused { ProgressView().controlSize(.small) }
                if state.isPaused {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                ProgressView(value: state.generationProgress).progressViewStyle(.linear)
                Text("\(Int(state.generationProgress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            // Time elapsed / remaining
            if state.isGenerating {
                HStack(spacing: 12) {
                    if secondsElapsed > 0 {
                        Label("\(formatSeconds(secondsElapsed)) elapsed", systemImage: "timer")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let remaining = estimatedRemainingSeconds {
                        Label("~\(formatSeconds(remaining)) remaining", systemImage: "hourglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if state.isGenerating, let last = state.generationLog.last {
                Text(last.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            if !state.generationLog.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showLog.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showLog ? "chevron.up" : "chevron.down").font(.caption2)
                        Text(showLog ? "Hide Output Log" : "Show Output Log (\(state.generationLog.count) lines)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showLog {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            state.copyGenerationLogToClipboard()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(state.generationLog) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(logColor(for: line.style))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Render card — always last

    private var renderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    if let dir = state.outputDirectory {
                        NSWorkspace.shared.open(dir)
                    }
                } label: {
                    Label("Open Output Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.outputDirectory == nil)
                .help("Open the output folder in Finder.")

                Button { state.renderSelectedScenes() } label: {
                    Label("Render All \(state.selectedScenes.count) Scenes", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRender)
                .help("Renders every selected scene in order to the output folder.")
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Helpers

    private var runningCaption: String {
        let done = state.sceneProgress.values.filter { $0 >= 1.0 }.count
        return "\(done) of \(state.renderingSceneNumbers.count) scenes done"
    }

    private var idleCaption: String {
        let done = state.sceneProgress.values.filter { $0 >= 1.0 }.count
        if done > 0 { return "\(done) scene\(done == 1 ? "" : "s") rendered" }
        return "\(state.selectedScenes.count) scene\(state.selectedScenes.count == 1 ? "" : "s") queued"
    }

    private func logColor(for style: LogStyle) -> Color {
        switch style {
        case .info: .secondary; case .success: .green; case .warning: .orange; case .error: .red
        }
    }
}

// MARK: - Generation complete panel

private struct GenerationCompletePanel: View {
    @EnvironmentObject private var state: AppState

    private var outputDir: URL? { state.lastOutputDirectory }
    private var scenesRendered: Int { state.sceneProgress.values.filter { $0 >= 1.0 }.count }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                // Icon + headline
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 88, height: 88)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.green)
                    }
                    VStack(spacing: 6) {
                        Text("Render Complete")
                            .font(.largeTitle.weight(.semibold))
                        Text("\(scenesRendered) scene\(scenesRendered == 1 ? "" : "s") rendered successfully")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        if let dir = outputDir {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill").font(.caption).foregroundStyle(.secondary)
                                Text(dir.abbreviatingWithTilde)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }

                // Actions
                VStack(spacing: 10) {
                    if let dir = outputDir {
                        Button {
                            NSWorkspace.shared.open(dir)
                        } label: {
                            Label("Open Output in Finder", systemImage: "folder.fill")
                                .frame(minWidth: 260)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    HStack(spacing: 12) {
                        Button {
                            // Render again = stay on generate page, reset completion state
                            state.generationComplete = false
                        } label: {
                            Label("Render Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            state.resetForNewProject()
                        } label: {
                            Label("New Project", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }
            .padding(48)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SceneQueuePanel: View {
    @EnvironmentObject private var state: AppState
    var engine: EngineKind

    private var displayScenes: [SceneSummary] {
        guard let script = state.script else { return [] }
        let numbers: Set<Int> = state.renderingSceneNumbers.isEmpty
            ? state.selectedScenes
            : Set(state.renderingSceneNumbers)
        return script.scenes.filter { numbers.contains($0.number) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scene Queue").font(.headline)
                Spacer()
                Text(headerCaption).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayScenes) { scene in
                        SceneQueueRow(scene: scene,
                                      progress: state.sceneProgress[scene.number] ?? 0,
                                      isRendering: state.isGenerating,
                                      estimatedSeconds: scene.estimatedSeconds(engine: engine))
                        Divider().padding(.leading, 36)
                    }
                }
            }
            if !state.isGenerating && !state.sceneProgress.isEmpty {
                Divider()
                Button {
                    state.goTo(.review)
                } label: {
                    Label("Edit Scene Selection", systemImage: "pencil")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(10)
                .foregroundStyle(.secondary)
            }
        }
        .background(.bar)
    }

    private var headerCaption: String {
        if state.isGenerating {
            let done = state.sceneProgress.values.filter { $0 >= 1.0 }.count
            return "\(done)/\(state.renderingSceneNumbers.count)"
        }
        return "\(state.selectedScenes.count) queued"
    }
}

private struct SceneQueueRow: View {
    var scene: SceneSummary
    var progress: Double
    var isRendering: Bool
    var estimatedSeconds: Int = 0

    private var isDone:   Bool { progress >= 1.0 }
    private var isActive: Bool { progress > 0 && progress < 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                statusIcon.frame(width: 16, height: 16)
                Text(scene.title).font(.callout).lineLimit(2)
                    .foregroundStyle(isDone ? .secondary : .primary)
                Spacer(minLength: 0)
                if isDone {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if isActive {
                    Text("\(Int(progress * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                } else if isRendering {
                    Text("Queued").font(.caption2).foregroundStyle(.tertiary)
                } else if estimatedSeconds > 0 {
                    Text("~\(formatSeconds(estimatedSeconds))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if isActive {
                ProgressView(value: progress).progressViewStyle(.linear).padding(.leading, 24)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isDone {
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        } else if isActive {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "circle").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shared components

private struct ResizableDivider: View {
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>

    var body: some View {
        // NSViewRepresentable backing makes the cursor change reliable on macOS
        ResizeCursorHost()
            .frame(width: 8)
            .overlay(Divider())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                width = max(range.lowerBound, min(range.upperBound, width - value.translation.width))
            })
    }
}

private struct ResizeCursorHost: NSViewRepresentable {
    func makeNSView(context: Context) -> _ResizeCursorNSView { _ResizeCursorNSView() }
    func updateNSView(_ nsView: _ResizeCursorNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private class _ResizeCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

func formatSeconds(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60, s = seconds % 60
    return s == 0 ? "\(m)m" : "\(m)m \(s)s"
}

extension SceneSummary {
    func estimatedSeconds(engine: EngineKind) -> Int {
        let dialogLines = elements.filter { $0.kind == "dialog" }
        let wordCount = dialogLines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let wordsPerSecond: Double
        switch engine {
        case .kokoro: wordsPerSecond = 3.2
        case .openAI: wordsPerSecond = 4.0
        default:      wordsPerSecond = 2.8
        }
        return max(1, Int(Double(wordCount) / wordsPerSecond))
    }
}

extension URL {
    var abbreviatingWithTilde: String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct SceneElementRow: View {
    var element: SceneElementSummary
    var pdfPath: String
    var sceneNumber: Int
    var allSpeakers: [String]
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onAddLineBelow: (() -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false
    @State private var showingEdit = false
    @State private var showingEditLeft = false
    @State private var showingEditRight = false

    var body: some View {
        let correctionKey = ParserCorrection.key(
            pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
        let correction = state.corrections[correctionKey]
        let isRemoved = correction?.markedAsNoise == true
        let effectiveKind = correction?.correctedKind ?? element.kind
        // For parser overlaps, the visible cue may have been edited down to 1 voice.
        let rawOverlapCue: [String] = element.isOverlap ? (element.overlapCue ?? []) : []
        let displayCueForOverlap: [String] = correction?.correctedOverlapSpeakers ?? rawOverlapCue
        // Show two-panel layout only when ≥2 voices are still active.
        // removedVoiceIndex: 0 = left only, 1 = right only, 2 = both
        let isLeftVoiceRemoved  = correction?.removedVoiceIndex == 0 || correction?.removedVoiceIndex == 2
        let isRightVoiceRemoved = correction?.removedVoiceIndex == 1 || correction?.removedVoiceIndex == 2
        let showAsTwoPanel = rawOverlapCue.count >= 2
                          && displayCueForOverlap.count >= 2
                          && effectiveKind == "dialog"
        let displaySpeaker: String = {
            if let s = correction?.correctedSpeaker { return s.isEmpty ? "Narrator" : s }
            // Collapsed single-voice overlap: use the surviving voice name.
            if element.isOverlap, let os = correction?.correctedOverlapSpeakers, os.count == 1 {
                return os[0].isEmpty ? "Narrator" : os[0]
            }
            return element.displaySpeaker
        }()
        let displayText: String = {
            if let t = correction?.correctedText, !t.isEmpty { return t }
            // Collapsed single-voice overlap: use the surviving voice text.
            if element.isOverlap,
               let os = correction?.correctedOverlapSpeakers, os.count == 1,
               let ot = correction?.correctedOverlapTexts, !ot.isEmpty { return ot[0] }
            return element.text
        }()

        HStack(alignment: .top, spacing: 8) {
            // Checkbox
            Button {
                onToggleSelect?()
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)

            if showAsTwoPanel {
                // ── Two-panel layout for parser-detected overlap ──
                let displayCue   = displayCueForOverlap          // already computed above
                let rawCue       = rawOverlapCue                 // alias for clarity
                let overlapTexts = correction?.correctedOverlapTexts ?? element.overlapTexts
                let leftText  = overlapTexts?.indices.contains(0) == true ? overlapTexts![0] : displayText
                let rightText = overlapTexts?.indices.contains(1) == true ? overlapTexts![1] : displayText

                HStack(alignment: .top, spacing: 0) {
                    // Left panel — speaker A
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            let nameL = displayCue.indices.contains(0) ? displayCue[0] : rawCue[0]
                            Circle().fill(speakerColor(nameL)).frame(width: 7, height: 7).padding(.top, 1)
                            Text(nameL)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(nameL))
                                .strikethrough(isRemoved || isLeftVoiceRemoved)
                            if correction != nil && !isRemoved && !isLeftVoiceRemoved {
                                Circle().fill(speakerColor(nameL)).frame(width: 4, height: 4)
                                    .help("User correction applied")
                            }
                            if isHovered || showingEditLeft {
                                if isRemoved && correction?.isSplit == true {
                                    // Fully unlinked — offer Relink
                                    Button {
                                        state.relinkParserOverlap(element: element, sceneNumber: sceneNumber, pdfPath: pdfPath)
                                    } label: {
                                        Label("Relink", systemImage: "link")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Restore as simultaneous lines")
                                } else if isLeftVoiceRemoved {
                                    // This voice was soft-removed — show Restore
                                    Button {
                                        state.restoreOverlapVoice(element: element, voiceIndex: 0,
                                                                   sceneNumber: sceneNumber, pdfPath: pdfPath)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Restore this voice")
                                } else {
                                    Button { showingEditLeft = true } label: {
                                        Text("Edit")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(speakerColor(nameL))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(speakerColor(nameL).opacity(0.15), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showingEditLeft, arrowEdge: .top) {
                                        OverlapVoiceEditPopover(element: element, voiceIndex: 0,
                                            pdfPath: pdfPath, sceneNumber: sceneNumber, allSpeakers: allSpeakers)
                                            .environmentObject(state)
                                    }
                                    Button {
                                        state.markOverlapVoiceAsRemoved(element: element, voiceIndex: 0,
                                                                         sceneNumber: sceneNumber, pdfPath: pdfPath)
                                    } label: {
                                        Label("Remove", systemImage: "minus.circle")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.red.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove this voice")
                                    Button {
                                        state.splitParserOverlap(element: element, keepVoiceIndex: nil,
                                                                 sceneNumber: sceneNumber, pdfPath: pdfPath)
                                    } label: {
                                        Label("Unlink", systemImage: "link.badge.minus")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Split into two separate solo lines")
                                    if let addBelow = onAddLineBelow {
                                        Button(action: addBelow) {
                                            Label("Add line", systemImage: "plus.circle")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(.quaternary, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Insert a new line below this one")
                                    }
                                }
                            }
                        }
                        Text(leftText)
                            .font(.callout)
                            .foregroundStyle((isRemoved || isLeftVoiceRemoved) ? .tertiary : .primary)
                            .strikethrough(isRemoved || isLeftVoiceRemoved, color: .secondary)
                            .lineLimit((isRemoved || isLeftVoiceRemoved) ? 1 : nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .padding(.horizontal, 8)

                    // Right panel — speaker B
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            let nameR = displayCue.indices.contains(1) ? displayCue[1] : rawCue[1]
                            Circle().fill(speakerColor(nameR)).frame(width: 7, height: 7).padding(.top, 1)
                            Text(nameR)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(nameR))
                                .strikethrough(isRemoved || isRightVoiceRemoved)
                            if (isHovered || showingEditRight) && !isRemoved {
                                if isRightVoiceRemoved {
                                    // This voice was soft-removed — show Restore
                                    Button {
                                        state.restoreOverlapVoice(element: element, voiceIndex: 1,
                                                                   sceneNumber: sceneNumber, pdfPath: pdfPath)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Restore this voice")
                                } else {
                                    Button { showingEditRight = true } label: {
                                        Text("Edit")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(speakerColor(nameR))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(speakerColor(nameR).opacity(0.15), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showingEditRight, arrowEdge: .top) {
                                        OverlapVoiceEditPopover(element: element, voiceIndex: 1,
                                            pdfPath: pdfPath, sceneNumber: sceneNumber, allSpeakers: allSpeakers)
                                            .environmentObject(state)
                                    }
                                    Button {
                                        state.markOverlapVoiceAsRemoved(element: element, voiceIndex: 1,
                                                                         sceneNumber: sceneNumber, pdfPath: pdfPath)
                                    } label: {
                                        Label("Remove", systemImage: "minus.circle")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.red.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove this voice")
                                }
                            }
                        }
                        Text(rightText)
                            .font(.callout)
                            .foregroundStyle((isRemoved || isRightVoiceRemoved) ? .tertiary : .primary)
                            .strikethrough(isRemoved || isRightVoiceRemoved, color: .secondary)
                            .lineLimit((isRemoved || isRightVoiceRemoved) ? 1 : nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            } else {
                // ── Solo element layout ──
                Circle()
                    .fill(speakerColor(displaySpeaker))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                Image(systemName: element.kind == "dialog" ? "person.wave.2" : "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displaySpeaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerColor(displaySpeaker))
                            .strikethrough(isRemoved)
                        if correction != nil && !isRemoved {
                            Circle()
                                .fill(speakerColor(displaySpeaker))
                                .frame(width: 5, height: 5)
                                .help("User correction applied")
                        }
                        Button { showingEdit = true } label: {
                            Text("Edit")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(speakerColor(displaySpeaker))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(speakerColor(displaySpeaker).opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovered || showingEdit ? 1 : 0)
                        .popover(isPresented: $showingEdit, arrowEdge: .top) {
                            ElementCorrectionPopover(element: element, pdfPath: pdfPath,
                                sceneNumber: sceneNumber, allSpeakers: allSpeakers)
                                .environmentObject(state)
                        }
                        ElementRemoveRestoreButton(element: element, pdfPath: pdfPath,
                            sceneNumber: sceneNumber, isRemoved: isRemoved)
                            .opacity(isHovered ? 1 : 0)
                        if let addBelow = onAddLineBelow {
                            Button(action: addBelow) {
                                Label("Add line", systemImage: "plus.circle")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .opacity(isHovered ? 1 : 0)
                            .help("Insert a new line below this one")
                        }
                    }
                    Text(displayText)
                        .font(.callout)
                        .foregroundStyle(isRemoved ? .tertiary : .primary)
                        .strikethrough(isRemoved, color: .secondary)
                        .lineLimit(isRemoved ? 1 : 4)
                }
                Spacer()
            }
        }
        .opacity(isRemoved ? 0.45 : 1)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Shared remove/restore button for parsed elements

private struct ElementRemoveRestoreButton: View {
    var element: SceneElementSummary
    var pdfPath: String
    var sceneNumber: Int
    var isRemoved: Bool

    @EnvironmentObject private var state: AppState

    var body: some View {
        Button {
            let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
            let existing = state.corrections[k]
            if isRemoved {
                if let e = existing, e.correctedKind != nil || e.correctedSpeaker != nil || e.correctedText != nil || e.manualOverlapPartnerKey != nil {
                    state.saveCorrection(ParserCorrection(
                        textKey: e.textKey, pdfIdentifier: e.pdfIdentifier, sceneNumber: e.sceneNumber,
                        originalKind: e.originalKind, originalSpeaker: e.originalSpeaker,
                        correctedKind: e.correctedKind, correctedSpeaker: e.correctedSpeaker,
                        correctedText: e.correctedText, markedAsNoise: false,
                        timestamp: Date(), contributed: state.contributeCorrections,
                        manualOverlapPartnerKey: e.manualOverlapPartnerKey
                    ))
                } else {
                    state.deleteCorrection(pdfPath: pdfPath, sceneNumber: sceneNumber, textKey: element.text)
                }
            } else {
                state.saveCorrection(ParserCorrection(
                    textKey: element.text, pdfIdentifier: pdfPath, sceneNumber: sceneNumber,
                    originalKind: element.kind, originalSpeaker: element.speaker,
                    correctedKind: existing?.correctedKind, correctedSpeaker: existing?.correctedSpeaker,
                    correctedText: existing?.correctedText, markedAsNoise: true,
                    timestamp: Date(), contributed: state.contributeCorrections,
                    manualOverlapPartnerKey: nil  // removing clears any manual overlap link
                ))
            }
        } label: {
            Label(isRemoved ? "Restore" : "Remove",
                  systemImage: isRemoved ? "arrow.uturn.backward" : "minus.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isRemoved ? Color.secondary : Color.red)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((isRemoved ? Color.secondary : Color.red).opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(isRemoved ? "Restore this line" : "Mark line as removed (won't be voiced)")
    }
}

// MARK: - Manual overlap row

private struct ManualOverlapRow: View {
    var primary: SceneElementSummary
    var secondary: SceneElementSummary
    var pdfPath: String
    var sceneNumber: Int
    var allSpeakers: [String]
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onAddLineBelow: (() -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false
    @State private var showingEditPrimary = false
    @State private var showingEditSecondary = false

    var body: some View {
        let pk = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: primary.text)
        let sk = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: secondary.text)
        let pCorr = state.corrections[pk]
        let sCorr = state.corrections[sk]
        let pRemoved = pCorr?.markedAsNoise == true
        let sRemoved = sCorr?.markedAsNoise == true

        let pSpeaker = pCorr?.correctedSpeaker.map { $0.isEmpty ? "Narrator" : $0 } ?? primary.displaySpeaker
        let sSpeaker = sCorr?.correctedSpeaker.map { $0.isEmpty ? "Narrator" : $0 } ?? secondary.displaySpeaker
        let pText = pCorr?.correctedText ?? primary.text
        let sText = sCorr?.correctedText ?? secondary.text

        HStack(alignment: .top, spacing: 8) {
            // Checkbox
            Button { onToggleSelect?() } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)

            HStack(alignment: .top, spacing: 0) {
                // Left panel — primary speaker
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(speakerColor(pSpeaker)).frame(width: 7, height: 7).padding(.top, 1)
                        Text(pSpeaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerColor(pSpeaker))
                            .strikethrough(pRemoved)
                        if pCorr != nil && !pRemoved {
                            Circle().fill(speakerColor(pSpeaker)).frame(width: 4, height: 4)
                                .help("User correction applied")
                        }
                        if isHovered || showingEditPrimary {
                            Button { showingEditPrimary = true } label: {
                                Text("Edit")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(speakerColor(pSpeaker))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(speakerColor(pSpeaker).opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingEditPrimary, arrowEdge: .top) {
                                ElementCorrectionPopover(element: primary, pdfPath: pdfPath,
                                    sceneNumber: sceneNumber, allSpeakers: allSpeakers)
                                    .environmentObject(state)
                            }
                            Button {
                                removeSide(isPrimary: true, isCurrentlyRemoved: pRemoved, correction: pCorr)
                            } label: {
                                Label(pRemoved ? "Restore" : "Remove",
                                      systemImage: pRemoved ? "arrow.uturn.backward" : "minus.circle")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(pRemoved ? Color.secondary : Color.red)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background((pRemoved ? Color.secondary : Color.red).opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            Button {
                                state.breakSimultaneous(primaryText: primary.text, sceneNumber: sceneNumber, pdfPath: pdfPath)
                            } label: {
                                Label("Unlink", systemImage: "link.badge.minus")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Split into two separate lines")
                        }
                    }
                    Text(pText)
                        .font(.callout)
                        .foregroundStyle(pRemoved ? .tertiary : .primary)
                        .strikethrough(pRemoved, color: .secondary)
                        .lineLimit(pRemoved ? 1 : nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .padding(.horizontal, 8)

                // Right panel — secondary speaker
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(speakerColor(sSpeaker)).frame(width: 7, height: 7).padding(.top, 1)
                        Text(sSpeaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerColor(sSpeaker))
                            .strikethrough(sRemoved)
                        if sCorr != nil && !sRemoved {
                            Circle().fill(speakerColor(sSpeaker)).frame(width: 4, height: 4)
                                .help("User correction applied")
                        }
                        if isHovered || showingEditSecondary {
                            Button { showingEditSecondary = true } label: {
                                Text("Edit")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(speakerColor(sSpeaker))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(speakerColor(sSpeaker).opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingEditSecondary, arrowEdge: .top) {
                                ElementCorrectionPopover(element: secondary, pdfPath: pdfPath,
                                    sceneNumber: sceneNumber, allSpeakers: allSpeakers)
                                    .environmentObject(state)
                            }
                            Button {
                                removeSide(isPrimary: false, isCurrentlyRemoved: sRemoved, correction: sCorr)
                            } label: {
                                Label(sRemoved ? "Restore" : "Remove",
                                      systemImage: sRemoved ? "arrow.uturn.backward" : "minus.circle")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(sRemoved ? Color.secondary : Color.red)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background((sRemoved ? Color.secondary : Color.red).opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            if let addBelow = onAddLineBelow {
                                Button(action: addBelow) {
                                    Label("Add line", systemImage: "plus.circle")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Insert a new line below this pair")
                            }
                        }
                    }
                    Text(sText)
                        .font(.callout)
                        .foregroundStyle(sRemoved ? .tertiary : .primary)
                        .strikethrough(sRemoved, color: .secondary)
                        .lineLimit(sRemoved ? 1 : nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
    }

    private func removeSide(isPrimary: Bool, isCurrentlyRemoved: Bool, correction: ParserCorrection?) {
        let el = isPrimary ? primary : secondary
        if isCurrentlyRemoved {
            // Restore
            if let e = correction, e.correctedKind != nil || e.correctedSpeaker != nil || e.correctedText != nil {
                state.saveCorrection(ParserCorrection(
                    textKey: e.textKey, pdfIdentifier: e.pdfIdentifier, sceneNumber: e.sceneNumber,
                    originalKind: e.originalKind, originalSpeaker: e.originalSpeaker,
                    correctedKind: e.correctedKind, correctedSpeaker: e.correctedSpeaker,
                    correctedText: e.correctedText, markedAsNoise: false,
                    timestamp: Date(), contributed: state.contributeCorrections
                ))
            } else {
                state.deleteCorrection(pdfPath: pdfPath, sceneNumber: sceneNumber, textKey: el.text)
            }
        } else {
            // Mark as noise
            state.saveCorrection(ParserCorrection(
                textKey: el.text, pdfIdentifier: pdfPath, sceneNumber: sceneNumber,
                originalKind: el.kind, originalSpeaker: el.speaker,
                correctedKind: correction?.correctedKind, correctedSpeaker: correction?.correctedSpeaker,
                correctedText: correction?.correctedText, markedAsNoise: true,
                timestamp: Date(), contributed: state.contributeCorrections
            ))
            // If removing primary, also clear the link so secondary becomes solo
            if isPrimary {
                state.breakSimultaneous(primaryText: primary.text, sceneNumber: sceneNumber, pdfPath: pdfPath)
            }
            // If removing secondary, primary keeps its link; secondary shows as removed-within-overlap
        }
    }
}

// MARK: - Selection actions toolbar

private struct SelectionActionsBar: View {
    var selectedKeys: Set<String>
    var selectedAddedIds: Set<UUID>
    var scene: SceneSummary
    var pdfPath: String
    var allSpeakers: [String]
    var onClearSelection: () -> Void

    @EnvironmentObject private var state: AppState
    @State private var showingSpeakerPicker = false
    @State private var pickerSpeaker: String = ""

    private var selectedElements: [SceneElementSummary] {
        scene.elements.filter { selectedKeys.contains(String($0.text.prefix(60))) }
    }

    private var selectedAddedElements: [UserAddedElement] {
        let key = state.addedKey(pdfPath: pdfPath, sceneNumber: scene.number)
        return (state.userAddedElements[key] ?? []).filter { selectedAddedIds.contains($0.id) }
    }

    private var totalCount: Int { selectedKeys.count + selectedAddedIds.count }

    // Simultaneous only works for exactly 2 solo parsed dialog lines, no added elements mixed in.
    private var canMakeSimultaneous: Bool {
        guard selectedAddedIds.isEmpty, selectedKeys.count == 2 else { return false }
        let els = selectedElements.filter { el in
            let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: scene.number, text: el.text)
            let fix = state.corrections[k]
            // Use corrected kind so lines edited to/from dialog are handled correctly.
            let effectiveKind = fix?.correctedKind ?? el.kind
            guard effectiveKind == "dialog" else { return false }
            // Skip noise'd lines.
            guard fix?.markedAsNoise != true else { return false }
            // Skip active (2-voice) overlaps; collapsed single-voice overlaps are fine.
            let displayCue = fix?.correctedOverlapSpeakers ?? el.overlapCue ?? []
            return !(el.isOverlap && displayCue.count >= 2)
        }
        return els.count == 2
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(totalCount) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            // Remove
            Button {
                for el in selectedElements {
                    let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: scene.number, text: el.text)
                    let e = state.corrections[k]
                    state.saveCorrection(ParserCorrection(
                        textKey: el.text, pdfIdentifier: pdfPath, sceneNumber: scene.number,
                        originalKind: el.kind, originalSpeaker: el.speaker,
                        correctedKind: e?.correctedKind, correctedSpeaker: e?.correctedSpeaker,
                        correctedText: e?.correctedText, markedAsNoise: true,
                        timestamp: Date(), contributed: state.contributeCorrections
                    ))
                }
                for el in selectedAddedElements {
                    state.deleteAddedElement(id: el.id, sceneNumber: scene.number, pdfPath: pdfPath)
                }
                onClearSelection()
            } label: {
                Label("Remove", systemImage: "minus.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Mark selected lines as removed")

            // Make Simultaneous
            if canMakeSimultaneous {
                Button {
                    let pair = selectedElements.filter { $0.kind == "dialog" && !$0.isOverlap }
                    guard pair.count == 2 else { return }
                    // Document order: pair[0] comes first in scene.elements
                    state.makeSimultaneous(primaryText: pair[0].text, secondaryText: pair[1].text,
                                          sceneNumber: scene.number, pdfPath: pdfPath)
                    onClearSelection()
                } label: {
                    Label("Simultaneous", systemImage: "person.2.wave.2")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.purple.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Make selected lines play simultaneously")
            }

            // Change Speaker
            let dialogSelected = selectedElements.filter { $0.kind == "dialog" }
            let addedDialogSelected = selectedAddedElements.filter { $0.kind == "dialog" }
            if !dialogSelected.isEmpty || !addedDialogSelected.isEmpty {
                let totalDialogCount = dialogSelected.count + addedDialogSelected.count
                Button { showingSpeakerPicker = true } label: {
                    Label("Speaker", systemImage: "person.crop.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Reassign speaker for selected dialog lines")
                .popover(isPresented: $showingSpeakerPicker, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Change speaker").font(.headline)
                        Picker("Speaker", selection: $pickerSpeaker) {
                            ForEach(allSpeakers, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(minWidth: 160)
                        Button("Apply to \(totalDialogCount) line\(totalDialogCount == 1 ? "" : "s")") {
                            for el in dialogSelected {
                                let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: scene.number, text: el.text)
                                let e = state.corrections[k]
                                state.saveCorrection(ParserCorrection(
                                    textKey: el.text, pdfIdentifier: pdfPath, sceneNumber: scene.number,
                                    originalKind: el.kind, originalSpeaker: el.speaker,
                                    correctedKind: e?.correctedKind, correctedSpeaker: pickerSpeaker,
                                    correctedText: e?.correctedText, markedAsNoise: e?.markedAsNoise ?? false,
                                    timestamp: Date(), contributed: state.contributeCorrections,
                                    manualOverlapPartnerKey: e?.manualOverlapPartnerKey
                                ))
                            }
                            for el in addedDialogSelected {
                                state.updateAddedElement(id: el.id, speaker: pickerSpeaker,
                                    text: el.text, kind: el.kind,
                                    sceneNumber: scene.number, pdfPath: pdfPath)
                            }
                            showingSpeakerPicker = false
                            onClearSelection()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pickerSpeaker.isEmpty)
                    }
                    .padding()
                }
                .onAppear {
                    pickerSpeaker = allSpeakers.first ?? ""
                }
            }

            Spacer()

            Button(action: onClearSelection) {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear selection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Undo / Redo bar

private struct UndoRedoBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Button {
                state.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!state.canUndo)

            if state.undoStackCount > 0 {
                Text("\(state.undoStackCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14)
            }

            Button {
                state.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!state.canRedo)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
    }
}

// MARK: - User-added element row

private struct AddedElementRow: View {
    var element: UserAddedElement
    var sceneNumber: Int
    var pdfPath: String
    var allSpeakers: [String]
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false
    @State private var showingEdit = false

    private var displaySpeaker: String {
        element.speaker.isEmpty ? "Narrator" : element.speaker
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { onToggleSelect?() } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)

            // Dashed circle — visual cue that this line was user-added
            Circle()
                .strokeBorder(
                    speakerColor(displaySpeaker),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                )
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            Image(systemName: "plus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displaySpeaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(speakerColor(displaySpeaker))

                    Text("Added")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.65), in: Capsule())

                    // Edit pill
                    Button { showingEdit = true } label: {
                        Text("Edit")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(speakerColor(displaySpeaker))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(speakerColor(displaySpeaker).opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || showingEdit ? 1 : 0)
                    .popover(isPresented: $showingEdit, arrowEdge: .top) {
                        AddedElementEditPopover(
                            element: element,
                            pdfPath: pdfPath,
                            sceneNumber: sceneNumber,
                            allSpeakers: allSpeakers
                        )
                        .environmentObject(state)
                    }

                    // Delete button
                    Button {
                        withAnimation(.snappy(duration: 0.15)) {
                            state.deleteAddedElement(id: element.id, sceneNumber: sceneNumber, pdfPath: pdfPath)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .help("Remove this added line")
                }

                if element.text.isEmpty {
                    Text("Empty — hover and tap Edit to add text")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(element.text)
                        .font(.callout)
                        .lineLimit(4)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.leading, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(speakerColor(displaySpeaker).opacity(0.04))
        )
        .onHover { isHovered = $0 }
    }
}

private struct AddedElementEditPopover: View {
    var element: UserAddedElement
    var pdfPath: String
    var sceneNumber: Int
    var allSpeakers: [String]

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: String
    @State private var speakerText: String
    @State private var editedText: String

    private var kindOptions: [(String, String)] {
        [("dialog", "Dialog"), ("stage_direction", "Narration")]
    }

    private var speakerOptions: [String] {
        var opts = allSpeakers
        if !speakerText.isEmpty && speakerText != "Narrator" && !opts.contains(speakerText) {
            opts.insert(speakerText, at: 0)
        }
        return opts
    }

    init(element: UserAddedElement, pdfPath: String, sceneNumber: Int, allSpeakers: [String]) {
        self.element = element
        self.pdfPath = pdfPath
        self.sceneNumber = sceneNumber
        self.allSpeakers = allSpeakers
        _selectedKind = State(initialValue: element.kind)
        // Treat empty speaker as "Narrator" so the Picker always has a valid selection.
        _speakerText = State(initialValue: element.speaker.isEmpty ? "Narrator" : element.speaker)
        _editedText = State(initialValue: element.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit added line")
                .font(.headline)

            Divider()

            // Type
            VStack(alignment: .leading, spacing: 6) {
                Text("Type").font(.caption).foregroundStyle(.secondary)
                Picker("Type", selection: $selectedKind) {
                    ForEach(kindOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Speaker (dialog / aside only)
            if selectedKind != "stage_direction" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speaker").font(.caption).foregroundStyle(.secondary)
                    Picker("Speaker", selection: $speakerText) {
                        // "Narrator" is always the first option and is the valid
                        // tag for an empty-speaker line, ensuring SwiftUI never
                        // lands in an unmatched-tag state.
                        Text("Narrator").tag("Narrator")
                        ForEach(speakerOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 6) {
                Text("Text").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editedText)
                    .font(.callout)
                    .frame(minHeight: 64, maxHeight: 120)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .scrollContentBackground(.hidden)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                Button("Save") {
                    // stage_direction → always narrator (empty); "Narrator" picker
                    // option also maps to empty string so the backend treats it as narrator.
                    let speaker: String
                    if selectedKind == "stage_direction" || speakerText == "Narrator" {
                        speaker = ""
                    } else {
                        speaker = speakerText
                    }
                    state.updateAddedElement(
                        id: element.id,
                        speaker: speaker,
                        text: editedText,
                        kind: selectedKind,
                        sceneNumber: sceneNumber,
                        pdfPath: pdfPath
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Per-voice edit popover (parser-detected overlaps)

private struct OverlapVoiceEditPopover: View {
    var element: SceneElementSummary
    var voiceIndex: Int
    var pdfPath: String
    var sceneNumber: Int
    var allSpeakers: [String]

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var speakerText: String = ""
    @State private var editedText: String = ""

    private var correctionKey: String {
        ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
    }

    private var speakerOptions: [String] {
        var opts = allSpeakers
        if !speakerText.isEmpty && !opts.contains(speakerText) { opts.insert(speakerText, at: 0) }
        return opts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit line").font(.headline)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Speaker").font(.caption).foregroundStyle(.secondary)
                Picker("Speaker", selection: $speakerText) {
                    ForEach(speakerOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(minWidth: 160)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editedText)
                    .font(.callout)
                    .frame(minHeight: 72, maxHeight: 140)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .scrollContentBackground(.hidden)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.borderless)
                Spacer()
                Button("Save") { save(); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 280)
        .onAppear {
            let existing = state.corrections[correctionKey]
            let cue   = element.overlapCue ?? []
            let texts = element.overlapTexts ?? []
            speakerText = existing?.correctedOverlapSpeakers?.indices.contains(voiceIndex) == true
                ? existing!.correctedOverlapSpeakers![voiceIndex]
                : (cue.indices.contains(voiceIndex) ? cue[voiceIndex] : "")
            editedText = existing?.correctedOverlapTexts?.indices.contains(voiceIndex) == true
                ? existing!.correctedOverlapTexts![voiceIndex]
                : (texts.indices.contains(voiceIndex) ? texts[voiceIndex] : element.text)
        }
    }

    private func save() {
        let existing = state.corrections[correctionKey]
        let cue   = element.overlapCue ?? []
        let texts = element.overlapTexts ?? Array(repeating: element.text, count: cue.count)

        var newSpeakers = existing?.correctedOverlapSpeakers ?? cue
        while newSpeakers.count <= voiceIndex { newSpeakers.append("") }
        newSpeakers[voiceIndex] = speakerText

        var newTexts = existing?.correctedOverlapTexts ?? texts
        while newTexts.count <= voiceIndex { newTexts.append("") }
        newTexts[voiceIndex] = editedText

        state.saveCorrection(ParserCorrection(
            textKey: element.text, pdfIdentifier: pdfPath, sceneNumber: sceneNumber,
            originalKind: element.kind, originalSpeaker: element.speaker,
            correctedKind: existing?.correctedKind, correctedSpeaker: existing?.correctedSpeaker,
            correctedText: existing?.correctedText,
            correctedOverlapTexts: newTexts,
            correctedOverlapSpeakers: newSpeakers,
            markedAsNoise: existing?.markedAsNoise ?? false,
            timestamp: Date(), contributed: state.contributeCorrections,
            manualOverlapPartnerKey: existing?.manualOverlapPartnerKey
        ))
    }
}

private struct ElementCorrectionPopover: View {
    var element: SceneElementSummary
    var pdfPath: String
    var sceneNumber: Int
    var allSpeakers: [String]

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: String
    @State private var speakerText: String
    @State private var editedText: String
    @State private var editedOverlapText0: String  // first voice (hasSplitText only)
    @State private var editedOverlapText1: String  // second voice (hasSplitText only)
    @State private var markAsNoise: Bool

    init(element: SceneElementSummary, pdfPath: String, sceneNumber: Int, allSpeakers: [String]) {
        self.element = element
        self.pdfPath = pdfPath
        self.sceneNumber = sceneNumber
        self.allSpeakers = allSpeakers
        _selectedKind = State(initialValue: element.kind)
        _speakerText = State(initialValue: element.speaker ?? "")
        _editedText = State(initialValue: element.text)
        let ot = element.overlapTexts ?? []
        _editedOverlapText0 = State(initialValue: ot.indices.contains(0) ? ot[0] : "")
        _editedOverlapText1 = State(initialValue: ot.indices.contains(1) ? ot[1] : "")
        _markAsNoise = State(initialValue: false)   // populated from existing correction below
    }

    private var kindOptions: [(String, String)] {
        [("dialog", "Dialog"), ("stage_direction", "Narration")]
    }

    private var speakerOptions: [String] {
        var opts = allSpeakers
        if !speakerText.isEmpty && !opts.contains(speakerText) { opts.insert(speakerText, at: 0) }
        return opts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct this line")
                .font(.headline)

            Divider()

            // Type
            VStack(alignment: .leading, spacing: 6) {
                Text("Type").font(.caption).foregroundStyle(.secondary)
                Picker("Type", selection: $selectedKind) {
                    ForEach(kindOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Speaker (dialog only)
            if selectedKind == "dialog" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speaker").font(.caption).foregroundStyle(.secondary)
                    Picker("Speaker", selection: $speakerText) {
                        ForEach(speakerOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
            }

            // Text content — per-voice editors for split-text overlap, single editor otherwise
            if element.hasSplitText, let cue = element.overlapCue, cue.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lines (simultaneous)").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cue[0])
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(cue[0]))
                            TextEditor(text: $editedOverlapText0)
                                .font(.callout)
                                .frame(minHeight: 56, maxHeight: 100)
                                .padding(6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .scrollContentBackground(.hidden)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cue[1])
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(cue[1]))
                            TextEditor(text: $editedOverlapText1)
                                .font(.callout)
                                .frame(minHeight: 56, maxHeight: 100)
                                .padding(6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .scrollContentBackground(.hidden)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editedText)
                        .font(.callout)
                        .frame(minHeight: 64, maxHeight: 120)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .scrollContentBackground(.hidden)
                }
            }

            // Remove line
            Button {
                markAsNoise.toggle()
            } label: {
                Label(markAsNoise ? "Restore this line" : "Remove this line",
                      systemImage: markAsNoise ? "arrow.uturn.backward" : "minus.circle")
                    .font(.callout)
                    .foregroundStyle(markAsNoise ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)

            Divider()

            // Actions
            HStack {
                let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
                if state.corrections[k] != nil {
                    Button("Undo Changes") {
                        state.deleteCorrection(pdfPath: pdfPath, sceneNumber: sceneNumber, textKey: element.text)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                Button("Save") {
                    let origOT = element.overlapTexts ?? []
                    let newOT: [String]? = element.hasSplitText
                        ? [editedOverlapText0, editedOverlapText1]
                        : nil
                    let overlapChanged = element.hasSplitText && (
                        editedOverlapText0 != (origOT.indices.contains(0) ? origOT[0] : "")
                        || editedOverlapText1 != (origOT.indices.contains(1) ? origOT[1] : "")
                    )
                    let correction = ParserCorrection(
                        textKey: element.text,
                        pdfIdentifier: pdfPath,
                        sceneNumber: sceneNumber,
                        originalKind: element.kind,
                        originalSpeaker: element.speaker,
                        correctedKind: selectedKind != element.kind ? selectedKind : nil,
                        correctedSpeaker: selectedKind == "dialog" && speakerText != (element.speaker ?? "")
                            ? speakerText : nil,
                        correctedText: !element.hasSplitText && editedText != element.text ? editedText : nil,
                        correctedOverlapTexts: overlapChanged ? newOT : nil,
                        markedAsNoise: markAsNoise,
                        timestamp: Date(),
                        contributed: state.contributeCorrections
                    )
                    state.saveCorrection(correction)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
            }
        }
        .padding(16)
        .frame(width: element.hasSplitText ? 520 : 340)
        .onAppear {
            // Pre-populate from any existing correction for this element
            let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
            if let existing = state.corrections[k] {
                if let kind = existing.correctedKind { selectedKind = kind }
                if let speaker = existing.correctedSpeaker { speakerText = speaker }
                if let text = existing.correctedText { editedText = text }
                if let ot = existing.correctedOverlapTexts, ot.count >= 2 {
                    editedOverlapText0 = ot[0]
                    editedOverlapText1 = ot[1]
                }
                markAsNoise = existing.markedAsNoise
            }
        }
    }

    private var hasChanges: Bool {
        let origOT = element.overlapTexts ?? []
        let overlapChanged = element.hasSplitText && (
            editedOverlapText0 != (origOT.indices.contains(0) ? origOT[0] : "")
            || editedOverlapText1 != (origOT.indices.contains(1) ? origOT[1] : "")
        )
        return markAsNoise
            || selectedKind != element.kind
            || (selectedKind == "dialog" && speakerText != (element.speaker ?? ""))
            || (!element.hasSplitText && editedText != element.text)
            || overlapChanged
    }
}

private struct StepPageFooter<Content: View>: View {
    var leading: String
    var backAction: (() -> Void)? = nil
    var primaryTitle: String
    var primarySystemImage: String
    var primaryDisabled: Bool
    var primaryAction: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                if let back = backAction {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }
                Text(leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: primaryAction) {
                    Label(primaryTitle, systemImage: primarySystemImage)
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct SectionPanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct OpenAIEstimatePanel: View {
    var estimate: OpenAIEstimate

    var body: some View {
        HStack(spacing: 14) {
            MetricCard(value: estimate.requestCount, label: "Requests")
            MetricCard(value: estimate.requestsPerMinute, label: "RPM Limit")
            VStack(alignment: .leading, spacing: 4) {
                Text(estimate.durationText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Minimum time").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct MetricCard: View {
    var value: Int
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyState: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
