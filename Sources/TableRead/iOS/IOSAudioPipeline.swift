#if os(iOS)
import Foundation
import AVFoundation

// MARK: - iOS audio generation pipeline

/// Orchestrates per-scene audio generation on iOS, mirroring the Python
/// audio_pipeline.py logic: synthesize each element, concatenate, export M4A.
actor IOSAudioPipeline {
    let engine: any IOSTTSEngine
    let voiceAssignment: [String: String]  // character name → voice ID
    let narratorVoiceID: String

    // 100 ms silence between elements; 500 ms between scenes
    private static let elementGap: Double = 0.10
    private static let sceneGap: Double = 0.50

    // MARK: - Event reporting (mirrors GenerationEvent)

    struct ProgressEvent: Sendable {
        enum Kind { case started, sceneBegin, elementDone, sceneDone, finished, error }
        let kind: Kind
        let sceneIndex: Int?
        let totalScenes: Int?
        let elementIndex: Int?
        let totalElements: Int?
        let sceneTitle: String?
        let message: String?
    }

    // MARK: - Init

    init(
        engine: any IOSTTSEngine,
        voiceAssignment: [String: String],
        narratorVoiceID: String
    ) {
        self.engine = engine
        self.voiceAssignment = voiceAssignment
        self.narratorVoiceID = narratorVoiceID
    }

    // MARK: - Public API

    /// Generate audio for the given scenes, writing one M4A per scene to `outputDir`.
    /// Reports progress via `onProgress`.
    func generate(
        scenes: [SceneSummary],
        outputDir: URL,
        onProgress: @Sendable @escaping (ProgressEvent) -> Void
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        onProgress(ProgressEvent(
            kind: .started, sceneIndex: nil, totalScenes: scenes.count,
            elementIndex: nil, totalElements: nil, sceneTitle: nil, message: nil
        ))

        var outputFiles: [URL] = []
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for (idx, scene) in scenes.enumerated() {
            onProgress(ProgressEvent(
                kind: .sceneBegin, sceneIndex: idx, totalScenes: scenes.count,
                elementIndex: nil, totalElements: scene.elements.count,
                sceneTitle: scene.title, message: nil
            ))

            let sceneOut = try await generateScene(
                scene: scene, sceneIndex: idx, tmpDir: tmpDir, outputDir: outputDir,
                onProgress: onProgress
            )
            outputFiles.append(sceneOut)

            onProgress(ProgressEvent(
                kind: .sceneDone, sceneIndex: idx, totalScenes: scenes.count,
                elementIndex: nil, totalElements: nil,
                sceneTitle: scene.title, message: nil
            ))
        }

        onProgress(ProgressEvent(
            kind: .finished, sceneIndex: nil, totalScenes: scenes.count,
            elementIndex: nil, totalElements: nil, sceneTitle: nil, message: nil
        ))

        return outputFiles
    }

    // MARK: - Per-scene generation

    private func generateScene(
        scene: SceneSummary,
        sceneIndex: Int,
        tmpDir: URL,
        outputDir: URL,
        onProgress: @Sendable @escaping (ProgressEvent) -> Void
    ) async throws -> URL {
        var elementFiles: [URL] = []

        for (elIdx, element) in scene.elements.enumerated() {
            guard !element.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let voiceID = resolvedVoiceID(for: element)
            let ext = engine.audioExtension
            let elementFile = tmpDir.appendingPathComponent(
                "s\(sceneIndex)_e\(elIdx)\(ext)"
            )

            do {
                try await engine.synthesize(
                    text: element.text,
                    voiceID: voiceID,
                    outputURL: elementFile
                )
                elementFiles.append(elementFile)
            } catch {
                // Non-fatal: log and skip the element
                onProgress(ProgressEvent(
                    kind: .error, sceneIndex: sceneIndex, totalScenes: nil,
                    elementIndex: elIdx, totalElements: nil,
                    sceneTitle: scene.title,
                    message: "Element \(elIdx) failed: \(error.localizedDescription)"
                ))
            }

            onProgress(ProgressEvent(
                kind: .elementDone, sceneIndex: sceneIndex, totalScenes: nil,
                elementIndex: elIdx, totalElements: scene.elements.count,
                sceneTitle: nil, message: nil
            ))
        }

        guard !elementFiles.isEmpty else {
            throw PipelineError.noElementsGenerated(scene.title)
        }

        // Concatenate and export M4A
        let sceneName = sanitizeFilename(scene.title)
        let outURL = outputDir.appendingPathComponent("\(sceneIndex + 1)_\(sceneName).m4a")
        try await concatenateToM4A(elementFiles: elementFiles, outputURL: outURL)
        return outURL
    }

    // MARK: - Voice resolution

    private func resolvedVoiceID(for element: SceneElementSummary) -> String {
        let speaker: String
        if element.kind == "dialog", let s = element.speaker {
            speaker = s
        } else {
            speaker = NARRATOR_KEY
        }
        return voiceAssignment[speaker] ?? narratorVoiceID
    }

    // MARK: - Audio concatenation (AVAssetExportSession → M4A)

    private func concatenateToM4A(elementFiles: [URL], outputURL: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PipelineError.compositionFailed
        }

        var cursor = CMTime.zero
        let gapTime = CMTime(seconds: Self.elementGap, preferredTimescale: 44100)

        for fileURL in elementFiles {
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try track.insertTimeRange(timeRange, of: assetTrack, at: cursor)
            cursor = cursor + duration + gapTime
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw PipelineError.exporterUnavailable
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        await exporter.export()

        if let error = exporter.error { throw error }
        guard exporter.status == .completed else {
            throw PipelineError.exportFailed(exporter.status.rawValue)
        }
    }

    // MARK: - Utilities

    private func sanitizeFilename(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return title.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .prefix(40)
            .description
    }
}

enum PipelineError: LocalizedError {
    case noElementsGenerated(String)
    case compositionFailed
    case exporterUnavailable
    case exportFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noElementsGenerated(let title): "No audio generated for scene: \(title)"
        case .compositionFailed: "Failed to create audio composition."
        case .exporterUnavailable: "M4A export is not available on this device."
        case .exportFailed(let code): "Audio export failed with status \(code)."
        }
    }
}
#endif
