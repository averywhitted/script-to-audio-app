#if os(iOS)
import Foundation
import PDFKit

// MARK: - PDFKit-based screenplay parser
//
// Mirrors the format detection and element extraction logic from parser.py.
// Supported formats: play (ALL-CAPS speaker), colon_play (SPEAKER:), scene_n (INT./EXT.),
// dash_dialog (SPEAKER – dialog). The heist format requires pdfplumber layout data not
// available via PDFKit and is not supported in the iOS parser.

struct ScreenplayParser {
    // MARK: - Public entry point

    /// Parse the PDF at `url` and return a `ScriptSummary` compatible with the
    /// existing macOS app models. Throws if the PDF cannot be opened.
    static func parse(url: URL) throws -> ScriptSummary {
        guard let doc = PDFDocument(url: url) else {
            throw ScreenplayParserError.cannotOpenPDF(url.lastPathComponent)
        }

        let text = extractText(from: doc)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        // Normalize doubled characters (some PDF exporters double every glyph)
        let normalized = lines.map { normalizeDoubled($0) }

        let format = detectFormat(lines: normalized)
        var scenes: [SceneSummary]
        var characters: [CharacterSummary]

        switch format {
        case .play:
            (scenes, characters) = parsePlay(lines: normalized)
        case .colonPlay:
            (scenes, characters) = parseColonPlay(lines: normalized)
        case .sceneN:
            (scenes, characters) = parseSceneN(lines: normalized)
        case .dashDialog:
            (scenes, characters) = parseDashDialog(lines: normalized)
        }

        let lineCount = scenes.reduce(0) { $0 + $1.elements.count }

        return ScriptSummary(
            title: inferTitle(lines: normalized),
            sceneCount: scenes.count,
            characterCount: characters.count,
            lineCount: lineCount,
            characters: characters,
            scenes: scenes
        )
    }

    // MARK: - Text extraction

    private static func extractText(from doc: PDFDocument) -> String {
        (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Doubled-character normalization

    /// "VVIINNNNYY" → "VINNY" — handles PDFs where each character is doubled.
    private static func normalizeDoubled(_ line: String) -> String {
        guard line.count >= 4 else { return line }
        var chars = Array(line)
        var doubling = true
        for i in stride(from: 0, to: chars.count - 1, by: 2) {
            if chars[i] != chars[i + 1] { doubling = false; break }
        }
        guard doubling else { return line }
        return String(stride(from: 0, to: chars.count, by: 2).map { chars[$0] })
    }

    // MARK: - Format detection

    private enum Format { case play, colonPlay, sceneN, dashDialog }

    private static func detectFormat(lines: [String]) -> Format {
        var colonCount = 0
        var intExtCount = 0
        var dashCount = 0

        for line in lines.prefix(200) {
            if line.hasPrefix("INT.") || line.hasPrefix("EXT.") || line.hasPrefix("INT/EXT") {
                intExtCount += 1
            }
            let colonMatch = line.range(of: #"^[A-Z][A-Z\s]{1,30}:\s"#, options: .regularExpression)
            if colonMatch != nil { colonCount += 1 }
            let dashMatch = line.range(of: #"^[A-Z][A-Z\s]{1,30}\s[–—]\s"#, options: .regularExpression)
            if dashMatch != nil { dashCount += 1 }
        }

        if intExtCount >= 2 { return .sceneN }
        if colonCount > dashCount && colonCount >= 3 { return .colonPlay }
        if dashCount >= 3 { return .dashDialog }
        return .play
    }

    // MARK: - Play format parser

    private static func parsePlay(lines: [String]) -> ([SceneSummary], [CharacterSummary]) {
        let scenePattern = try! NSRegularExpression(
            pattern: #"^(?:SCENE\s+\d+|ACT\s+[IVX\d]+|PART\s+\d+|\d+\.|[-–]\s*\d+\s*[-–])\b"#,
            options: .caseInsensitive
        )
        let allCapsPattern = try! NSRegularExpression(pattern: #"^[A-Z][A-Z\s']{2,30}$"#)

        var scenes: [SceneSummary] = []
        var characterCounts: [String: Int] = [:]
        var currentElements: [SceneElementSummary] = []
        var currentTitle = "Opening"
        var sceneNumber = 0
        var currentSpeaker: String?
        var dialogBuffer: [String] = []

        func flushDialog() {
            guard let spk = currentSpeaker, !dialogBuffer.isEmpty else { return }
            let text = dialogBuffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                currentElements.append(SceneElementSummary(kind: "dialog", speaker: spk, text: text))
                characterCounts[spk, default: 0] += 1
            }
            dialogBuffer = []
            currentSpeaker = nil
        }

        func flushScene() {
            flushDialog()
            if !currentElements.isEmpty {
                sceneNumber += 1
                scenes.append(SceneSummary(
                    number: sceneNumber,
                    title: currentTitle,
                    elementCount: currentElements.count,
                    elements: currentElements
                ))
                currentElements = []
            }
        }

        for line in lines {
            guard !line.isEmpty else { continue }

            // Scene marker?
            let range = NSRange(line.startIndex..., in: line)
            if scenePattern.firstMatch(in: line, range: range) != nil {
                flushScene()
                currentTitle = line.trimmingCharacters(in: .whitespaces)
                continue
            }

            // Stage direction in parens?
            if line.hasPrefix("(") && line.hasSuffix(")") {
                flushDialog()
                let text = String(line.dropFirst().dropLast())
                currentElements.append(SceneElementSummary(kind: "parenthetical", speaker: currentSpeaker, text: text))
                continue
            }

            // ALL-CAPS speaker cue?
            if allCapsPattern.firstMatch(in: line, range: range) != nil, line.count <= 32 {
                flushDialog()
                currentSpeaker = line
                continue
            }

            // Accumulate dialog or narration
            if currentSpeaker != nil {
                dialogBuffer.append(line)
            } else {
                currentElements.append(SceneElementSummary(kind: "stage_direction", speaker: nil, text: line))
            }
        }

        flushScene()

        let characters = characterCounts.map { name, _ in
            CharacterSummary(name: name, genderHint: nil, roleHint: nil)
        }.sorted { $0.name < $1.name }

        return (scenes, characters)
    }

    // MARK: - Colon play format (SPEAKER: dialog on same line)

    private static func parseColonPlay(lines: [String]) -> ([SceneSummary], [CharacterSummary]) {
        let colonPattern = try! NSRegularExpression(pattern: #"^([A-Z][A-Z\s']{1,30}):\s+(.+)$"#)
        let scenePattern = try! NSRegularExpression(
            pattern: #"^(?:SCENE|ACT|PART)\s+\S+"#,
            options: .caseInsensitive
        )

        var scenes: [SceneSummary] = []
        var characterCounts: [String: Int] = [:]
        var currentElements: [SceneElementSummary] = []
        var currentTitle = "Opening"
        var sceneNumber = 0

        func flushScene() {
            if !currentElements.isEmpty {
                sceneNumber += 1
                scenes.append(SceneSummary(
                    number: sceneNumber, title: currentTitle,
                    elementCount: currentElements.count, elements: currentElements
                ))
                currentElements = []
            }
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)

            if scenePattern.firstMatch(in: line, range: range) != nil {
                flushScene()
                currentTitle = line
                continue
            }

            if let m = colonPattern.firstMatch(in: line, range: range) {
                let speaker = (line as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let dialog = (line as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                currentElements.append(SceneElementSummary(kind: "dialog", speaker: speaker, text: dialog))
                characterCounts[speaker, default: 0] += 1
            } else {
                currentElements.append(SceneElementSummary(kind: "stage_direction", speaker: nil, text: line))
            }
        }

        flushScene()
        let characters = characterCounts.keys.sorted().map { CharacterSummary(name: $0) }
        return (scenes, characters)
    }

    // MARK: - Screenplay format (INT./EXT. headers)

    private static func parseSceneN(lines: [String]) -> ([SceneSummary], [CharacterSummary]) {
        let headerPattern = try! NSRegularExpression(
            pattern: #"^(?:INT\.|EXT\.|INT/EXT\.)\s+.+"#,
            options: .caseInsensitive
        )
        let allCaps = try! NSRegularExpression(pattern: #"^[A-Z][A-Z\s'()]{2,30}$"#)

        var scenes: [SceneSummary] = []
        var characterCounts: [String: Int] = [:]
        var currentElements: [SceneElementSummary] = []
        var currentTitle = "Opening"
        var sceneNumber = 0
        var currentSpeaker: String?
        var dialogBuffer: [String] = []

        func flushDialog() {
            guard let spk = currentSpeaker, !dialogBuffer.isEmpty else { return }
            let text = dialogBuffer.joined(separator: " ")
            currentElements.append(SceneElementSummary(kind: "dialog", speaker: spk, text: text))
            characterCounts[spk, default: 0] += 1
            dialogBuffer = []
            currentSpeaker = nil
        }

        func flushScene() {
            flushDialog()
            if !currentElements.isEmpty {
                sceneNumber += 1
                scenes.append(SceneSummary(
                    number: sceneNumber, title: currentTitle,
                    elementCount: currentElements.count, elements: currentElements
                ))
                currentElements = []
            }
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)

            if headerPattern.firstMatch(in: line, range: range) != nil {
                flushScene()
                currentTitle = line
                continue
            }

            if line.hasPrefix("(") {
                flushDialog()
                currentElements.append(SceneElementSummary(kind: "parenthetical", speaker: currentSpeaker, text: line))
                continue
            }

            if allCaps.firstMatch(in: line, range: range) != nil, line.count <= 40 {
                flushDialog()
                currentSpeaker = line
                continue
            }

            if currentSpeaker != nil {
                dialogBuffer.append(line)
            } else {
                currentElements.append(SceneElementSummary(kind: "stage_direction", speaker: nil, text: line))
            }
        }

        flushScene()
        let characters = characterCounts.keys.sorted().map { CharacterSummary(name: $0) }
        return (scenes, characters)
    }

    // MARK: - Dash dialog format (SPEAKER – text)

    private static func parseDashDialog(lines: [String]) -> ([SceneSummary], [CharacterSummary]) {
        let dashPattern = try! NSRegularExpression(pattern: #"^([A-Z][A-Z\s']{1,30})\s+[–—]\s+(.+)$"#)
        let scenePattern = try! NSRegularExpression(pattern: #"^\d+\.\s*$"#)

        var scenes: [SceneSummary] = []
        var characterCounts: [String: Int] = [:]
        var currentElements: [SceneElementSummary] = []
        var sceneNumber = 0

        func flushScene() {
            if !currentElements.isEmpty {
                sceneNumber += 1
                scenes.append(SceneSummary(
                    number: sceneNumber, title: "Scene \(sceneNumber)",
                    elementCount: currentElements.count, elements: currentElements
                ))
                currentElements = []
            }
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)

            if scenePattern.firstMatch(in: line, range: range) != nil {
                flushScene()
                continue
            }

            if let m = dashPattern.firstMatch(in: line, range: range) {
                let speaker = (line as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let dialog = (line as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                currentElements.append(SceneElementSummary(kind: "dialog", speaker: speaker, text: dialog))
                characterCounts[speaker, default: 0] += 1
            } else {
                currentElements.append(SceneElementSummary(kind: "stage_direction", speaker: nil, text: line))
            }
        }

        flushScene()
        let characters = characterCounts.keys.sorted().map { CharacterSummary(name: $0) }
        return (scenes, characters)
    }

    // MARK: - Title inference

    private static func inferTitle(lines: [String]) -> String {
        for line in lines.prefix(20) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count >= 3 && t.count <= 60 && !t.isEmpty {
                return t
            }
        }
        return "Untitled Script"
    }
}

enum ScreenplayParserError: LocalizedError {
    case cannotOpenPDF(String)
    var errorDescription: String? {
        switch self {
        case .cannotOpenPDF(let name): "Cannot open PDF: \(name)"
        }
    }
}
#endif
