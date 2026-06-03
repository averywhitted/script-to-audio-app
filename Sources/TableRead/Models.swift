import Foundation
import SwiftUI

enum WorkflowStep: String, CaseIterable, Identifiable {
    case importScript = "Import"
    case review = "Review"
    case cast = "Cast"
    case generate = "Generate"

    var id: String { rawValue }

    var number: Int {
        switch self {
        case .importScript: 1
        case .review: 2
        case .cast: 3
        case .generate: 4
        }
    }
}

enum EngineKind: String, CaseIterable, Identifiable {
    case macOS
    case kokoro
    case piper
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: "macOS Voices"
        case .kokoro: "Kokoro Local"
        case .piper: "Piper Local"
        case .openAI: "OpenAI TTS"
        }
    }

    var subtitle: String {
        switch self {
        case .macOS: "Built in, free, offline"
        case .kokoro: "Recommended offline neural voices"
        case .piper: "Small, fast offline voices"
        case .openAI: "Cloud quality, API key and limits"
        }
    }

    /// Whether this engine is actually wired up in the Python backend.
    var isSupported: Bool {
        switch self {
        case .macOS, .openAI, .kokoro: true
        case .piper: false
        }
    }

    /// Message shown in the download confirmation alert.
    var downloadDescription: String {
        switch self {
        case .macOS:
            "macOS voices are built in and need no download."
        case .kokoro:
            "Kokoro uses an Apache-licensed neural model (~88 MB) that downloads automatically from GitHub releases on first use. Your internet connection is needed only for that initial download — after that it works fully offline."
        case .piper:
            "Piper is coming soon."
        case .openAI:
            "OpenAI TTS is a cloud service. Enter your API key on the next screen — no download required."
        }
    }

    var detail: String {
        switch self {
        case .macOS:
            "No download, no quota, no setup. Best reliability and privacy."
        case .kokoro:
            "High-quality local speech with Apache-licensed weights. Download voices on demand instead of bundling them all."
        case .piper:
            "Very practical ONNX voices. Smaller and faster, with quality below Kokoro."
        case .openAI:
            "Good cloud quality, but full scripts can be slow or blocked by request limits. Always preflight first."
        }
    }

    var symbol: String {
        switch self {
        case .macOS: "desktopcomputer"
        case .kokoro: "waveform"
        case .piper: "bolt.horizontal"
        case .openAI: "cloud"
        }
    }

    var defaultSizeLabel: String {
        switch self {
        case .macOS: "Built in"
        case .kokoro: "~115 MB after install"
        case .piper: "Not installed"
        case .openAI: "Cloud service"
        }
    }
}

struct ScriptSummary: Codable, Equatable, Sendable {
    var title: String
    var sceneCount: Int
    var characterCount: Int
    var lineCount: Int
    var characters: [CharacterSummary]
    var scenes: [SceneSummary]
}

struct CharacterSummary: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var genderHint: String?
    var roleHint: String?

    var id: String { name }
}

struct SceneSummary: Codable, Equatable, Identifiable, Sendable {
    var number: Int
    var title: String
    var elementCount: Int
    var elements: [SceneElementSummary]

    var id: Int { number }
}

struct SceneElementSummary: Codable, Equatable, Identifiable, Sendable {
    var kind: String
    var speaker: String?
    var text: String

    var id: String { "\(kind)-\(speaker ?? "narrator")-\(text.prefix(24))" }

    var displaySpeaker: String {
        if kind == "stage_direction" || kind == "parenthetical" { return "Narrator" }
        return speaker ?? "Narrator"
    }

    var kindLabel: String {
        switch kind {
        case "dialog": "Dialog"
        case "stage_direction": "Narration"
        case "parenthetical": "Aside"
        default: kind
        }
    }
}

struct OpenAIEstimate: Codable, Equatable, Sendable {
    var requestCount: Int
    var requestsPerMinute: Int
    var minimumSeconds: Int

    var durationText: String {
        let minutes = max(1, minimumSeconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct VoiceLibraryItem: Identifiable {
    var id: EngineKind
    var installed: Bool
    var size: String
    var note: String
}

struct RecentScript: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var title: String
    var lastOpened: Date

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
}

struct EngineStatus: Codable, Equatable, Sendable {
    var installed: Bool
    var sizeBytes: Int
    var sizeLabel: String
    var canUninstall: Bool
}

struct EngineStatusResponse: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var engines: [String: EngineStatus]?
}

struct BasicWorkerResponse: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var message: String?
    var path: String?
}

struct EngineDownloadPrompt: Identifiable {
    var id: EngineKind { engine }
    var engine: EngineKind
}

struct GenerationEvent: Codable, Sendable {
    var event: String
    var level: String?
    var message: String?
    var sceneIndex: Int?
    var totalScenes: Int?
    var sceneTitle: String?
    var elementIndex: Int?
    var totalElements: Int?
    var outputDir: String?
    var files: [String]?
    var errors: [String]?
    var skippedScenes: [String]?
    var seconds: Double?
}

/// Matches NARRATOR_KEY in voice_assignment.py
let NARRATOR_KEY = "__NARRATOR__"

struct VoiceSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var gender: String?
    var locale: String?
    var note: String?
    var display: String
}

struct VoicesResponse: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var voices: [VoiceSummary]?
    var autoAssign: [String: String]?
}

struct GenerationLogLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var style: LogStyle
}

enum LogStyle: Equatable {
    case info
    case success
    case warning
    case error
}

// MARK: - User-added elements

/// A dialogue/narration line manually inserted by the user after a parsed element.
/// Stored locally alongside corrections; injected into the generation payload so
/// the Python backend synthesises them in the right position.
struct UserAddedElement: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var pdfPath: String
    var sceneNumber: Int
    /// `element.text.prefix(60)` of the parsed element this line follows.
    var afterElementTextKey: String
    var speaker: String       // empty string = narrator
    var text: String
    var kind: String          // "dialog", "stage_direction", "parenthetical"
    var timestamp: Date
}

/// Unified element type used in the Review scene expansion —
/// merges parsed elements with any user-inserted lines.
enum MergedSceneElement: Identifiable {
    case parsed(SceneElementSummary)
    case added(UserAddedElement)

    var id: String {
        switch self {
        case .parsed(let e): "p-\(e.id)"
        case .added(let e):  "a-\(e.id.uuidString)"
        }
    }
}

// MARK: - Parser corrections

/// A user-supplied correction to a single parsed script element.
///
/// Corrections are stored locally and optionally contributed anonymously
/// to help improve the parser for everyone.
struct ParserCorrection: Codable, Equatable, Sendable {
    /// Stable identifier: first 60 chars of element text (enough for uniqueness within a scene).
    var textKey: String
    var pdfIdentifier: String   // URL path — corrections follow the file
    var sceneNumber: Int
    var originalKind: String
    var originalSpeaker: String?
    var correctedKind: String?        // nil = keep original
    var correctedSpeaker: String?     // nil = keep original; "" = narrator (no speaker)
    var correctedText: String?        // nil = keep original
    var markedAsNoise: Bool           // true = exclude this element entirely
    var timestamp: Date
    var contributed: Bool             // user opted to share this correction
    var uploaded: Bool = false        // true once successfully POSTed to the corrections endpoint
}

/// Privacy-safe version of ParserCorrection for upload — no file paths or personal identifiers.
struct AnonymousCorrection: Encodable, Sendable {
    var sceneNumber: Int
    var originalKind: String
    var originalSpeaker: String?
    var originalText: String        // first 60 chars of the original element text
    var correctedKind: String?
    var correctedSpeaker: String?
    var correctedText: String?
    var markedAsNoise: Bool
    var appVersion: String
}

extension ParserCorrection {
    func anonymized(appVersion: String) -> AnonymousCorrection {
        // textKey format: "pdfPath|sceneNumber|originalText(60chars)"
        let originalText = textKey.components(separatedBy: "|").last ?? ""
        return AnonymousCorrection(
            sceneNumber: sceneNumber,
            originalKind: originalKind,
            originalSpeaker: originalSpeaker,
            originalText: originalText,
            correctedKind: correctedKind,
            correctedSpeaker: correctedSpeaker,
            correctedText: correctedText,
            markedAsNoise: markedAsNoise,
            appVersion: appVersion
        )
    }
}

extension ParserCorrection {
    /// Key used to look up a correction for a given element.
    static func key(pdfIdentifier: String, sceneNumber: Int, text: String) -> String {
        "\(pdfIdentifier)|\(sceneNumber)|\(String(text.prefix(60)))"
    }
}

extension ScriptSummary {
    /// Apply a map of corrections in-place, returning the modified summary.
    func applying(_ corrections: [String: ParserCorrection], pdfPath: String) -> ScriptSummary {
        var copy = self
        copy.scenes = scenes.map { scene in
            var sc = scene
            sc.elements = scene.elements.compactMap { el in
                let k = ParserCorrection.key(
                    pdfIdentifier: pdfPath,
                    sceneNumber: scene.number,
                    text: el.text
                )
                guard let fix = corrections[k] else { return el }
                if fix.markedAsNoise { return nil }
                var updated = el
                if let kind = fix.correctedKind { updated.kind = kind }
                if let speaker = fix.correctedSpeaker {
                    updated.speaker = speaker.isEmpty ? nil : speaker
                }
                if let text = fix.correctedText, !text.isEmpty { updated.text = text }
                return updated
            }
            return sc
        }
        // Recount after filtering noise
        copy.lineCount = copy.scenes.reduce(0) { $0 + $1.elements.count }
        return copy
    }
}
