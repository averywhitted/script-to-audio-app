import Foundation
import SwiftUI

enum WorkflowStep: String, CaseIterable, Identifiable {
    case importScript = "Import"
    case review = "Review"
    case cast = "Cast"
    case generate = "Generate"

    var id: String { rawValue }
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

    var id: Int { number }
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
