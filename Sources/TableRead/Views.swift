import SwiftUI
import AppKit

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
            Text("Recent Scripts")
                .font(.headline)
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

struct ReviewView: View {
    @EnvironmentObject private var state: AppState

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
                    // Scene list is the primary content
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
                    }
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
    @State private var expanded = false
    @State private var editingTitle = false
    @State private var titleDraft = ""

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
                        TextField("Scene title", text: $titleDraft)
                            .font(.callout.weight(.medium))
                            .textFieldStyle(.plain)
                            .onSubmit { commitTitle() }
                            .onExitCommand { editingTitle = false }
                    } else {
                        Text(effectiveTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                            .onTapGesture(count: 2) { beginEditingTitle() }
                            .help("Double-click to edit scene title")
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
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(scene.elements.prefix(80)) { element in
                        SceneElementRow(
                            element: element,
                            pdfPath: pdfPath,
                            sceneNumber: scene.number,
                            allSpeakers: allSpeakers
                        )
                    }
                    if scene.elements.count > 80 {
                        Text("\(scene.elements.count - 80) more lines…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private func speakerColor(_ speaker: String) -> Color {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]
        let index = abs(speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palette.count
        return palette[index]
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

    private var maleVoices:   [VoiceSummary] { voices.filter { $0.gender == "M" } }
    private var femaleVoices: [VoiceSummary] { voices.filter { $0.gender == "F" } }
    private var otherVoices:  [VoiceSummary] { voices.filter { $0.gender != "M" && $0.gender != "F" } }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(genderColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                if let hint = genderHint {
                    Text(hint == "M" ? "Male" : hint == "F" ? "Female" : "Unknown")
                        .font(.caption2).foregroundStyle(.secondary)
                }
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

    private var genderColor: Color {
        switch genderHint {
        case "M": return .blue
        case "F": return .pink
        default:  return .secondary
        }
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

    // Time remaining extrapolated from elapsed + progress
    private var estimatedRemainingSeconds: Int? {
        guard state.isGenerating,
              let start = state.renderStartTime,
              state.generationProgress > 0.04 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
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
                        ProgressView().controlSize(.small)
                        Text(runningCaption).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { state.goTo(.cast) } label: {
                            Label("Back to Voices", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Text(idleCaption).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
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
            guard state.isGenerating, let start = state.renderStartTime else { return }
            secondsElapsed = Int(Date().timeIntervalSince(start))
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
                Text(state.isGenerating ? "Rendering…" : "Render Progress").font(.title3.weight(.semibold))
                Spacer()
                if state.isGenerating { ProgressView().controlSize(.small) }
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
                Button { state.renderPreviewScene() } label: {
                    Label("Preview First Scene", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canRender)
                .help("Renders only the first selected scene — audition pacing and voice cast before the full run.")

                Button { state.renderSelectedScenes() } label: {
                    Label("Render All \(state.selectedScenes.count) Scenes", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRender)
                .help("Renders every selected scene in order to the output folder.")
            }

            Text("Use Preview to audition voice cast and pacing before committing to the full queue.")
                .font(.caption).foregroundStyle(.secondary)
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

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false
    @State private var showingEdit = false

    var body: some View {
        let correctionKey = ParserCorrection.key(
            pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
        let correction = state.corrections[correctionKey]
        let isRemoved = correction?.markedAsNoise == true

        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(speakerColor(element.displaySpeaker))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            Image(systemName: element.kind == "dialog" ? "person.wave.2" : "text.quote")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(element.displaySpeaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(speakerColor(element.displaySpeaker))
                        .strikethrough(isRemoved)
                    // Correction dot (non-noise corrections only)
                    if correction != nil && !isRemoved {
                        Circle()
                            .fill(speakerColor(element.displaySpeaker))
                            .frame(width: 5, height: 5)
                            .help("User correction applied")
                    }
                    // "Edit" pill — always in layout, fades on hover
                    Button { showingEdit = true } label: {
                        Text("Edit")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(speakerColor(element.displaySpeaker))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(speakerColor(element.displaySpeaker).opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || showingEdit ? 1 : 0)
                    .popover(isPresented: $showingEdit, arrowEdge: .top) {
                        ElementCorrectionPopover(
                            element: element,
                            pdfPath: pdfPath,
                            sceneNumber: sceneNumber,
                            allSpeakers: allSpeakers
                        )
                        .environmentObject(state)
                    }
                }
                Text(element.text)
                    .font(.callout)
                    .foregroundStyle(isRemoved ? .tertiary : .primary)
                    .strikethrough(isRemoved, color: .secondary)
                    .lineLimit(isRemoved ? 1 : 4)
            }
            Spacer()
        }
        .opacity(isRemoved ? 0.45 : 1)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
    }

    private func speakerColor(_ speaker: String) -> Color {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]
        let index = abs(speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palette.count
        return palette[index]
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
    @State private var markAsNoise: Bool

    init(element: SceneElementSummary, pdfPath: String, sceneNumber: Int, allSpeakers: [String]) {
        self.element = element
        self.pdfPath = pdfPath
        self.sceneNumber = sceneNumber
        self.allSpeakers = allSpeakers
        _selectedKind = State(initialValue: element.kind)
        _speakerText = State(initialValue: element.speaker ?? "")
        _editedText = State(initialValue: element.text)
        _markAsNoise = State(initialValue: false)   // populated from existing correction below
    }

    private var kindOptions: [(String, String)] {
        [("dialog", "Dialog"), ("stage_direction", "Narration"), ("parenthetical", "Aside")]
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
                    HStack {
                        TextField("Character name", text: $speakerText)
                            .textFieldStyle(.roundedBorder)
                        if !allSpeakers.isEmpty {
                            Menu {
                                ForEach(allSpeakers, id: \.self) { name in
                                    Button(name) { speakerText = name }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }

            // Text content
            VStack(alignment: .leading, spacing: 6) {
                Text("Text").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editedText)
                    .font(.callout)
                    .frame(minHeight: 64, maxHeight: 120)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .scrollContentBackground(.hidden)
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
                    let correction = ParserCorrection(
                        textKey: element.text,
                        pdfIdentifier: pdfPath,
                        sceneNumber: sceneNumber,
                        originalKind: element.kind,
                        originalSpeaker: element.speaker,
                        correctedKind: selectedKind != element.kind ? selectedKind : nil,
                        correctedSpeaker: selectedKind == "dialog" && speakerText != (element.speaker ?? "")
                            ? speakerText : nil,
                        correctedText: editedText != element.text ? editedText : nil,
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
        .frame(width: 340)
        .onAppear {
            // Pre-populate from any existing correction for this element
            let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: element.text)
            if let existing = state.corrections[k] {
                if let kind = existing.correctedKind { selectedKind = kind }
                if let speaker = existing.correctedSpeaker { speakerText = speaker }
                if let text = existing.correctedText { editedText = text }
                markAsNoise = existing.markedAsNoise
            }
        }
    }

    private var hasChanges: Bool {
        markAsNoise
            || selectedKind != element.kind
            || (selectedKind == "dialog" && speakerText != (element.speaker ?? ""))
            || editedText != element.text
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
