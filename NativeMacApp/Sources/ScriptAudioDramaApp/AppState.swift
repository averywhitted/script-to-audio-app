import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var step: WorkflowStep = .importScript
    @Published var selectedPDF: URL?
    @Published var script: ScriptSummary?
    @Published var selectedEngine: EngineKind = .macOS
    @Published var installedEngines: Set<EngineKind> = [.macOS, .openAI]
    @Published var pendingDownload: EngineDownloadPrompt?
    @Published var isDownloadingEngine = false
    @Published var selectedScenes: Set<Int> = []
    @Published var openAIEstimate: OpenAIEstimate?
    @Published var isWorking = false
    @Published var isGenerating = false
    @Published var generationProgress = 0.0
    @Published var generationLog: [GenerationLogLine] = []
    @Published var outputDirectory: URL?
    @Published var status = "Choose a PDF script to begin."
    @Published var errorMessage: String?

    let bridge = PythonBridge()

    var sceneList: [SceneSummary] { script?.scenes ?? [] }

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
        step = target
    }

    func importPDF(_ url: URL) {
        selectedPDF = url
        isWorking = true
        status = "Parsing script..."
        errorMessage = nil

        Task {
            do {
                let parsed = try await bridge.parse(pdf: url)
                script = parsed
                selectedScenes = Set(parsed.scenes.map(\.number))
                step = .review
                status = "\(parsed.sceneCount) scenes, \(parsed.characterCount) characters."
            } catch {
                errorMessage = error.localizedDescription
                status = "Parsing failed."
            }
            isWorking = false
        }
    }

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

    func chooseEngine(_ engine: EngineKind) {
        selectedEngine = engine
        if installedEngines.contains(engine) {
            refreshOpenAIEstimate()
        } else {
            pendingDownload = EngineDownloadPrompt(engine: engine)
        }
    }

    func downloadPendingEngine() {
        guard let engine = pendingDownload?.engine else { return }
        pendingDownload = nil
        isDownloadingEngine = true
        isWorking = true
        status = "Downloading \(engine.title)..."
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            installedEngines.insert(engine)
            isDownloadingEngine = false
            isWorking = false
            status = "\(engine.title) is ready."
            refreshOpenAIEstimate()
        }
    }

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
        guard selectedEngine == .macOS else {
            errorMessage = "\(selectedEngine.title) generation is not wired yet. Use macOS Voices for this slice."
            return
        }

        let out = outputDirectory ?? defaultOutputDirectory(for: pdf)
        outputDirectory = out
        generationLog = []
        generationProgress = 0
        isGenerating = true
        isWorking = true
        status = "Rendering \(sceneNumbers.count) scene(s)..."
        appendLog("Starting render to \(out.path)", .info)

        Task {
            do {
                try await bridge.generate(
                    pdf: pdf,
                    outputDirectory: out,
                    engine: selectedEngine,
                    sceneNumbers: sceneNumbers
                ) { [weak self] event in
                    self?.handleGenerationEvent(event)
                }
            } catch {
                appendLog(error.localizedDescription, .error)
                errorMessage = error.localizedDescription
                status = "Generation failed."
            }
            isGenerating = false
            isWorking = false
        }
    }

    func handleGenerationEvent(_ event: GenerationEvent) {
        switch event.event {
        case "started":
            appendLog(event.message ?? "Generation started.", .info)
        case "progress":
            if let sceneIndex = event.sceneIndex,
               let totalScenes = event.totalScenes,
               let elementIndex = event.elementIndex,
               let totalElements = event.totalElements,
               totalScenes > 0 {
                let sceneFraction = Double(max(elementIndex + 1, 0)) / Double(max(totalElements, 1))
                generationProgress = (Double(sceneIndex) + sceneFraction) / Double(totalScenes)
            }
            if let message = event.message, !message.isEmpty {
                appendLog(message, message.lowercased().contains("error") ? .error : .info)
            }
        case "done":
            generationProgress = 1
            let count = event.files?.count ?? 0
            let seconds = event.seconds ?? 0
            appendLog("Done. Wrote \(count) file(s) in \(format(seconds: seconds)).", .success)
            if let errors = event.errors, !errors.isEmpty {
                errors.forEach { appendLog($0, .error) }
            }
            status = "Generation complete."
        default:
            appendLog(event.message ?? event.event, .info)
        }
    }

    func appendLog(_ text: String, _ style: LogStyle) {
        generationLog.append(GenerationLogLine(text: text, style: style))
    }

    private func defaultOutputDirectory(for pdf: URL) -> URL {
        pdf.deletingLastPathComponent()
            .appendingPathComponent(pdf.deletingPathExtension().lastPathComponent + " - audio drama")
    }

    private func format(seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s" }
        return "\(value / 60)m \(value % 60)s"
    }
}
