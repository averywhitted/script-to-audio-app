import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var step: WorkflowStep = .importScript
    @Published var selectedPDF: URL?
    @Published var script: ScriptSummary?
    @Published var selectedEngine: EngineKind = .macOS
    @Published var selectedScenes: Set<Int> = []
    @Published var openAIEstimate: OpenAIEstimate?
    @Published var isWorking = false
    @Published var status = "Choose a PDF script to begin."
    @Published var errorMessage: String?

    let bridge = PythonBridge()

    var sceneList: [SceneSummary] { script?.scenes ?? [] }

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
}
