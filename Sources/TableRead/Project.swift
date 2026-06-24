import Foundation

struct Project: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastOpenedAt: Date
    /// Filename (not full path) of the PDF inside the project folder.
    var pdfFilename: String
    var scriptTitle: String
    var voiceAssignment: [String: String]
    var characterGenderOverrides: [String: String]
    var corrections: [String: ParserCorrection]
    var sceneTitleOverrides: [String: [Int: String]]
    var userAddedElements: [String: [UserAddedElement]]
    var selectedEngine: String
    var renderedScenes: [Int]

    /// Transient: absolute URL of the project folder on disk. Not persisted.
    var folderURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastOpenedAt, pdfFilename, scriptTitle
        case voiceAssignment, characterGenderOverrides, corrections
        case sceneTitleOverrides, userAddedElements, selectedEngine, renderedScenes
    }

    var pdfURL: URL? {
        folderURL?.appendingPathComponent(pdfFilename)
    }

    var displayDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: lastOpenedAt)
    }
}

extension Project {
    static func new(name: String, folderURL: URL, engine: EngineKind = .macOS) -> Project {
        Project(
            id: UUID(),
            name: name,
            createdAt: Date(),
            lastOpenedAt: Date(),
            pdfFilename: "",
            scriptTitle: "",
            voiceAssignment: [:],
            characterGenderOverrides: [:],
            corrections: [:],
            sceneTitleOverrides: [:],
            userAddedElements: [:],
            selectedEngine: engine.rawValue,
            renderedScenes: [],
            folderURL: folderURL
        )
    }
}

// MARK: - Codable helpers

extension JSONEncoder {
    static var projectEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var projectDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
