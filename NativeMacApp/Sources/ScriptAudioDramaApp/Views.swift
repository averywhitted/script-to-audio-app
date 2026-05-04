import SwiftUI

struct ImportView: View {
    var openImporter: () -> Void

    var body: some View {
        VStack(spacing: 26) {
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
            Spacer()
        }
        .padding(48)
    }
}

struct ReviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let script = state.script {
            StepPageFooter(
                leading: "\(state.selectedScenes.count) of \(script.sceneCount) scenes selected",
                primaryTitle: "Continue to Voices",
                primarySystemImage: "arrow.right.circle",
                primaryDisabled: state.selectedScenes.isEmpty,
                primaryAction: { state.goTo(.cast) }
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        MetricRow(script: script)
                        SectionPanel("Scenes") {
                            HStack {
                                Text("Select the scenes to include, then expand any scene to inspect parsed lines.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Select All") { state.selectAllScenes() }
                                Button("Select None") { state.clearSceneSelection() }
                            }
                            LazyVStack(spacing: 8) {
                                ForEach(script.scenes) { scene in
                                    ExpandableSceneRow(scene: scene, isSelected: state.selectedScenes.contains(scene.number), engine: state.selectedEngine) {
                                        state.toggleScene(scene)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        } else {
            EmptyState(title: "No script loaded", message: "Open a PDF to review parsed scenes and characters.")
        }
    }
}

struct CastView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        StepPageFooter(
            leading: state.installedEngines.contains(state.selectedEngine) ? "\(state.selectedEngine.title) ready" : "\(state.selectedEngine.title) needs download",
            primaryTitle: "Continue to Generate",
            primarySystemImage: "arrow.right.circle",
            primaryDisabled: !state.installedEngines.contains(state.selectedEngine),
            primaryAction: { state.goTo(.generate) }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    SectionPanel("Voice Engine") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                            ForEach(EngineKind.allCases) { engine in
                                EngineCard(
                                    engine: engine,
                                    selected: state.selectedEngine == engine,
                                    installed: state.installedEngines.contains(engine)
                                )
                                .onTapGesture { state.chooseEngine(engine) }
                            }
                        }
                    }

                    if state.selectedEngine == .openAI {
                        SectionPanel("OpenAI Setup") {
                            VStack(alignment: .leading, spacing: 10) {
                                SecureField("API key", text: $state.openAIAPIKey)
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Text("Key is saved securely in Keychain and restored on next launch.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Save Key") { state.saveOpenAIAPIKey() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }

                    VoiceAssignmentSection()

                }
                .padding(24)
            }
        }
    }
}

private struct VoiceAssignmentSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SectionPanel("Voice Assignment") {
            if state.isFetchingVoices {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading voices…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if state.voices.isEmpty {
                Text("Select and install a voice engine above to assign voices.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(spacing: 0) {
                    // Narrator always first
                    CharacterVoiceRow(
                        name: "Narrator",
                        genderHint: nil,
                        characterKey: NARRATOR_KEY,
                        voices: state.voices,
                        assignment: $state.voiceAssignment
                    )
                    if let script = state.script {
                        ForEach(script.characters) { character in
                            Divider().padding(.leading, 36)
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
}

private struct CharacterVoiceRow: View {
    var name: String
    var genderHint: String?
    var characterKey: String
    var voices: [VoiceSummary]
    @Binding var assignment: [String: String]

    private var selectedVoiceId: String { assignment[characterKey] ?? "" }

    private var selectedVoice: VoiceSummary? {
        voices.first { $0.id == selectedVoiceId }
    }

    private var maleVoices:   [VoiceSummary] { voices.filter { $0.gender == "M" } }
    private var femaleVoices: [VoiceSummary] { voices.filter { $0.gender == "F" } }
    private var otherVoices:  [VoiceSummary] { voices.filter { $0.gender != "M" && $0.gender != "F" } }

    var body: some View {
        HStack(spacing: 12) {
            // Gender indicator dot
            Circle()
                .fill(genderColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                if let hint = genderHint {
                    Text(hint == "M" ? "Male" : hint == "F" ? "Female" : "Unknown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Voice picker menu
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
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
    }

    private var genderColor: Color {
        switch genderHint {
        case "M": return .blue
        case "F": return .pink
        default:  return .secondary
        }
    }
}

struct GenerateView: View {
    @EnvironmentObject private var state: AppState
    @State private var choosingOutput = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Two-column layout: scene list left, controls+log right ──
            HStack(spacing: 0) {
                // Left: scene queue
                SceneQueuePanel()
                    .frame(width: 260)
                Divider()
                // Right: controls + log
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        preflightSection
                        outputSection
                        progressSection
                    }
                    .padding(24)
                }
            }
            Divider()
            GenerateFooter()
        }
        .fileImporter(
            isPresented: $choosingOutput,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.setOutputDirectory(url)
            }
        }
    }

    // MARK: - Sections

    private var preflightSection: some View {
        SectionPanel("Preflight") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("\(state.selectedScenes.count) scenes selected", systemImage: "checklist")
                    Spacer()
                    if state.selectedEngine == .openAI {
                        Button("Refresh Estimate") { state.refreshOpenAIEstimate() }
                    }
                }
                if state.selectedEngine == .openAI, let estimate = state.openAIEstimate {
                    OpenAIEstimatePanel(estimate: estimate)
                } else if state.selectedEngine == .openAI {
                    Text("Run a preflight estimate to see expected requests, time, and quota risk before generating.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if !state.installedEngines.contains(state.selectedEngine) {
                    Label("Download \(state.selectedEngine.title) in the Voices step first.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else {
                    Label("Ready. Local engine, no cloud quota.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        }
    }

    private var outputSection: some View {
        SectionPanel("Output") {
            HStack {
                Label(outputFolderLabel, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { choosingOutput = true }
            }
            if let output = state.lastOutputDirectory {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Last output: \(output.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(output) }
                        .font(.caption)
                }
                .padding(.top, 4)
            }
        }
    }

    private var progressSection: some View {
        SectionPanel("Progress") {
            VStack(alignment: .leading, spacing: 12) {
                // Overall bar
                HStack(spacing: 10) {
                    if state.isGenerating {
                        ProgressView().controlSize(.small)
                    }
                    ProgressView(value: state.generationProgress)
                        .progressViewStyle(.linear)
                    Text("\(Int(state.generationProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                // Log
                if !state.generationLog.isEmpty {
                    HStack {
                        Text("Output Log")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            state.copyGenerationLogToClipboard()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.generationLog) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(logColor(for: line.style))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if !state.isGenerating {
                    Text("Hit Render to start. Log output will appear here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Helpers

    private var outputFolderLabel: String {
        state.outputDirectory?.path ?? "Default: next to the PDF"
    }

    private func logColor(for style: LogStyle) -> Color {
        switch style {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct SceneQueuePanel: View {
    @EnvironmentObject private var state: AppState

    /// Scenes to show: rendering list if active, otherwise the selection from Review.
    private var displayScenes: [SceneSummary] {
        guard let script = state.script else { return [] }
        let numbers: Set<Int> = state.renderingSceneNumbers.isEmpty
            ? state.selectedScenes
            : Set(state.renderingSceneNumbers)
        return script.scenes.filter { numbers.contains($0.number) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Scenes")
                    .font(.headline)
                Spacer()
                Text(headerCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            // Scene rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayScenes) { scene in
                        SceneQueueRow(scene: scene,
                                      progress: state.sceneProgress[scene.number] ?? 0,
                                      isRendering: state.isGenerating)
                        Divider().padding(.leading, 36)
                    }
                }
            }
        }
        .background(.bar)
    }

    private var headerCaption: String {
        if state.isGenerating {
            let done = state.sceneProgress.values.filter { $0 >= 1.0 }.count
            return "\(done)/\(state.renderingSceneNumbers.count)"
        }
        return "\(state.selectedScenes.count) selected"
    }
}

private struct SceneQueueRow: View {
    var scene: SceneSummary
    var progress: Double   // 0.0–1.0
    var isRendering: Bool

    private var isDone:   Bool { progress >= 1.0 }
    private var isActive: Bool { progress > 0 && progress < 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 16)

                Text(scene.title)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(isDone ? .secondary : .primary)

                Spacer(minLength: 0)

                // Status badge
                if isDone {
                    Text("Done")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else if isActive {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tint)
                } else if isRendering {
                    Text("Queued")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // Progress bar (active scenes only)
            if isActive {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if isActive {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct GenerateFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack {
            Text(footerCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.renderPreviewScene()
            } label: {
                Label("Render Preview", systemImage: "play.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(actionsDisabled)
            Button {
                state.renderSelectedScenes()
            } label: {
                Label("Render All Selected", systemImage: "waveform.badge.play")
            }
            .disabled(actionsDisabled)
            Button(role: .cancel) {
                state.cancelGeneration()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(!state.isGenerating)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var actionsDisabled: Bool {
        state.isGenerating
            || state.selectedScenes.isEmpty
            || !state.installedEngines.contains(state.selectedEngine)
    }

    private var footerCaption: String {
        if state.isGenerating {
            let done = state.sceneProgress.values.filter { $0 >= 1.0 }.count
            return "Rendering… \(done) of \(state.renderingSceneNumbers.count) done"
        }
        return "\(state.selectedScenes.count) scenes selected"
    }
}

private struct MetricRow: View {
    var script: ScriptSummary

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(value: script.sceneCount, label: "Scenes")
            MetricCard(value: script.characterCount, label: "Characters")
            MetricCard(value: script.lineCount, label: "Lines")
        }
    }
}

private struct StepPageFooter<Content: View>: View {
    var leading: String
    var primaryTitle: String
    var primarySystemImage: String
    var primaryDisabled: Bool
    var primaryAction: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
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
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
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

private struct ExpandableSceneRow: View {
    var scene: SceneSummary
    var isSelected: Bool
    var engine: EngineKind
    var toggle: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text("\(scene.number)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title).foregroundStyle(.primary)
                    Text("\(scene.elementCount) parsed lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(scene.elements.prefix(80)) { element in
                        SceneElementRow(element: element, engine: engine)
                    }
                    if scene.elements.count > 80 {
                        Text("\(scene.elements.count - 80) more lines hidden for performance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 34)
                    }
                }
                .padding(.leading, 34)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SceneElementRow: View {
    var element: SceneElementSummary
    var engine: EngineKind

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(for: element.displaySpeaker))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            Image(systemName: element.kind == "dialog" ? "person.wave.2" : "text.quote")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(element.displaySpeaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: element.displaySpeaker))
                    Label(engine.title, systemImage: engine.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(element.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // Voice label removed — assignment isn't known until Cast step


    private func color(for speaker: String) -> Color {
        let colors: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]
        let index = abs(speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % colors.count
        return colors[index]
    }
}

private struct EngineCard: View {
    var engine: EngineKind
    var selected: Bool
    var installed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: engine.symbol).font(.title3)
                Spacer()
                Label(installed ? "Ready" : "Download", systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(installed ? .green : .orange)
            }
            Text(engine.title).font(.headline)
            Text(engine.detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
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
