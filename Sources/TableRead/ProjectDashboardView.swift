import SwiftUI

// MARK: - ActiveElementInfo

struct ActiveElementInfo {
    var sceneNumber: Int
    var cueText: String
}

// MARK: - SidePanelTab

enum SidePanelTab: String, CaseIterable {
    case cast = "Cast"
    case render = "Render"
    case rehearse = "Rehearse"
    case log = "Log"
}

// MARK: - SceneTagKind

private enum SceneTagKind {
    case none, rendered, edited
}

// MARK: - ProjectDashboardView

struct ProjectDashboardView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var projectStore: ProjectStore
    @StateObject private var playerState = PlayerState()
    @State private var sidePanelTab: SidePanelTab = .cast

    var body: some View {
        VStack(spacing: 0) {
            DashboardTopBar()
            Divider()
            HSplitView {
                DashboardScriptArea()
                    .frame(minWidth: 450)
                SidePanelView(tab: $sidePanelTab)
                    .frame(minWidth: 240, maxWidth: 480)
            }
        }
        .environmentObject(playerState)
    }
}

// MARK: - DashboardTopBar

private struct DashboardTopBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var projectStore: ProjectStore
    @Environment(\.openSettings) private var openSettings
    @State private var showHomeConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if state.isGenerating {
                    showHomeConfirm = true
                } else {
                    returnToGallery()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to Projects")
            .confirmationDialog(
                "A render is in progress.",
                isPresented: $showHomeConfirm,
                titleVisibility: .visible
            ) {
                Button("Cancel Render & Go Home", role: .destructive) {
                    state.cancelGeneration()
                    returnToGallery()
                }
                Button("Keep Rendering", role: .cancel) {}
            }

            if let project = projectStore.currentProject {
                Text(project.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer()

            if state.availableUpdate != nil {
                Button {
                    NotificationCenter.default.post(name: .showUpdateSheet, object: nil)
                } label: {
                    Label("Update Available", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColors.updateAvailable)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().strokeBorder(AppColors.updateAvailable.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("A new version of Table Read is available")
                .transition(.scale.combined(with: .opacity))
            }

            Text("BETA")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.secondary.opacity(0.12), in: Capsule())

            Button {
                NotificationCenter.default.post(name: .showBugReport, object: nil)
            } label: {
                Label("Report a Bug", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.bugReport.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().strokeBorder(AppColors.bugReport.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Report a bug (⌘⇧B)")

            Button { openSettings() } label: {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func returnToGallery() {
        state.persistProjectIfNeeded()
        state.resetForNewProject()
        projectStore.currentProject = nil
    }
}

// MARK: - DashboardScriptArea

private struct DashboardScriptArea: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var playerState: PlayerState
    @StateObject private var selection = ReviewSelectionState()

    // Auto-scroll: track when we last scrolled programmatically vs when user scrolled.
    // If the user scrolled within the last 3 s, suppress auto-scroll so we don't fight them.
    @State private var lastAutoScrollTime: Date = .distantPast
    @State private var lastManualScrollTime: Date = .distantPast

    private var autoScrollPaused: Bool {
        Date().timeIntervalSince(lastManualScrollTime) < 3.0
    }

    private var activeSceneNumber: Int? {
        let idx = playerState.currentSceneIndex
        guard idx >= 0, idx < playerState.scenes.count else { return nil }
        return playerState.scenes[idx].sceneNumber
    }

    private var activeCueText: String? {
        let idx = playerState.currentCueIndex
        guard idx >= 0, idx < playerState.cues.count else { return nil }
        return playerState.cues[idx].text
    }

    // ID of the individual element row for fine-grained centering.
    // Matches the .id() applied to SceneElementRow inside SceneReviewRow.
    private var activeElementID: String? {
        guard let sceneNum = activeSceneNumber, let text = activeCueText else { return nil }
        return "el-\(sceneNum)-\(String(text.prefix(60)))"
    }

    private var activeInfo: ActiveElementInfo? {
        guard let sceneNum = activeSceneNumber, playerState.currentCueIndex >= 0 else { return nil }
        return ActiveElementInfo(sceneNumber: sceneNum, cueText: activeCueText ?? "")
    }

    var body: some View {
        if let script = state.script {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Label("\(script.sceneCount) scenes", systemImage: "film.stack")
                    Label("\(script.characterCount) characters", systemImage: "person.2")
                    Label("\(script.lineCount) lines", systemImage: "text.bubble")
                    Spacer()
                    if state.isFetchingVoices {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Loading voices…").font(.caption).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }
                    Button("Select All") { state.selectAllScenes() }.buttonStyle(.borderless)
                    Button("Select None") { state.clearSceneSelection() }.buttonStyle(.borderless)
                    Button("Skip Rendered") { state.selectMissingScenes() }
                        .buttonStyle(.borderless)
                        .help("Select only scenes that haven't been rendered yet")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .animation(.easeInOut(duration: 0.2), value: state.isFetchingVoices)

                Divider()

                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(script.scenes) { scene in
                                    SceneReviewRow(
                                        scene: scene,
                                        pdfPath: state.selectedPDF?.path ?? "",
                                        allSpeakers: ["Narrator"] + script.characters.map(\.name),
                                        isSelected: state.selectedScenes.contains(scene.number),
                                        activeInfo: activeInfo?.sceneNumber == scene.number ? activeInfo : nil,
                                        practiceRole: playerState.myRole,
                                        blockMyLines: playerState.blockMyLines,
                                        muteMyLines: playerState.muteMyLines
                                    ) {
                                        state.toggleScene(scene)
                                    }
                                    .id("scene-\(scene.number)")
                                    .opacity(activeSceneNumber != nil && activeSceneNumber != scene.number ? 0.55 : 1)
                                    .animation(.easeInOut(duration: 0.2), value: activeSceneNumber)
                                }
                            }
                            .padding(16)
                            .padding(.bottom, selection.isEmpty ? 0 : 64)
                        }
                        .environmentObject(selection)
                        .onManualScroll(lastAutoScrollTime: lastAutoScrollTime) {
                            lastManualScrollTime = Date()
                        }
                        .onChange(of: playerState.currentCueIndex) { _, _ in
                            guard !autoScrollPaused, let sceneNum = activeSceneNumber else { return }
                            lastAutoScrollTime = Date()
                            withAnimation(.spring(response: 0.3)) {
                                // Prefer scrolling to the element row for precise centering.
                                // Falls back to scene header if the scene isn't expanded yet.
                                if let elemID = activeElementID {
                                    proxy.scrollTo(elemID, anchor: .center)
                                } else {
                                    proxy.scrollTo("scene-\(sceneNum)", anchor: .center)
                                }
                            }
                        }
                    }

                    if !selection.isEmpty,
                       let sceneNum = selection.sceneNumber,
                       let scene = script.scenes.first(where: { $0.number == sceneNum }) {
                        SelectionActionsBar(
                            selectedKeys: selection.keys,
                            selectedAddedIds: selection.addedKeys,
                            scene: scene,
                            pdfPath: selection.pdfPath,
                            allSpeakers: ["Narrator"] + script.characters.map(\.name),
                            onClearSelection: { selection.clear() }
                        )
                        .environmentObject(state)
                        .padding(.horizontal, 24).padding(.bottom, 16)
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
        } else if state.isWorking {
            ParseLoadingView()
        } else {
            EmptyState(title: "No script loaded",
                       message: "Open a PDF to review parsed scenes and characters.")
        }
    }
}

// MARK: - ParseLoadingView

private struct ParseLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Parsing script\u{2026}")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SidePanelView

private struct SidePanelView: View {
    @Binding var tab: SidePanelTab
    @EnvironmentObject private var state: AppState

    private var hasLogAlerts: Bool {
        state.debugLog.contains { $0.style == .error || $0.style == .warning }
    }

    @ViewBuilder
    private func tabLabel(_ t: SidePanelTab) -> some View {
        if t == .log && hasLogAlerts && tab != .log {
            HStack(spacing: 3) {
                Text(t.rawValue)
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
        } else {
            Text(t.rawValue)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SidePanelTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        tabLabel(t)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(tab == t ? .semibold : .regular))
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        if tab == t {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .background(.bar)
            Divider()

            switch tab {
            case .cast:
                CastPanelView()
            case .render:
                RenderPanelView()
            case .rehearse:
                RehearsePanelView()
            case .log:
                DebugLogPanelView()
            }
        }
        .background(.regularMaterial)
    }
}

// MARK: - CastPanelView

private struct CastPanelView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Engine")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Engine", selection: $state.selectedEngine) {
                    ForEach(EngineKind.allCases) { engine in
                        HStack(spacing: 4) {
                            Image(systemName: engine.symbol)
                            Text(engine.title)
                        }.tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.bar)

            Divider()

            if !state.installedEngines.contains(state.selectedEngine) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("\(state.selectedEngine.title) not installed — go to Settings to set it up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.selectedEngine == .openAI {
                        OpenAISetupPanel()
                            .padding(.horizontal, 14).padding(.top, 14)
                    }
                    VoiceAssignmentList()
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            if state.voices.isEmpty { state.fetchVoices() }
        }
    }
}

// MARK: - RenderPanelView

private struct RenderPanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var showLog = false

    private var engineReady: Bool { state.installedEngines.contains(state.selectedEngine) }
    private var canRender: Bool { !state.isGenerating && !state.selectedScenes.isEmpty && engineReady }

    var body: some View {
        VStack(spacing: 0) {
            if !state.scenesNeedingRerender.isEmpty {
                Button {
                    state.selectedScenes = state.scenesNeedingRerender
                    state.renderSelectedScenes()
                } label: {
                    Label(
                        "Re-Render Edited Scenes (\(state.scenesNeedingRerender.count))",
                        systemImage: "arrow.clockwise.circle.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                .transition(.opacity)
            }

            ScrollView {
                if let script = state.script {
                    LazyVStack(spacing: 4) {
                        ForEach(script.scenes) { scene in
                            SceneRenderRow(scene: scene)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }

            Divider()

            HStack {
                Button("All Unrendered") { state.selectMissingScenes() }
                    .buttonStyle(.borderless).font(.caption)
                Button("Select All") { state.selectAllScenes() }
                    .buttonStyle(.borderless).font(.caption)
                Button("Clear") { state.clearSceneSelection() }
                    .buttonStyle(.borderless).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)

            Divider()

            VStack(spacing: 8) {
                if state.isGenerating {
                    ProgressView(value: state.generationProgress)
                        .padding(.horizontal, 4)
                    if let last = state.generationLog.last {
                        Text(last.text)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    DisclosureGroup("Show Log", isExpanded: $showLog) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(state.generationLog) { line in
                                    Text(line.text)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 180)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.caption)
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 8) {
                    if state.isGenerating {
                        Button { state.cancelGeneration() } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button {
                            if state.isPaused { state.resumeGeneration() }
                            else { state.pauseGeneration() }
                        } label: {
                            Label(
                                state.isPaused ? "Resume" : "Pause",
                                systemImage: state.isPaused ? "play.circle" : "pause.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(state.isPaused ? .green : .orange)
                    } else {
                        Button { state.renderSelectedScenes() } label: {
                            Label("Render \(state.selectedScenes.count) Scenes", systemImage: "waveform")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRender)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - SceneRenderRow

private struct SceneRenderRow: View {
    var scene: SceneSummary
    @EnvironmentObject private var state: AppState

    private var tagKind: SceneTagKind {
        if state.scenesNeedingRerender.contains(scene.number) { return .edited }
        if state.sceneFileInfo[scene.number]?.exists == true { return .rendered }
        return .none
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { state.toggleScene(scene) } label: {
                Image(systemName: state.selectedScenes.contains(scene.number)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(state.selectedScenes.contains(scene.number)
                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Scene %02d", scene.number))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(state.effectiveSceneTitle(pdfPath: state.selectedPDF?.path ?? "", scene: scene))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            switch tagKind {
            case .edited:
                Text("Edited")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            case .rendered:
                Text("Rendered")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            state.selectedScenes.contains(scene.number)
                ? Color.accentColor.opacity(0.06)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - RehearsePanelView

private struct RehearsePanelView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var playerState: PlayerState

    private var allCharacters: [String] {
        (state.script?.characters.map(\.name) ?? []).sorted()
    }

    var body: some View {
        if playerState.scenes.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "headphones")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No rendered scenes")
                    .font(.title3.weight(.semibold))
                Text("Render at least one scene to use the rehearsal player.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .onAppear {
                state.checkRenderedScenes()
                playerState.load(from: state)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Scene") {
                        Picker("Scene", selection: Binding(
                            get: { playerState.currentSceneIndex },
                            set: { playerState.switchToScene($0) }
                        )) {
                            ForEach(Array(playerState.scenes.enumerated()), id: \.element.id) { idx, scene in
                                Text("Scene \(scene.sceneNumber): \(scene.sceneTitle)").tag(idx)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    if !allCharacters.isEmpty {
                        LabeledContent("My Role") {
                            Picker("My Role", selection: $playerState.myRole) {
                                Text("Spectator").tag("")
                                Divider()
                                ForEach(allCharacters, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    Divider()

                    HStack(spacing: 20) {
                        Button { playerState.prevScene() } label: {
                            Image(systemName: "backward.end.fill").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(playerState.currentSceneIndex == 0
                            ? Color.secondary : Color.primary)
                        .disabled(playerState.currentSceneIndex == 0)
                        .help("Previous scene")

                        Button { playerState.prevLine() } label: {
                            Image(systemName: "arrow.left").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help("Previous line")

                        Button { playerState.togglePlayPause() } label: {
                            Image(systemName: playerState.isPlaying
                                  ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(playerState.isPlaying ? "Pause" : "Play")

                        Button { playerState.nextLine() } label: {
                            Image(systemName: "arrow.right").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help("Next line")

                        Button { playerState.nextScene() } label: {
                            Image(systemName: "forward.end.fill").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            playerState.currentSceneIndex >= playerState.scenes.count - 1
                                ? Color.secondary : Color.primary
                        )
                        .disabled(playerState.currentSceneIndex >= playerState.scenes.count - 1)
                        .help("Next scene")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Divider()

                    Toggle("Mute My Lines", isOn: $playerState.muteMyLines)
                        .disabled(playerState.myRole.isEmpty)
                        .help(playerState.myRole.isEmpty
                            ? "Select a role above to enable this"
                            : "Skip audio playback for your lines")
                    Toggle("Block My Lines", isOn: $playerState.blockMyLines)
                        .disabled(playerState.myRole.isEmpty)
                        .help(playerState.myRole.isEmpty
                            ? "Select a role above to enable this"
                            : "Replace your lines with underscores for memorization practice")

                    Divider()

                    LabeledContent("Speed") {
                        HStack(spacing: 6) {
                            Button { playerState.stepRate(by: -0.05) } label: {
                                Image(systemName: "minus")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(playerState.playbackRate <= 0.5)
                            .help("Slower (−0.05×)")

                            Slider(
                                value: Binding(
                                    get: { Double(playerState.playbackRate) },
                                    set: { playerState.setRate(Float($0)) }
                                ),
                                in: 0.5...2.0,
                                step: 0.05
                            )

                            Button { playerState.stepRate(by: 0.05) } label: {
                                Image(systemName: "plus")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(playerState.playbackRate >= 2.0)
                            .help("Faster (+0.05×)")

                            Text(String(format: "%.2f×", playerState.playbackRate))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .font(.callout)
            }
            .onAppear {
                state.checkRenderedScenes()
                playerState.load(from: state)
            }
            .onChange(of: state.sceneFileInfo) { _, _ in
                playerState.load(from: state)
            }
        }
    }
}

// MARK: - DebugLogPanelView

private struct DebugLogPanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var filterLevel: LogStyle? = nil
    @State private var scrollID: UUID?

    private var filtered: [DebugLogEntry] {
        guard let level = filterLevel else { return state.debugLog }
        return state.debugLog.filter { $0.style == level }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text("\(state.debugLog.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                filterButton("All", nil)
                filterButton("Err", .error)
                filterButton("Warn", .warning)
                filterButton("Py", .debug)
                Button {
                    let text = state.debugLog.map { "[\($0.timestampString)] \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy all log entries")
                Button {
                    state.debugLog.removeAll()
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear log")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()

            if state.debugLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard").font(.title2).foregroundStyle(.tertiary)
                    Text("No activity yet").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.timestampString)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 72, alignment: .leading)
                                    Text(entry.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(logColor(entry.style))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.debugLog.last?.id) { _, newID in
                        guard filterLevel == nil, let id = newID else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filterButton(_ label: String, _ level: LogStyle?) -> some View {
        Button(label) { filterLevel = filterLevel == level ? nil : level }
            .font(.caption2.weight(filterLevel == level ? .semibold : .regular))
            .foregroundStyle(filterLevel == level ? Color.accentColor : Color.secondary)
            .buttonStyle(.plain)
    }

    private func logColor(_ style: LogStyle) -> Color {
        switch style {
        case .error:   return .red
        case .warning: return .orange
        case .success: return .green
        case .info:    return Color(nsColor: .labelColor)
        case .debug:   return .secondary
        }
    }
}

// MARK: - Helpers

private extension View {
    /// Detects user-initiated scrolling and calls `action`. No-ops on macOS 14 (graceful
    /// degradation: auto-scroll simply always fires on that OS).
    @ViewBuilder
    func onManualScroll(lastAutoScrollTime: Date, action: @escaping () -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollGeometryChange(for: Double.self) { geo in
                geo.contentOffset.y
            } action: { old, new in
                guard abs(new - old) > 1.0 else { return }
                // Ignore scroll changes that are part of our own animation (within 0.8 s buffer)
                if Date().timeIntervalSince(lastAutoScrollTime) > 0.8 {
                    action()
                }
            }
        } else {
            self
        }
    }
}
