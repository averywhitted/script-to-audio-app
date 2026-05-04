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
}
