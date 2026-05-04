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
                    HStack {
                        Spacer()
                        Button {
                            state.goTo(.cast)
                        } label: {
                            Label("Continue to Voices", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.selectedScenes.isEmpty)
                    }
                }
                .padding(24)
            }
        } else {
            EmptyState(title: "No script loaded", message: "Open a PDF to review parsed scenes and characters.")
        }
    }
}

struct CastView: View {
    @EnvironmentObject private var state: AppState

    private let library = [
        VoiceLibraryItem(id: .macOS, installed: true, size: "Included", note: "Best default for reliability."),
        VoiceLibraryItem(id: .kokoro, installed: false, size: "~100-300 MB", note: "Recommended local neural add-on."),
        VoiceLibraryItem(id: .piper, installed: false, size: "~50-150 MB/voice", note: "Fast lightweight offline fallback."),
        VoiceLibraryItem(id: .openAI, installed: true, size: "Cloud", note: "Requires API key and preflight estimate."),
    ]

    var body: some View {
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
                                .onTapGesture {
                                    state.chooseEngine(engine)
                                }
                        }
                    }
                }

                SectionPanel("Voice Library") {
                    VStack(spacing: 10) {
                        ForEach(library) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.id.symbol)
                                    .frame(width: 28)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.id.title).font(.headline)
                                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.size).font(.caption).foregroundStyle(.secondary)
                                Button(item.installed ? "Ready" : "Download") {
                                    state.chooseEngine(item.id)
                                }
                                    .disabled(item.installed)
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        state.goTo(.generate)
                    } label: {
                        Label("Continue to Generate", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.installedEngines.contains(state.selectedEngine))
                }
            }
            .padding(24)
        }
    }
}

struct GenerateView: View {
    @EnvironmentObject private var state: AppState
    @State private var choosingOutput = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionPanel("Preflight") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("\(state.selectedScenes.count) scenes selected", systemImage: "checklist")
                            Spacer()
                            Button("Refresh Estimate") {
                                state.refreshOpenAIEstimate()
                            }
                        }
                        if state.selectedEngine == .openAI, let estimate = state.openAIEstimate {
                            OpenAIEstimatePanel(estimate: estimate)
                        } else if state.selectedEngine == .openAI {
                            Text("OpenAI needs an estimate before generation so users can see expected requests, minimum time, and quota risk.")
                                .foregroundStyle(.secondary)
                        } else if !state.installedEngines.contains(state.selectedEngine) {
                            Text("Download \(state.selectedEngine.title) from the Voice screen before generating.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Local/macOS engines do not use cloud request quota. Generation can still take time, but it should be predictable and private.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SectionPanel("Run Controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(outputFolderLabel, systemImage: "folder")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Output Folder") {
                                choosingOutput = true
                            }
                        }
                        HStack {
                            Button {
                                state.renderPreviewScene()
                            } label: {
                                Label("Render Preview Scene", systemImage: "play.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isGenerating || state.selectedScenes.isEmpty || !state.installedEngines.contains(state.selectedEngine))
                            Button {
                                state.renderSelectedScenes()
                            } label: {
                                Label("Render Selected Scenes", systemImage: "waveform.badge.play")
                            }
                            .disabled(state.isGenerating || state.selectedScenes.isEmpty || !state.installedEngines.contains(state.selectedEngine))
                            Button(role: .cancel) {
                                state.cancelGeneration()
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                            .disabled(!state.isGenerating)
                            if let output = state.lastOutputDirectory {
                                Button {
                                    NSWorkspace.shared.open(output)
                                } label: {
                                    Label("Open Output", systemImage: "folder.badge.gearshape")
                                }
                            }
                            Spacer()
                        }
                    }
                }

                SectionPanel("Progress") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if state.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            ProgressView(value: state.generationProgress)
                                .progressViewStyle(.linear)
                            Text("\(Int(state.generationProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                        if state.generationLog.isEmpty {
                            Text("No generation log yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("Output Log")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    state.copyGenerationLogToClipboard()
                                } label: {
                                    Label("Copy Log", systemImage: "doc.on.doc")
                                }
                                .disabled(state.generationLog.isEmpty)
                            }
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(state.generationLog) { line in
                                    Text(line.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(color(for: line.style))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(24)
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

    private var outputFolderLabel: String {
        if let output = state.outputDirectory {
            return output.path
        }
        return "Default output folder next to the PDF"
    }

    private func color(for style: LogStyle) -> Color {
        switch style {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
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
                    Text(defaultVoiceLabel)
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

    private var defaultVoiceLabel: String {
        element.displaySpeaker == "Narrator" ? "Narrator voice" : "Assigned voice"
    }

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
