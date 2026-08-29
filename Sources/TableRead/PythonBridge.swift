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

    /// Called with each Python stderr line. Set by AppState to route Python output to the debug log.
    nonisolated(unsafe) var onPythonLog: (@Sendable (String) -> Void)?

    init() {
        repositoryRoot = Self.findRepositoryRoot()
    }

    nonisolated private func emitPythonLog(_ line: String) {
        guard let handler = onPythonLog else { return }
        handler(line)
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

        // 1. Path baked into Info.plist at build time via $(SRCROOT).
        //    Points at the developer's source tree, so a build run from Xcode uses
        //    the LIVE backend (no rebuild needed for parser edits). It MUST be
        //    validated: on any other machine the developer's path does not exist,
        //    and trusting it blindly was exactly why a distributed .app could not
        //    find the worker. When it is invalid we fall through to the bundled copy
        //    below. (On the dev machine the path is real, so the existence check is
        //    cheap and needs no access the app does not already have to read scripts.)
        if let baked = Bundle.main.infoDictionary?["TRRepoRoot"] as? String,
           !baked.isEmpty {
            let url = URL(fileURLWithPath: baked).standardizedFileURL
            if valid(url) { return url }
        }

        // 2. Bundled inside a .app (packaged distribution) — the fallback that makes
        //    distributed builds work on machines without the developer's source tree.
        //    audio_worker.py lives at Contents/Resources/backend/audio_worker.py;
        //    return Contents/Resources/ so backend/audio_worker.py resolves correctly.
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

    func parse(pdf: URL, formatProfile: FormatProfile? = nil) async throws -> ScriptSummary {
        var payload: [String: Any] = ["command": "parse", "pdfPath": pdf.path]
        if let formatProfile { payload["formatProfile"] = try jsonDict(formatProfile) }
        let response: WorkerEnvelope<ScriptSummary> = try await request(payload)
        guard let script = response.script else { throw PythonBridgeError.badResponse }
        return script
    }

    func voices(
        engine: EngineKind, pdf: URL?, formatProfile: FormatProfile? = nil
    ) async throws -> (voices: [VoiceSummary], autoAssign: [String: String]) {
        var payload: [String: Any] = ["command": "voices", "engine": engine.id]
        if let pdf {
            payload["pdfPath"] = pdf.path
        }
        if let formatProfile { payload["formatProfile"] = try jsonDict(formatProfile) }
        let data = try await rawRequest(payload)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VoicesResponse.self, from: data)
        guard decoded.ok else {
            throw PythonBridgeError.failed(decoded.error ?? "Worker failed.")
        }
        return (decoded.voices ?? [], decoded.autoAssign ?? [:])
    }

    func estimateOpenAI(
        pdf: URL, sceneNumbers: [Int], formatProfile: FormatProfile? = nil
    ) async throws -> OpenAIEstimate {
        var payload: [String: Any] = [
            "command": "estimateOpenAI",
            "pdfPath": pdf.path,
            "sceneNumbers": sceneNumbers,
        ]
        if let formatProfile { payload["formatProfile"] = try jsonDict(formatProfile) }
        let response: WorkerEnvelope<OpenAIEstimate> = try await request(payload)
        guard let estimate = response.estimate else { throw PythonBridgeError.badResponse }
        return estimate
    }

    /// Returns a mapping of scene number → SceneOutputInfo indicating whether
    /// an output .m4a already exists for each scene.
    func checkOutputFiles(
        pdf: URL, outputDir: URL, formatProfile: FormatProfile? = nil
    ) async throws -> [Int: SceneOutputInfo] {
        var payload: [String: Any] = [
            "command": "checkOutputFiles",
            "pdfPath": pdf.path,
            "outputDir": outputDir.path,
        ]
        if let formatProfile { payload["formatProfile"] = try jsonDict(formatProfile) }
        let data = try await rawRequest(payload)

        // Response is {"ok": true, "scenes": {"1": {...}, "2": {...}, ...}}
        struct CheckResponse: Decodable {
            var ok: Bool
            var error: String?
            var scenes: [String: SceneOutputInfo]?
        }

        let decoded = try JSONDecoder().decode(CheckResponse.self, from: data)
        guard decoded.ok, let rawScenes = decoded.scenes else {
            throw PythonBridgeError.failed(decoded.error ?? "checkOutputFiles failed")
        }
        // Convert string keys to Int
        return Dictionary(uniqueKeysWithValues: rawScenes.compactMap { key, val in
            guard let n = Int(key) else { return nil }
            return (n, val)
        })
    }

    func generate(
        pdf: URL,
        outputDirectory: URL,
        engine: EngineKind,
        sceneNumbers: [Int],
        assignment: [String: String] = [:],
        apiKey: String? = nil,
        userAddedElements: [String: [UserAddedElement]] = [:],
        corrections: [ParserCorrection] = [],
        formatProfile: FormatProfile? = nil,
        onEvent: @escaping @MainActor (GenerationEvent) -> Void
    ) async throws {
        var payload: [String: Any] = [
            "command": "generate",
            "pdfPath": pdf.path,
            "outputDir": outputDirectory.path,
            "engine": engine.id,
            "sceneNumbers": sceneNumbers,
        ]
        if let formatProfile { payload["formatProfile"] = try jsonDict(formatProfile) }
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
        if !corrections.isEmpty {
            // Serialize corrections for Python: keyed by sceneNumber + text prefix
            var correctionList: [[String: Any]] = []
            for c in corrections {
                // c.textKey is the raw element text (not the full dict-key).
                // Python matches on el.text[:60], so truncate to the same 60-char prefix.
                let textPrefix = String(c.textKey.prefix(60))
                var dict: [String: Any] = [
                    "sceneNumber": c.sceneNumber,
                    "textPrefix": textPrefix,
                    "markedAsNoise": c.markedAsNoise,
                ]
                if let kind = c.correctedKind { dict["correctedKind"] = kind }
                if let speaker = c.correctedSpeaker { dict["correctedSpeaker"] = speaker }
                if let text = c.correctedText, !text.isEmpty { dict["correctedText"] = text }
                if let os = c.correctedOverlapSpeakers, !os.isEmpty { dict["correctedOverlapSpeakers"] = os }
                if let ot = c.correctedOverlapTexts, !ot.isEmpty { dict["correctedOverlapTexts"] = ot }
                if let partnerKey = c.manualOverlapPartnerKey { dict["manualOverlapPartnerKey"] = partnerKey }
                if let removedIdx = c.removedVoiceIndex { dict["removedVoiceIndex"] = removedIdx }
                correctionList.append(dict)
            }
            payload["corrections"] = correctionList
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

    /// Raw sample blocks for the format calibration UI — pre-classification.
    func sampleBlocks(pdf: URL, maxPages: Int = 12, maxBlocks: Int = 200) async throws -> (roles: [String], blocks: [SampleBlock]) {
        struct SampleBlocksResponse: Decodable {
            var ok: Bool
            var error: String?
            var roles: [String]?
            var blocks: [SampleBlock]?
        }
        let data = try await rawRequest([
            "command": "sampleBlocks",
            "pdfPath": pdf.path,
            "maxPages": maxPages,
            "maxBlocks": maxBlocks,
        ])
        let decoded = try JSONDecoder().decode(SampleBlocksResponse.self, from: data)
        guard decoded.ok else {
            throw PythonBridgeError.failed(decoded.error ?? "sampleBlocks failed")
        }
        return (decoded.roles ?? [], decoded.blocks ?? [])
    }

    /// Derives a FormatProfile from user-tagged sample blocks.
    func deriveFormatProfile(pdf: URL, examples: [TaggedBlockExample]) async throws -> FormatProfile {
        struct DeriveResponse: Decodable {
            var ok: Bool
            var error: String?
            var formatProfile: FormatProfile?
        }
        let examplesPayload = try examples.map { try jsonDict($0) }
        let data = try await rawRequest([
            "command": "deriveFormatProfile",
            "pdfPath": pdf.path,
            "examples": examplesPayload,
        ])
        let decoded = try JSONDecoder().decode(DeriveResponse.self, from: data)
        guard decoded.ok, let profile = decoded.formatProfile else {
            throw PythonBridgeError.failed(decoded.error ?? "deriveFormatProfile failed")
        }
        return profile
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

    /// Terminates an in-progress engine install (pip subprocess).
    func cancelInstall() {
        // installEngine uses streamRequest, which stores the active process in
        // generationProcess (same slot, one stream at a time).
        generationProcess?.terminate()
        generationProcess = nil
    }

    // MARK: - Process management

    private var generationProcess: Process?

    // MARK: - Private helpers

    /// The embedded Python interpreter inside the app bundle, if present.
    /// Returns nil when running in dev mode (Xcode / swift run).
    private var bundledPython: URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/python/bin/python3")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// ~/Library/Application Support/TableRead/python-packages
    /// Used as the pip --target for optional engine installs (Kokoro, Piper)
    /// so they land outside the signed bundle and survive app updates.
    private var userPackagesDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TableRead/python-packages")
    }

    private func python(root: URL) -> String {
        let fm = FileManager.default
        // 1. Bundled Python (production .app)
        if let bundled = bundledPython { return bundled.path }
        // 2. Venv alongside the repo root (development / swift run)
        for name in [".venv/bin/python3", ".venv/bin/python"] {
            let p = root.appendingPathComponent(name).path
            if fm.fileExists(atPath: p) { return p }
        }
        // 3. Fall back to whatever python3 is on PATH
        return "python3"
    }

    private func workerURL() throws -> URL {
        // Bundled inside the .app
        if let bundled = Bundle.main.url(forResource: "audio_worker",
                                          withExtension: "py",
                                          subdirectory: "backend") {
            return bundled
        }
        // Dev: repo root
        let worker = repositoryRoot.appendingPathComponent("backend/audio_worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw PythonBridgeError.workerMissing
        }
        return worker
    }

    /// Environment variables to set on every worker process.
    /// When running from the bundled .app, TABLEREAD_PACKAGES points to the
    /// user-writable site-packages directory for optional engines.
    private var workerEnvironment: [String: String]? {
        guard bundledPython != nil else { return nil }   // dev: inherit parent env
        let pkgsPath = userPackagesDir.path
        // Ensure the directory exists so pip can install into it immediately.
        try? FileManager.default.createDirectory(at: userPackagesDir,
                                                  withIntermediateDirectories: true)
        return [
            "TABLEREAD_PACKAGES": pkgsPath,
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }

    /// Encodes a Codable value into a `[String: Any]` dict suitable for a
    /// rawRequest payload (which is serialized via JSONSerialization, not
    /// JSONEncoder, so a Codable value can't be dropped in directly).
    private func jsonDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PythonBridgeError.badResponse
        }
        return dict
    }

    /// Run the worker synchronously, return stdout as Data.
    private func rawRequest(_ payload: [String: Any]) async throws -> Data {
        let worker = try workerURL()
        let root = repositoryRoot
        let py = python(root: root)
        let env = workerEnvironment
        let requestData = try JSONSerialization.data(withJSONObject: payload)

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [py, worker.path]
            // Neutral CWD — avoids a Documents TCC prompt when the repo lives
            // inside ~/Documents. The worker uses absolute paths throughout.
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            if let env { process.environment = env }

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
            // Forward Python stderr to the Xcode console and the in-app debug log.
            if let errText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                errText.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach {
                    print("[py] \($0)")
                    self.emitPythonLog($0)
                }
            }
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
        let env = workerEnvironment
        let requestData = try JSONSerialization.data(withJSONObject: payload)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [py, worker.path]
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                if let env { process.environment = env }

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
                    // Forward Python stderr to the Xcode console and in-app debug log.
                    stderr.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach {
                        print("[py] \($0)")
                        self.emitPythonLog($0)
                    }

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
