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
                Text("Start with a script PDF")
                    .font(.largeTitle.weight(.semibold))
                Text("The native shell keeps parsing, casting, preflight estimates, and generation jobs explicit before any long-running work starts.")
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
                        LazyVStack(spacing: 8) {
                            ForEach(script.scenes) { scene in
                                SceneRow(scene: scene, isSelected: state.selectedScenes.contains(scene.number)) {
                                    state.toggleScene(scene)
                                }
                            }
                        }
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
                            EngineCard(engine: engine, selected: state.selectedEngine == engine)
                                .onTapGesture {
                                    state.selectedEngine = engine
                                    state.refreshOpenAIEstimate()
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
                                Button(item.installed ? "Ready" : "Download") {}
                                    .disabled(item.installed)
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct GenerateView: View {
    @EnvironmentObject private var state: AppState

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
                        } else {
                            Text("Local/macOS engines do not use cloud request quota. Generation can still take time, but it should be predictable and private.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SectionPanel("Run Controls") {
                    HStack {
                        Button {
                        } label: {
                            Label("Render Preview Scene", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                        } label: {
                            Label("Render Selected Scenes", systemImage: "waveform.badge.play")
                        }
                        Button(role: .cancel) {
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        Spacer()
                    }
                }
            }
            .padding(24)
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

private struct SceneRow: View {
    var scene: SceneSummary
    var isSelected: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("\(scene.number)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title).foregroundStyle(.primary)
                    Text("\(scene.elementCount) voice chunks before batching")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct EngineCard: View {
    var engine: EngineKind
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: engine.symbol).font(.title3)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
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
