#if os(iOS)
import Foundation

// MARK: - Voice info

struct IOSVoiceInfo: Identifiable, Sendable, Hashable {
    let id: String
    let label: String
    let gender: String?
    let locale: String?
    let note: String?

    var display: String {
        var parts = [label]
        if let g = gender { parts.append("(\(g))") }
        if let l = locale { parts.append(l) }
        if let n = note { parts.append("– \(n)") }
        return parts.joined(separator: " ")
    }

    func asVoiceSummary() -> VoiceSummary {
        VoiceSummary(
            id: id, label: label, gender: gender,
            locale: locale, note: note, display: display
        )
    }
}

// MARK: - Errors

enum IOSTTSError: LocalizedError {
    case notAvailable
    case synthesisFailure(String)
    case voiceNotFound(String)
    case modelNotLoaded
    case downloadRequired(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "TTS engine is not available on this device."
        case .synthesisFailure(let msg):
            return "Synthesis failed: \(msg)"
        case .voiceNotFound(let id):
            return "Voice '\(id)' not found."
        case .modelNotLoaded:
            return "TTS model is not loaded. Download it first."
        case .downloadRequired(let name):
            return "\(name) must be downloaded before use."
        }
    }
}

// MARK: - Protocol

protocol IOSTTSEngine: Sendable {
    var name: String { get }
    var audioExtension: String { get }

    func isAvailable() -> Bool
    func listVoices() -> [IOSVoiceInfo]

    /// Synthesize `text` using `voiceID` and write audio to `outputURL`.
    /// The output format matches `audioExtension` (.caf for system, .wav for Kokoro).
    func synthesize(text: String, voiceID: String, outputURL: URL) async throws
}
#endif
