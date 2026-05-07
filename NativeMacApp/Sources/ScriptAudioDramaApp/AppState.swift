import Foundation
import AppKit
import Security
import SwiftUI

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

    // Settings — persisted via UserDefaults
    @Published var autoOpenFinderAfterRender: Bool = UserDefaults.standard.bool(forKey: "autoOpenFinderAfterRender") {
        didSet { UserDefaults.standard.set(autoOpenFinderAfterRender, forKey: "autoOpenFinderAfterRender") }
    }

    let bridge = PythonBridge()
    private var previewSound: NSSound?

    var sceneList: [SceneSummary] { script?.scenes ?? [] }

    init() {
        // Restore OpenAI key from Keychain on launch
        if let stored = KeychainHelper.read(key: "openai_api_key"), !stored.isEmpty {
            openAIAPIKey = stored
            installedEngines.insert(.openAI)
        }
        // Restore last output directory
        if let savedPath = UserDefaults.standard.string(forKey: "lastOutputDirectory") {
            let url = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: savedPath) {
                outputDirectory = url
            }
        }
        recentScripts = Self.loadRecentScripts()
        Task {
            await refreshEngineStatus()
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            step = target
        }
        if target == .cast && voices.isEmpty {
            fetchVoices()
        }
    }

    // MARK: - Import

    func importPDF(_ url: URL) {
        selectedPDF = url
        isWorking = true
        status = "Parsing script..."
        errorMessage = nil

        Task {
            do {
                let parsed = try await bridge.parse(pdf: url)
                script = parsed
                rememberRecentScript(url, title: parsed.title)
                selectedScenes = Set(parsed.scenes.map(\.number))
                navigatingForward = true
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                    step = .review
                }
                status = "\(parsed.sceneCount) scenes, \(parsed.characterCount) characters."
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
                let (list, autoAssign) = try await bridge.voices(engine: engine, pdf: pdf)
                voices = list
                // voiceAssignment is cleared whenever the engine changes, so apply
                // server suggestions unconditionally — they become the starting defaults.
                for (char, voiceId) in autoAssign {
                    voiceAssignment[char] = voiceId
                }
                status = "\(list.count) voices available for \(engine.title)."
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
                openAIEstimate = try await bridge.estimateOpenAI(
                    pdf: pdf,
                    sceneNumbers: Array(selectedScenes).sorted()
                )
                if let estimate = openAIEstimate {
                    status = "\(estimate.requestCount) requests, about \(estimate.durationText) minimum."
                }
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
            KeychainHelper.delete(key: "openai_api_key")
            status = "OpenAI API key cleared."
            return
        }
        openAIAPIKey = trimmed
        installedEngines.insert(.openAI)
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
                try await bridge.installEngine(engine) { [weak self] event in
                    self?.handleInstallEvent(event)
                }
                installedEngines.insert(engine)
                await refreshEngineStatus()
                status = "\(engine.title) ready. The neural model downloads on first voice preview."
                fetchVoices()
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
            if !openAIAPIKey.isEmpty {
                installed.insert(.openAI)
            }
            installedEngines = installed
        } catch {
            // Keep the current UI state if the worker cannot answer yet.
        }
    }

    func uninstallEngine(_ engine: EngineKind) {
        guard engine != .macOS, engine != .openAI else { return }
        uninstallingEngine = engine
        status = "Removing \(engine.title)…"
        Task {
            do {
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
            } catch {
                errorMessage = error.localizedDescription
                status = "Uninstall failed."
            }
            uninstallingEngine = nil
        }
    }

    func toggleVoicePreview(_ voice: VoiceSummary) {
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
        renderingSceneNumbers = sceneNumbers
        sceneProgress = Dictionary(uniqueKeysWithValues: sceneNumbers.map { ($0, 0.0) })
        renderStartTime = Date()
        isGenerating = true
        isWorking = true
        status = "Rendering \(sceneNumbers.count) scene(s)..."
        appendLog("Starting render to \(out.path)", .info)

        let assignment = voiceAssignment
        let engine = selectedEngine
        let apiKey = selectedEngine == .openAI ? openAIAPIKey : nil

        Task {
            do {
                try await bridge.generate(
                    pdf: pdf,
                    outputDirectory: out,
                    engine: engine,
                    sceneNumbers: sceneNumbers,
                    assignment: assignment,
                    apiKey: apiKey
                ) { [weak self] event in
                    self?.handleGenerationEvent(event)
                }
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
        appendLog("Cancel requested. Stopping the current render job.", .warning)
        bridge.cancelGeneration()
        isGenerating = false
        isWorking = false
        renderStartTime = nil
        status = "Generation canceled."
    }

    func copyGenerationLogToClipboard() {
        let text = generationLog.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("Copied output log to clipboard.", .success)
    }

    func resetForNewProject() {
        navigatingForward = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            step = .importScript
        }
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
        return decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
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
            if !renderHadErrors {
                generationComplete = true
                if autoOpenFinderAfterRender, let dir = lastOutputDirectory {
                    NSWorkspace.shared.open(dir)
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
        var addQuery = query
        addQuery[kSecValueData as String] = data
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
