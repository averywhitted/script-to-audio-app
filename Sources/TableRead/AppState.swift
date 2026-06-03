import Foundation
import Security
import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

@MainActor
final class AppState: ObservableObject {
    @Published var step: WorkflowStep = .importScript
    @Published var navigatingForward = true
    @Published var selectedPDF: URL?
    @Published var script: ScriptSummary?
    @Published var selectedEngine: EngineKind = .macOS
    @Published var installedEngines: Set<EngineKind> = [.macOS]
    @Published var engineStatuses: [EngineKind: EngineStatus] = [:]
    @Published var pendingDownload: EngineDownloadPrompt?
    @Published var isDownloadingEngine = false
    @Published var openAIAPIKey = ""
    // True when an OpenAI key exists in Keychain — checked via UserDefaults flag,
    // so we never touch Keychain at launch or when Settings opens.
    @Published var hasStoredOpenAIKey: Bool = UserDefaults.standard.bool(forKey: "openAIKeyStored")
    @Published var selectedScenes: Set<Int> = []
    @Published var openAIEstimate: OpenAIEstimate?
    @Published var isWorking = false
    @Published var isGenerating = false
    @Published var generationProgress = 0.0
    @Published var generationLog: [GenerationLogLine] = []
    @Published var outputDirectory: URL?
    @Published var lastOutputDirectory: URL?
    @Published var status = "Choose a PDF script to begin."
    @Published var errorMessage: String?
    @Published var recentScripts: [RecentScript] = []

    // Voice assignment
    @Published var voices: [VoiceSummary] = []
    @Published var voiceAssignment: [String: String] = [:]   // char name → voice id
    @Published var isFetchingVoices = false

    // Engine installation
    @Published var installLog: [GenerationLogLine] = []
    @Published var installingEngine: EngineKind? = nil
    @Published var uninstallingEngine: EngineKind? = nil
    @Published var previewingVoiceId: String?
    @Published var preparingPreviewVoiceId: String?
    @Published var renderStartTime: Date?

    // Per-scene generation progress
    @Published var renderingSceneNumbers: [Int] = []          // ordered list of scene numbers being rendered
    @Published var sceneProgress: [Int: Double] = [:]         // scene number → 0.0–1.0

    // Render completion
    @Published var generationComplete = false

    // Pause state
    @Published var isPaused = false
    private var pauseStartTime: Date?
    private var totalPausedSeconds: Double = 0

    // Settings — persisted via UserDefaults
    @Published var autoOpenFinderAfterRender: Bool = UserDefaults.standard.bool(forKey: "autoOpenFinderAfterRender") {
        didSet { UserDefaults.standard.set(autoOpenFinderAfterRender, forKey: "autoOpenFinderAfterRender") }
    }
    @Published var contributeCorrections: Bool = UserDefaults.standard.bool(forKey: "contributeCorrections") {
        didSet { UserDefaults.standard.set(contributeCorrections, forKey: "contributeCorrections") }
    }

    // Notification settings — persisted via UserDefaults
    @Published var notifyOnSceneComplete: Bool = UserDefaults.standard.bool(forKey: "notifyOnSceneComplete") {
        didSet {
            UserDefaults.standard.set(notifyOnSceneComplete, forKey: "notifyOnSceneComplete")
            if notifyOnSceneComplete { requestNotificationPermission() }
        }
    }
    @Published var notifyOnRenderComplete: Bool = UserDefaults.standard.bool(forKey: "notifyOnRenderComplete") {
        didSet {
            UserDefaults.standard.set(notifyOnRenderComplete, forKey: "notifyOnRenderComplete")
            if notifyOnRenderComplete { requestNotificationPermission() }
        }
    }
    @Published var notifyOnRenderFailed: Bool = UserDefaults.standard.bool(forKey: "notifyOnRenderFailed") {
        didSet {
            UserDefaults.standard.set(notifyOnRenderFailed, forKey: "notifyOnRenderFailed")
            if notifyOnRenderFailed { requestNotificationPermission() }
        }
    }

    // User-added elements — keyed by "\(pdfPath)|\(sceneNumber)"
    @Published var userAddedElements: [String: [UserAddedElement]] = [:]

    // Parser corrections — keyed by ParserCorrection.key(...)
    @Published var corrections: [String: ParserCorrection] = [:]
    // Scene title overrides — pdfPath → sceneNumber → custom title
    @Published var sceneTitleOverrides: [String: [Int: String]] = [:]

    #if os(macOS)
    let bridge = PythonBridge()
    private var previewSound: NSSound?
    #endif

    var sceneList: [SceneSummary] { script?.scenes ?? [] }

    init() {
        // Restore last output directory (path only — no file I/O at launch)
        if let savedPath = UserDefaults.standard.string(forKey: "lastOutputDirectory") {
            outputDirectory = URL(fileURLWithPath: savedPath)
        }
        // Load recent scripts without touching the filesystem at launch
        recentScripts = Self.loadRecentScripts()
        corrections = Self.loadCorrections()
        sceneTitleOverrides = Self.loadSceneTitleOverrides()
        userAddedElements = Self.loadUserAddedElements()
        // Mark OpenAI as installed based on UserDefaults flag — no Keychain touch at launch
        if UserDefaults.standard.bool(forKey: "openAIKeyStored") {
            installedEngines.insert(.openAI)
        }
        Task {
            await refreshEngineStatus()
        }
        // Upload any corrections that didn't make it out last session.
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s after launch
            await self?.uploadPendingCorrections()
        }
    }

    // MARK: - Navigation

    func canNavigate(to target: WorkflowStep) -> Bool {
        switch target {
        case .importScript:
            true
        case .review:
            script != nil
        case .cast:
            script != nil
        case .generate:
            script != nil && installedEngines.contains(selectedEngine)
        }
    }

    func goTo(_ target: WorkflowStep) {
        guard canNavigate(to: target) else { return }
        let steps = WorkflowStep.allCases
        let currentIdx = steps.firstIndex(of: step) ?? 0
        let targetIdx  = steps.firstIndex(of: target) ?? 0
        navigatingForward = targetIdx >= currentIdx
        step = target   // ZStack.animation() in ContentView drives the transition
        if target == .cast && voices.isEmpty {
            fetchVoices()
        }
    }

    // MARK: - Import

    func importPDF(_ url: URL) {
        selectedPDF = url
        outputDirectory = nil   // reset so the new script defaults to "next to the PDF"
        isWorking = true
        status = "Parsing script..."
        errorMessage = nil

        Task {
            do {
                #if os(macOS)
                let parsed = try await bridge.parse(pdf: url)
                script = parsed
                rememberRecentScript(url, title: parsed.title)
                selectedScenes = Set(parsed.scenes.map(\.number))
                navigatingForward = true
                step = .review
                let correctionCount = corrections.values.filter { $0.pdfIdentifier == url.path }.count
                let suffix = correctionCount > 0 ? ", \(correctionCount) correction\(correctionCount == 1 ? "" : "s") applied" : ""
                status = "\(parsed.sceneCount) scenes, \(parsed.characterCount) characters\(suffix)."
                #else
                throw NSError(domain: "TableRead", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "PDF parsing not yet available on iOS."])
                #endif
            } catch {
                errorMessage = error.localizedDescription
                status = "Parsing failed."
            }
            isWorking = false
        }
    }

    // MARK: - Voice fetching

    func fetchVoices() {
        guard let pdf = selectedPDF else { return }
        isFetchingVoices = true
        let engine = selectedEngine
        Task {
            do {
                #if os(macOS)
                let (list, autoAssign) = try await bridge.voices(engine: engine, pdf: pdf)
                voices = list
                for (char, voiceId) in autoAssign {
                    voiceAssignment[char] = voiceId
                }
                status = "\(list.count) voices available for \(engine.title)."
                #else
                voices = []
                status = "Voice loading not yet available on iOS."
                #endif
            } catch {
                errorMessage = error.localizedDescription
                status = "Could not load voices."
            }
            isFetchingVoices = false
        }
    }

    // MARK: - OpenAI estimate

    func refreshOpenAIEstimate() {
        guard selectedEngine == .openAI, let pdf = selectedPDF else {
            openAIEstimate = nil
            return
        }
        isWorking = true
        status = "Estimating OpenAI request count..."
        Task {
            do {
                #if os(macOS)
                openAIEstimate = try await bridge.estimateOpenAI(
                    pdf: pdf,
                    sceneNumbers: Array(selectedScenes).sorted()
                )
                if let estimate = openAIEstimate {
                    status = "\(estimate.requestCount) requests, about \(estimate.durationText) minimum."
                }
                #else
                status = "Estimation not yet available on iOS."
                #endif
            } catch {
                errorMessage = error.localizedDescription
                status = "Estimate failed."
            }
            isWorking = false
        }
    }

    // MARK: - Scene selection

    func toggleScene(_ scene: SceneSummary) {
        if selectedScenes.contains(scene.number) {
            selectedScenes.remove(scene.number)
        } else {
            selectedScenes.insert(scene.number)
        }
        refreshOpenAIEstimate()
    }

    func selectAllScenes() {
        selectedScenes = Set(sceneList.map(\.number))
        refreshOpenAIEstimate()
    }

    func clearSceneSelection() {
        selectedScenes = []
        refreshOpenAIEstimate()
    }

    // MARK: - Engine selection

    /// Select an engine card without triggering install — used by card tap.
    func selectEngine(_ engine: EngineKind) {
        guard engine.isSupported else { return }
        selectedEngine = engine
        voices = []
        voiceAssignment = [:]
        if installedEngines.contains(engine) {
            fetchVoices()
            refreshOpenAIEstimate()
        } else if engine == .openAI {
            status = "Enter your OpenAI API key to use cloud voices."
        } else {
            status = "Click Install to set up \(engine.title)."
        }
    }

    /// Select an engine and start install if needed — used by the Install button.
    func chooseEngine(_ engine: EngineKind) {
        selectedEngine = engine
        voices = []
        voiceAssignment = [:]
        if installedEngines.contains(engine) {
            fetchVoices()
            refreshOpenAIEstimate()
        } else if engine == .openAI {
            status = "Enter your OpenAI API key to use cloud voices."
        } else if engine.isSupported {
            startEngineInstall(engine)
        } else {
            status = "\(engine.title) is coming soon."
            selectedEngine = .macOS
            fetchVoices()
        }
    }

    func downloadPendingEngine() {
        guard let engine = pendingDownload?.engine else { return }
        pendingDownload = nil

        if engine == .openAI {
            status = "Enter an OpenAI API key to use OpenAI TTS."
            return
        }

        if !engine.isSupported {
            selectedEngine = .macOS
            voices = []
            voiceAssignment = [:]
            errorMessage = "\(engine.title) is coming soon and isn't available in this version. Switched back to macOS Voices."
            status = "\(engine.title) not yet available."
            fetchVoices()
            return
        }

        // Supported local engines: stream pip install, then mark ready.
        startEngineInstall(engine)
    }

    func saveOpenAIAPIKey() {
        let trimmed = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            installedEngines.remove(.openAI)
            hasStoredOpenAIKey = false
            UserDefaults.standard.removeObject(forKey: "openAIKeyStored")
            KeychainHelper.delete(key: "openai_api_key")
            openAIAPIKey = ""
            status = "OpenAI API key cleared."
            return
        }
        openAIAPIKey = trimmed
        installedEngines.insert(.openAI)
        hasStoredOpenAIKey = true
        UserDefaults.standard.set(true, forKey: "openAIKeyStored")
        KeychainHelper.write(key: "openai_api_key", value: trimmed)
        status = "OpenAI TTS is ready for estimates."
        fetchVoices()
        refreshOpenAIEstimate()
    }

    // MARK: - Engine installation

    func startEngineInstall(_ engine: EngineKind) {
        installingEngine = engine
        installLog = []
        status = "Installing \(engine.title)…"

        Task {
            do {
                #if os(macOS)
                try await bridge.installEngine(engine) { [weak self] event in
                    self?.handleInstallEvent(event)
                }
                installedEngines.insert(engine)
                await refreshEngineStatus()
                status = "\(engine.title) ready. The neural model downloads on first voice preview."
                fetchVoices()
                #else
                status = "Engine installation not available on iOS."
                #endif
            } catch {
                appendInstallLog("Installation failed: \(error.localizedDescription)", .error)
                errorMessage = "Could not install \(engine.title). Check the log for details."
                status = "Installation failed."
                selectedEngine = .macOS
            }
            installingEngine = nil
        }
    }

    func refreshEngineStatus() async {
        #if os(macOS)
        do {
            var statuses = try await bridge.engineStatus()
            if installedEngines.contains(.openAI) {
                statuses[.openAI] = EngineStatus(
                    installed: true,
                    sizeBytes: 0,
                    sizeLabel: "Cloud service",
                    canUninstall: false
                )
            }
            engineStatuses = statuses
            var installed: Set<EngineKind> = [.macOS]
            for (engine, status) in statuses where status.installed {
                installed.insert(engine)
            }
            if hasStoredOpenAIKey {
                installed.insert(.openAI)
            }
            installedEngines = installed
        } catch {
            // Keep the current UI state if the worker cannot answer yet.
        }
        #endif
    }

    func uninstallEngine(_ engine: EngineKind) {
        guard engine != .macOS, engine != .openAI else { return }
        uninstallingEngine = engine
        status = "Removing \(engine.title)…"
        Task {
            do {
                #if os(macOS)
                try await bridge.uninstallEngine(engine)
                installedEngines.remove(engine)
                if selectedEngine == engine {
                    selectedEngine = .macOS
                    voices = []
                    voiceAssignment = [:]
                    fetchVoices()
                }
                await refreshEngineStatus()
                status = "\(engine.title) removed."
                #endif
            } catch {
                errorMessage = error.localizedDescription
                status = "Uninstall failed."
            }
            uninstallingEngine = nil
        }
    }

    func toggleVoicePreview(_ voice: VoiceSummary) {
        #if os(macOS)
        if previewingVoiceId == voice.id {
            previewSound?.stop()
            previewSound = nil
            previewingVoiceId = nil
            return
        }

        previewSound?.stop()
        previewSound = nil
        preparingPreviewVoiceId = voice.id
        status = "Preparing \(voice.label) preview…"

        let engine = selectedEngine
        Task {
            do {
                if engine == .openAI && openAIAPIKey.isEmpty {
                    openAIAPIKey = KeychainHelper.read(key: "openai_api_key") ?? ""
                }
                let url = try await bridge.previewVoice(
                    engine: engine, voice: voice,
                    apiKey: engine == .openAI ? openAIAPIKey : nil
                )
                guard preparingPreviewVoiceId == voice.id else { return }
                let sound = NSSound(contentsOf: url, byReference: true)
                previewSound = sound
                previewingVoiceId = voice.id
                preparingPreviewVoiceId = nil
                sound?.play()
                status = "Playing \(voice.label) preview."
                let duration = sound?.duration ?? 4
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(duration, 1) * 1_000_000_000))
                    if previewingVoiceId == voice.id {
                        previewingVoiceId = nil
                        previewSound = nil
                    }
                }
            } catch {
                preparingPreviewVoiceId = nil
                errorMessage = error.localizedDescription
                status = "Preview failed."
            }
        }
        #else
        status = "Voice preview not yet available on iOS."
        #endif
    }

    private func handleInstallEvent(_ event: GenerationEvent) {
        switch event.event {
        case "started":
            appendInstallLog(event.message ?? "Starting…", .info)
        case "log":
            appendInstallLog(event.message ?? "", style(from: event.level))
        case "done":
            appendInstallLog(event.message ?? "Done.", .success)
        default:
            if let msg = event.message, !msg.isEmpty {
                appendInstallLog(msg, style(from: event.level))
            }
        }
    }

    func appendInstallLog(_ text: String, _ style: LogStyle) {
        installLog.append(GenerationLogLine(text: text, style: style))
    }

    // MARK: - Generation

    func renderPreviewScene() {
        guard let first = sceneList.first(where: { selectedScenes.contains($0.number) }) else {
            errorMessage = "Select at least one scene first."
            return
        }
        startGeneration(sceneNumbers: [first.number])
    }

    func renderSelectedScenes() {
        startGeneration(sceneNumbers: Array(selectedScenes).sorted())
    }

    func startGeneration(sceneNumbers: [Int]) {
        guard let pdf = selectedPDF else {
            errorMessage = "Open a PDF before generating audio."
            return
        }
        guard !sceneNumbers.isEmpty else {
            errorMessage = "Select at least one scene to render."
            return
        }
        guard installedEngines.contains(selectedEngine) else {
            errorMessage = "\(selectedEngine.title) is not installed. Go back to Voices to download it."
            return
        }

        let out = outputDirectory ?? defaultOutputDirectory(for: pdf)
        outputDirectory = out
        UserDefaults.standard.set(out.path, forKey: "lastOutputDirectory")
        generationLog = []
        generationProgress = 0
        generationComplete = false
        isPaused = false
        pauseStartTime = nil
        totalPausedSeconds = 0
        renderingSceneNumbers = sceneNumbers
        sceneProgress = Dictionary(uniqueKeysWithValues: sceneNumbers.map { ($0, 0.0) })
        renderStartTime = Date()
        isGenerating = true
        isWorking = true
        status = "Rendering \(sceneNumbers.count) scene(s)..."
        appendLog("Starting render to \(out.path)", .info)

        let assignment = voiceAssignment
        let engine = selectedEngine
        // Load key from Keychain on demand — only at the point of actual use
        if engine == .openAI && openAIAPIKey.isEmpty {
            openAIAPIKey = KeychainHelper.read(key: "openai_api_key") ?? ""
        }
        let apiKey = engine == .openAI ? openAIAPIKey : nil

        let addedElements = userAddedElements

        Task {
            do {
                #if os(macOS)
                try await bridge.generate(
                    pdf: pdf,
                    outputDirectory: out,
                    engine: engine,
                    sceneNumbers: sceneNumbers,
                    assignment: assignment,
                    apiKey: apiKey,
                    userAddedElements: addedElements
                ) { [weak self] event in
                    self?.handleGenerationEvent(event)
                }
                #else
                throw NSError(domain: "TableRead", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Audio generation not yet available on iOS."])
                #endif
            } catch {
                if isGenerating {
                    appendLog(error.localizedDescription, .error)
                    errorMessage = error.localizedDescription
                    status = "Generation failed."
                }
            }
            isGenerating = false
            isWorking = false
            renderStartTime = nil
        }
    }

    func cancelGeneration() {
        guard isGenerating else { return }
        #if os(macOS)
        if isPaused { bridge.resumeGeneration() }  // must resume before terminating
        bridge.cancelGeneration()
        #endif
        appendLog("Cancel requested. Stopping the current render job.", .warning)
        isGenerating = false
        isWorking = false
        isPaused = false
        pauseStartTime = nil
        totalPausedSeconds = 0
        renderStartTime = nil
        status = "Generation canceled."
    }

    func pauseGeneration() {
        guard isGenerating, !isPaused else { return }
        isPaused = true
        pauseStartTime = Date()
        #if os(macOS)
        bridge.pauseGeneration()
        #endif
        appendLog("Render paused.", .warning)
        status = "Render paused — click Resume to continue."
    }

    func resumeGeneration() {
        guard isGenerating, isPaused else { return }
        if let start = pauseStartTime {
            totalPausedSeconds += Date().timeIntervalSince(start)
        }
        pauseStartTime = nil
        isPaused = false
        #if os(macOS)
        bridge.resumeGeneration()
        #endif
        appendLog("Render resumed.", .info)
        status = "Rendering…"
    }

    /// Effective wall-clock seconds elapsed, excluding time spent paused.
    var effectiveElapsedSeconds: Int {
        guard let start = renderStartTime else { return 0 }
        var paused = totalPausedSeconds
        if let ps = pauseStartTime { paused += Date().timeIntervalSince(ps) }
        return max(0, Int(Date().timeIntervalSince(start) - paused))
    }

    func copyGenerationLogToClipboard() {
        let text = generationLog.map(\.text).joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        appendLog("Copied output log to clipboard.", .success)
    }

    func resetForNewProject() {
        navigatingForward = false
        step = .importScript
        script = nil
        selectedPDF = nil
        voices = []
        voiceAssignment = [:]
        selectedScenes = []
        generationLog = []
        generationProgress = 0
        sceneProgress = [:]
        renderingSceneNumbers = []
        generationComplete = false
        renderStartTime = nil
        status = "Choose a PDF script to begin."
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
        UserDefaults.standard.set(url.path, forKey: "lastOutputDirectory")
        status = "Output folder set to \(url.lastPathComponent)."
    }

    // MARK: - Recent scripts

    private static let recentScriptsKey = "recentScripts"

    private static func loadRecentScripts() -> [RecentScript] {
        guard let data = UserDefaults.standard.data(forKey: recentScriptsKey),
              let decoded = try? JSONDecoder().decode([RecentScript].self, from: data) else {
            return []
        }
        // Skip fileExists check here — do it lazily in pruneStaleRecentScripts()
        // to avoid a Documents-folder TCC prompt at launch.
        return decoded
    }

    /// Remove entries whose files no longer exist. Call once the import screen is visible,
    /// not at launch — defers the filesystem scan past the TCC consent window.
    func pruneStaleRecentScripts() {
        recentScripts = recentScripts.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func rememberRecentScript(_ url: URL, title: String) {
        let item = RecentScript(path: url.path, title: title, lastOpened: Date())
        recentScripts.removeAll { $0.path == item.path }
        recentScripts.insert(item, at: 0)
        recentScripts = Array(recentScripts.prefix(8))
        if let data = try? JSONEncoder().encode(recentScripts) {
            UserDefaults.standard.set(data, forKey: Self.recentScriptsKey)
        }
    }

    // MARK: - Event handling

    func handleGenerationEvent(_ event: GenerationEvent) {
        switch event.event {
        case "started":
            appendLog(event.message ?? "Generation started.", .info)
        case "progress":
            if let sceneIndex = event.sceneIndex,
               let totalScenes = event.totalScenes,
               totalScenes > 0,
               sceneIndex >= 0,
               sceneIndex < renderingSceneNumbers.count {
                let sceneNumber = renderingSceneNumbers[sceneIndex]
                if let elementIndex = event.elementIndex {
                    if elementIndex >= 0, let totalElements = event.totalElements, totalElements > 0 {
                        // Per-element progress within a scene
                        let frac = Double(elementIndex + 1) / Double(totalElements)
                        sceneProgress[sceneNumber] = min(frac, 0.99) // cap until ✓ confirms completion
                        generationProgress = (Double(sceneIndex) + frac) / Double(totalScenes)
                    } else if elementIndex == -1 {
                        // Scene-level message: check for completion or error
                        if let message = event.message {
                            if message.hasPrefix("✓") {
                                sceneProgress[sceneNumber] = 1.0
                                if notifyOnSceneComplete {
                                    let title = event.sceneTitle ?? "Scene \(sceneNumber)"
                                    sendNotification(
                                        title: "Scene rendered",
                                        body: "\(title) is ready.",
                                        identifier: "scene-\(sceneNumber)"
                                    )
                                }
                            } else if message.lowercased().hasPrefix("error") {
                                // Leave at last known progress; log handles the display
                            }
                        }
                        generationProgress = (Double(sceneIndex) + 1.0) / Double(totalScenes)
                    }
                }
            }
            if let message = event.message, !message.isEmpty {
                appendLog(message, message.lowercased().contains("error") ? .error : .info)
            }
        case "log":
            appendLog(event.message ?? "", style(from: event.level))
        case "done":
            generationProgress = 1
            let count = event.files?.count ?? 0
            let seconds = event.seconds ?? 0
            let hasErrors = !(event.errors ?? []).isEmpty
            appendLog(
                "\(hasErrors ? "Finished with errors" : "Done"). Wrote \(count) file(s) in \(format(seconds: seconds)).",
                hasErrors ? .error : .success
            )
            if let outputDir = event.outputDir {
                lastOutputDirectory = URL(fileURLWithPath: outputDir)
            }
            if let errors = event.errors, !errors.isEmpty {
                errors.forEach { appendLog($0, .error) }
            }
            let renderHadErrors = !(event.errors ?? []).isEmpty
            status = renderHadErrors ? "Completed with errors." : "Generation complete."
            if renderHadErrors {
                if notifyOnRenderFailed {
                    sendNotification(
                        title: "Table Read — Render finished with errors",
                        body: "Check the output log for details.",
                        identifier: "render-complete"
                    )
                }
            } else {
                generationComplete = true
                if notifyOnRenderComplete {
                    let fileCount = event.files?.count ?? 0
                    let folder = lastOutputDirectory?.lastPathComponent ?? "the output folder"
                    sendNotification(
                        title: "Table Read — Render complete",
                        body: "\(fileCount) file\(fileCount == 1 ? "" : "s") ready in \(folder).",
                        identifier: "render-complete"
                    )
                }
                if autoOpenFinderAfterRender, let dir = lastOutputDirectory {
                    #if os(macOS)
                    NSWorkspace.shared.open(dir)
                    #else
                    await UIApplication.shared.open(dir)
                    #endif
                }
            }
        default:
            appendLog(event.message ?? event.event, .info)
        }
    }

    func appendLog(_ text: String, _ style: LogStyle) {
        generationLog.append(GenerationLogLine(text: text, style: style))
    }

    // MARK: - Helpers

    private func defaultOutputDirectory(for pdf: URL) -> URL {
        pdf.deletingLastPathComponent()
            .appendingPathComponent(pdf.deletingPathExtension().lastPathComponent + " - table read")
    }

    private func format(seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s" }
        return "\(value / 60)m \(value % 60)s"
    }

    private func style(from level: String?) -> LogStyle {
        switch level {
        case "success": .success
        case "warning", "warn": .warning
        case "error": .error
        default: .info
        }
    }
}

// MARK: - Corrections

extension AppState {
    func saveCorrection(_ correction: ParserCorrection) {
        let k = ParserCorrection.key(
            pdfIdentifier: correction.pdfIdentifier,
            sceneNumber: correction.sceneNumber,
            text: correction.textKey
        )
        corrections[k] = correction
        Self.persistCorrections(corrections)
        // Upload in the background if the user opted in.
        Task.detached(priority: .background) { [weak self] in
            await self?.uploadPendingCorrections()
        }
    }

    func deleteCorrection(pdfPath: String, sceneNumber: Int, textKey: String) {
        let k = ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: sceneNumber, text: textKey)
        corrections.removeValue(forKey: k)
        Self.persistCorrections(corrections)
    }

    func exportCorrections() -> URL? {
        let toExport = contributeCorrections
            ? corrections.values.map { $0 }
            : corrections.values.filter { $0.contributed }
        guard !toExport.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(toExport)) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("table_read_corrections_\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url)
        return url
    }

    static func loadCorrections() -> [String: ParserCorrection] {
        guard let data = UserDefaults.standard.data(forKey: "parserCorrections"),
              let decoded = try? JSONDecoder().decode([String: ParserCorrection].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persistCorrections(_ corrections: [String: ParserCorrection]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(corrections) {
            UserDefaults.standard.set(data, forKey: "parserCorrections")
        }
    }

    // MARK: Scene title overrides

    func setSceneTitle(_ title: String, pdfPath: String, sceneNumber: Int) {
        var byPDF = sceneTitleOverrides[pdfPath] ?? [:]
        byPDF[sceneNumber] = title.isEmpty ? nil : title
        sceneTitleOverrides[pdfPath] = byPDF
        Self.persistSceneTitleOverrides(sceneTitleOverrides)
    }

    func effectiveSceneTitle(pdfPath: String, scene: SceneSummary) -> String {
        sceneTitleOverrides[pdfPath]?[scene.number] ?? scene.title
    }

    static func loadSceneTitleOverrides() -> [String: [Int: String]] {
        guard let data = UserDefaults.standard.data(forKey: "sceneTitleOverrides"),
              let decoded = try? JSONDecoder().decode([String: [Int: String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persistSceneTitleOverrides(_ overrides: [String: [Int: String]]) {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: "sceneTitleOverrides")
        }
    }
}

// MARK: - Corrections upload

/// Replace this with your deployed Cloudflare Worker URL once you've set it up.
/// Leave empty to disable automatic upload (corrections are still stored locally).
private let correctionUploadEndpoint = ""

extension AppState {
    /// Upload any unuploaded, opted-in corrections to the Cloudflare Worker endpoint.
    /// Silently no-ops if the endpoint isn't configured or the network is unavailable.
    func uploadPendingCorrections() {
        guard contributeCorrections,
              !correctionUploadEndpoint.isEmpty,
              let url = URL(string: correctionUploadEndpoint) else { return }

        let pending = corrections.values.filter { $0.contributed && !$0.uploaded }
        guard !pending.isEmpty else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let payload = pending.map { $0.anonymized(appVersion: version) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(["corrections": payload]) else { return }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Keys of corrections we're about to upload — used to mark them after success.
        let keys: [String] = pending.compactMap { correction in
            corrections.first(where: { $0.value == correction })?.key
        }

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            Task { @MainActor in
                for key in keys {
                    self.corrections[key]?.uploaded = true
                }
                Self.persistCorrections(self.corrections)
            }
        }.resume()
    }
}

// MARK: - Notifications

extension AppState {
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - User-added elements

extension AppState {
    private static let userAddedElementsKey = "userAddedElements"

    private func addedKey(pdfPath: String, sceneNumber: Int) -> String {
        "\(pdfPath)|\(sceneNumber)"
    }

    func addElement(
        afterTextKey: String,
        speaker: String,
        kind: String = "dialog",
        sceneNumber: Int,
        pdfPath: String
    ) {
        let el = UserAddedElement(
            pdfPath: pdfPath,
            sceneNumber: sceneNumber,
            afterElementTextKey: afterTextKey,
            speaker: speaker,
            text: "",
            kind: kind,
            timestamp: Date()
        )
        let key = addedKey(pdfPath: pdfPath, sceneNumber: sceneNumber)
        userAddedElements[key, default: []].append(el)
        Self.persistUserAddedElements(userAddedElements)
    }

    func updateAddedElement(
        id: UUID,
        speaker: String,
        text: String,
        kind: String,
        sceneNumber: Int,
        pdfPath: String
    ) {
        let key = addedKey(pdfPath: pdfPath, sceneNumber: sceneNumber)
        guard let idx = userAddedElements[key]?.firstIndex(where: { $0.id == id }) else { return }
        userAddedElements[key]?[idx].speaker = speaker
        userAddedElements[key]?[idx].text = text
        userAddedElements[key]?[idx].kind = kind
        Self.persistUserAddedElements(userAddedElements)
    }

    func deleteAddedElement(id: UUID, sceneNumber: Int, pdfPath: String) {
        let key = addedKey(pdfPath: pdfPath, sceneNumber: sceneNumber)
        userAddedElements[key]?.removeAll { $0.id == id }
        if userAddedElements[key]?.isEmpty == true { userAddedElements.removeValue(forKey: key) }
        Self.persistUserAddedElements(userAddedElements)
    }

    /// Return parsed elements interleaved with any user-added lines, capped at `limit` parsed elements.
    func mergedElements(for scene: SceneSummary, pdfPath: String, limit: Int = 80) -> [MergedSceneElement] {
        let key = addedKey(pdfPath: pdfPath, sceneNumber: scene.number)
        let added = userAddedElements[key] ?? []
        var addedByKey: [String: [UserAddedElement]] = [:]
        for el in added {
            addedByKey[el.afterElementTextKey, default: []].append(el)
        }
        var result: [MergedSceneElement] = []
        for element in scene.elements.prefix(limit) {
            result.append(.parsed(element))
            let textKey = String(element.text.prefix(60))
            if let bucket = addedByKey[textKey] {
                for addedEl in bucket.sorted(by: { $0.timestamp < $1.timestamp }) {
                    result.append(.added(addedEl))
                }
            }
        }
        return result
    }

    static func loadUserAddedElements() -> [String: [UserAddedElement]] {
        guard let data = UserDefaults.standard.data(forKey: userAddedElementsKey) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [UserAddedElement]].self, from: data)) ?? [:]
    }

    private static func persistUserAddedElements(_ elements: [String: [UserAddedElement]]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(elements) {
            UserDefaults.standard.set(data, forKey: userAddedElementsKey)
        }
    }
}

// MARK: - Keychain helper

enum KeychainHelper {
    static func write(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tableread",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tableread",
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tableread",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tableread",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
