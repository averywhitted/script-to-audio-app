import Foundation

struct WorkerEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var script: T?
    var estimate: T?
}

private struct WorkerFailure: Decodable {
    var ok: Bool
    var error: String?
    var traceback: String?
}

enum PythonBridgeError: Error, LocalizedError {
    case workerMissing
    case failed(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .workerMissing:
            "Could not find the Python worker. Make sure the app is run from the repository root."
        case .failed(let message):
            message
        case .badResponse:
            "The Python worker returned an unexpected response."
        }
    }
}

private final class EventLineParser: @unchecked Sendable {
    private var partial = ""
    var workerError: String?

    func consume(_ text: String, flush: Bool = false, onEvent: @escaping @MainActor (GenerationEvent) -> Void) {
        partial += text
        while let range = partial.range(of: "\n") {
            let line = String(partial[..<range.lowerBound])
            partial.removeSubrange(partial.startIndex..<range.upperBound)
            decode(line, onEvent: onEvent)
        }
        if flush, !partial.isEmpty {
            decode(partial, onEvent: onEvent)
            partial = ""
        }
    }

    private func decode(_ line: String, onEvent: @escaping @MainActor (GenerationEvent) -> Void) {
        guard let lineData = line.data(using: .utf8) else { return }
        if let event = try? JSONDecoder().decode(GenerationEvent.self, from: lineData) {
            Task { @MainActor in onEvent(event) }
        } else if let failure = try? JSONDecoder().decode(WorkerFailure.self, from: lineData),
                  failure.ok == false {
            workerError = [failure.error, failure.traceback]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
    }
}

@MainActor
final class PythonBridge {
    let repositoryRoot: URL

    init() {
        repositoryRoot = Self.findRepositoryRoot()
    }

    // MARK: - Repository root detection

    /// Walk candidate paths looking for backend/audio_worker.py.
    /// Works for: swift run (CWD = repo root), Xcode (executable inside .build/),
    /// and future packaged app (worker bundled in Resources).
    private static func findRepositoryRoot() -> URL {
        let fm = FileManager.default
        let workerRelative = "backend/audio_worker.py"

        func valid(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent(workerRelative).path)
        }

        // 1. Path baked into Info.plist at build time via $(SRCROOT)/..
        //    Covers Xcode Debug/Release builds where the executable is in DerivedData.
        if let baked = Bundle.main.infoDictionary?["TRRepoRoot"] as? String {
            let url = URL(fileURLWithPath: baked).standardizedFileURL
            if valid(url) { return url }
        }

        // 2. Bundled inside a .app (packaged distribution)
        // audio_worker.py lives at Contents/Resources/backend/audio_worker.py
        // We want Contents/Resources/ so that backend/audio_worker.py resolves correctly.
        if let bundleURL = Bundle.main.url(forResource: "audio_worker", withExtension: "py") {
            let candidate = bundleURL
                .deletingLastPathComponent()   // → .../backend/
                .deletingLastPathComponent()   // → .../Resources/
            if valid(candidate) { return candidate }
        }

        // 3. CWD (covers `swift run` from repo root or NativeMacApp/)
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if valid(cwd) { return cwd }
        let parent = cwd.deletingLastPathComponent()
        if valid(parent) { return parent }

        // 4. Last resort — return CWD and let the error surface naturally
        return cwd
    }

    // MARK: - Public API

    func parse(pdf: URL) async throws -> ScriptSummary {
        let response: WorkerEnvelope<ScriptSummary> = try await request([
            "command": "parse",
            "pdfPath": pdf.path,
        ])
        guard let script = response.script else { throw PythonBridgeError.badResponse }
        return script
    }

    func voices(engine: EngineKind, pdf: URL?) async throws -> (voices: [VoiceSummary], autoAssign: [String: String]) {
        var payload: [String: Any] = ["command": "voices", "engine": engine.id]
        if let pdf {
            payload["pdfPath"] = pdf.path
        }
        let data = try await rawRequest(payload)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VoicesResponse.self, from: data)
        guard decoded.ok else {
            throw PythonBridgeError.failed(decoded.error ?? "Worker failed.")
        }
        return (decoded.voices ?? [], decoded.autoAssign ?? [:])
    }

    func estimateOpenAI(pdf: URL, sceneNumbers: [Int]) async throws -> OpenAIEstimate {
        let response: WorkerEnvelope<OpenAIEstimate> = try await request([
            "command": "estimateOpenAI",
            "pdfPath": pdf.path,
            "sceneNumbers": sceneNumbers,
        ])
        guard let estimate = response.estimate else { throw PythonBridgeError.badResponse }
        return estimate
    }

    func generate(
        pdf: URL,
        outputDirectory: URL,
        engine: EngineKind,
        sceneNumbers: [Int],
        assignment: [String: String] = [:],
        apiKey: String? = nil,
        userAddedElements: [String: [UserAddedElement]] = [:],
        onEvent: @escaping @MainActor (GenerationEvent) -> Void
    ) async throws {
        var payload: [String: Any] = [
            "command": "generate",
            "pdfPath": pdf.path,
            "outputDir": outputDirectory.path,
            "engine": engine.id,
            "sceneNumbers": sceneNumbers,
        ]
        if !assignment.isEmpty {
            payload["assignment"] = assignment
        }
        if let apiKey, !apiKey.isEmpty {
            payload["apiKey"] = apiKey
        }
        // Build a per-scene-number dict of user-added elements for the selected scenes
        var bySceneNumber: [String: [[String: Any]]] = [:]
        for sceneNumber in sceneNumbers {
            let key = "\(pdf.path)|\(sceneNumber)"
            if let elements = userAddedElements[key], !elements.isEmpty {
                bySceneNumber["\(sceneNumber)"] = elements.compactMap { el -> [String: Any]? in
                    guard !el.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return [
                        "afterElementTextKey": el.afterElementTextKey,
                        "speaker": el.speaker,
                        "text": el.text,
                        "kind": el.kind,
                    ]
                }
            }
        }
        if !bySceneNumber.isEmpty {
            payload["userAddedElements"] = bySceneNumber
        }
        try await streamRequest(payload, onEvent: onEvent)
    }

    func installEngine(
        _ engine: EngineKind,
        onEvent: @escaping @MainActor (GenerationEvent) -> Void
    ) async throws {
        try await streamRequest([
            "command": "installEngine",
            "engine": engine.id,
        ], onEvent: onEvent)
    }

    func engineStatus() async throws -> [EngineKind: EngineStatus] {
        let data = try await rawRequest(["command": "engineStatus"])
        let decoded = try JSONDecoder().decode(EngineStatusResponse.self, from: data)
        guard decoded.ok else {
            throw PythonBridgeError.failed(decoded.error ?? "Worker failed.")
        }
        let raw = decoded.engines ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let engine = EngineKind(rawValue: key) else { return nil }
            return (engine, value)
        })
    }

    func uninstallEngine(_ engine: EngineKind) async throws {
        let data = try await rawRequest([
            "command": "uninstallEngine",
            "engine": engine.id,
        ])
        let decoded = try JSONDecoder().decode(BasicWorkerResponse.self, from: data)
        guard decoded.ok else {
            throw PythonBridgeError.failed(decoded.error ?? "Worker failed.")
        }
    }

    func previewVoice(engine: EngineKind, voice: VoiceSummary, apiKey: String? = nil) async throws -> URL {
        var payload: [String: Any] = [
            "command": "previewVoice",
            "engine": engine.id,
            "voiceId": voice.id,
        ]
        if let key = apiKey, !key.isEmpty {
            payload["apiKey"] = key
        }
        let data = try await rawRequest(payload)
        let decoded = try JSONDecoder().decode(BasicWorkerResponse.self, from: data)
        guard decoded.ok, let path = decoded.path else {
            throw PythonBridgeError.failed(decoded.error ?? "Could not prepare voice preview.")
        }
        return URL(fileURLWithPath: path)
    }

    func cancelGeneration() {
        generationProcess?.terminate()
        generationProcess = nil
    }

    func pauseGeneration() {
        generationProcess?.suspend()
    }

    func resumeGeneration() {
        generationProcess?.resume()
    }

    // MARK: - Process management

    private var generationProcess: Process?

    // MARK: - Private helpers

    private func python(root: URL) -> String {
        let fm = FileManager.default
        // 1. Venv alongside the discovered root (development / swift run)
        for name in [".venv/bin/python3", ".venv/bin/python"] {
            let p = root.appendingPathComponent(name).path
            if fm.fileExists(atPath: p) { return p }
        }
        // 2. Venv in ~/Library/Application Support/TableRead/ (installed .app)
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for name in [".venv/bin/python3", ".venv/bin/python"] {
                let p = support.appendingPathComponent("TableRead/\(name)").path
                if fm.fileExists(atPath: p) { return p }
            }
        }
        // 3. Fall back to whatever python3 is on PATH
        return "python3"
    }

    private func workerURL() throws -> URL {
        let worker = repositoryRoot.appendingPathComponent("backend/audio_worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw PythonBridgeError.workerMissing
        }
        return worker
    }

    /// Run the worker synchronously, return stdout as Data.
    private func rawRequest(_ payload: [String: Any]) async throws -> Data {
        let worker = try workerURL()
        let root = repositoryRoot
        let py = python(root: root)
        let requestData = try JSONSerialization.data(withJSONObject: payload)

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [py, worker.path]
            // Neutral CWD — avoids a Documents TCC prompt when the repo lives
            // inside ~/Documents. The worker uses absolute paths throughout.
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            try process.run()
            input.fileHandleForWriting.write(requestData)
            input.fileHandleForWriting.closeFile()

            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Kokoro (and other engines) may print non-JSON download progress to stdout.
            // Scan from the end for the last line that looks like a JSON object.
            return Self.extractLastJSONLine(from: response) ?? response
        }.value
    }

    private nonisolated static func extractLastJSONLine(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{"), let lineData = t.data(using: .utf8) else { continue }
            if (try? JSONSerialization.jsonObject(with: lineData)) != nil { return lineData }
        }
        return nil
    }

    /// Decode a WorkerEnvelope<T> from rawRequest.
    private func request<T: Decodable & Sendable>(_ payload: [String: Any]) async throws -> WorkerEnvelope<T> {
        let data = try await rawRequest(payload)
        let decoded = try JSONDecoder().decode(WorkerEnvelope<T>.self, from: data)
        if decoded.ok { return decoded }
        throw PythonBridgeError.failed(decoded.error ?? "Python worker failed.")
    }

    /// Run the worker and stream JSON events line by line via onEvent.
    private func streamRequest(
        _ payload: [String: Any],
        onEvent: @escaping @MainActor (GenerationEvent) -> Void
    ) async throws {
        let worker = try workerURL()
        let root = repositoryRoot
        let py = python(root: root)
        let requestData = try JSONSerialization.data(withJSONObject: payload)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [py, worker.path]
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

                let input = Pipe()
                let output = Pipe()
                let error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error

                do {
                    try process.run()
                    Task { @MainActor in self.generationProcess = process }
                    input.fileHandleForWriting.write(requestData)
                    input.fileHandleForWriting.closeFile()

                    let eventQueue = DispatchQueue(label: "ScriptAudioDrama.worker.events")
                    let parser = EventLineParser()

                    output.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                        eventQueue.async {
                            parser.consume(text, onEvent: onEvent)
                        }
                    }

                    process.waitUntilExit()
                    Task { @MainActor in self.generationProcess = nil }
                    output.fileHandleForReading.readabilityHandler = nil
                    eventQueue.sync {
                        parser.consume("", flush: true, onEvent: onEvent)
                    }
                    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let fallback = stderr.isEmpty ? "Worker exited with code \(process.terminationStatus)." : stderr
                        continuation.resume(throwing: PythonBridgeError.failed(parser.workerError ?? fallback))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
