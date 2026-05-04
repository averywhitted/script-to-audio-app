import Foundation

struct WorkerEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var script: T?
    var estimate: T?
}

enum PythonBridgeError: Error, LocalizedError {
    case workerMissing
    case failed(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .workerMissing:
            "Could not find the Python worker."
        case .failed(let message):
            message
        case .badResponse:
            "The Python worker returned an unexpected response."
        }
    }
}

@MainActor
final class PythonBridge {
    private let repositoryRoot: URL

    init() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if cwd.lastPathComponent == "NativeMacApp" {
            repositoryRoot = cwd.deletingLastPathComponent()
        } else {
            repositoryRoot = cwd
        }
    }

    func parse(pdf: URL) async throws -> ScriptSummary {
        let response: WorkerEnvelope<ScriptSummary> = try await request([
            "command": "parse",
            "pdfPath": pdf.path,
        ])
        guard let script = response.script else { throw PythonBridgeError.badResponse }
        return script
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
        onEvent: @escaping @MainActor (GenerationEvent) -> Void
    ) async throws {
        let payload: [String: Any] = [
            "command": "generate",
            "pdfPath": pdf.path,
            "outputDir": outputDirectory.path,
            "engine": engine.id,
            "sceneNumbers": sceneNumbers,
        ]
        try await streamRequest(payload, onEvent: onEvent)
    }

    private func request<T: Decodable & Sendable>(_ payload: [String: Any]) async throws -> WorkerEnvelope<T> {
        let worker = repositoryRoot.appendingPathComponent("backend/audio_worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw PythonBridgeError.workerMissing
        }
        let root = repositoryRoot
        let requestData = try JSONSerialization.data(withJSONObject: payload)

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let venvPython = root.appendingPathComponent(".venv/bin/python")
            let python = FileManager.default.fileExists(atPath: venvPython.path) ? venvPython.path : "python3"
            process.arguments = [python, worker.path]
            process.currentDirectoryURL = root

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

            let decoded = try JSONDecoder().decode(WorkerEnvelope<T>.self, from: response)
            if decoded.ok { return decoded }
            throw PythonBridgeError.failed(decoded.error ?? "Python worker failed.")
        }.value
    }

    private func streamRequest(
        _ payload: [String: Any],
        onEvent: @escaping @MainActor (GenerationEvent) -> Void
    ) async throws {
        let worker = repositoryRoot.appendingPathComponent("backend/audio_worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw PythonBridgeError.workerMissing
        }
        let root = repositoryRoot
        let requestData = try JSONSerialization.data(withJSONObject: payload)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                let venvPython = root.appendingPathComponent(".venv/bin/python")
                let python = FileManager.default.fileExists(atPath: venvPython.path) ? venvPython.path : "python3"
                process.arguments = [python, worker.path]
                process.currentDirectoryURL = root

                let input = Pipe()
                let output = Pipe()
                let error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error

                do {
                    try process.run()
                    input.fileHandleForWriting.write(requestData)
                    input.fileHandleForWriting.closeFile()

                    let eventQueue = DispatchQueue(label: "ScriptAudioDrama.worker.events")
                    var partial = ""
                    var workerError: String?

                    func consume(_ text: String, flush: Bool = false) {
                        partial += text
                        while let range = partial.range(of: "\n") {
                            let line = String(partial[..<range.lowerBound])
                            partial.removeSubrange(partial.startIndex..<range.upperBound)
                            decode(line)
                        }
                        if flush, !partial.isEmpty {
                            decode(partial)
                            partial = ""
                        }
                    }

                    func decode(_ line: String) {
                        guard let lineData = line.data(using: .utf8) else { return }
                        if let event = try? JSONDecoder().decode(GenerationEvent.self, from: lineData) {
                            Task { @MainActor in onEvent(event) }
                        } else if let envelope = try? JSONDecoder().decode(WorkerEnvelope<ScriptSummary>.self, from: lineData),
                                  envelope.ok == false {
                            workerError = envelope.error
                        }
                    }

                    output.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                        eventQueue.async {
                            consume(text)
                        }
                    }

                    process.waitUntilExit()
                    output.fileHandleForReading.readabilityHandler = nil
                    eventQueue.sync {
                        consume("", flush: true)
                    }
                    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PythonBridgeError.failed(workerError ?? stderr))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
