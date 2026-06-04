import Foundation
import PDFKit

// MARK: - Public Entry Point

/// Parse a screenplay PDF natively using PDFKit and return a structured summary.
func parseScreenplay(at url: URL) async throws -> ScriptSummary {
    try await Task.detached(priority: .userInitiated) {
        guard let document = PDFDocument(url: url) else {
            throw ScreenplayParseError.cannotOpenDocument
        }
        return try ScreenplayParser(document: document, pdfURL: url).parse()
    }.value
}

// MARK: - Error

enum ScreenplayParseError: LocalizedError {
    case cannotOpenDocument
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .cannotOpenDocument: return "Could not open the PDF document."
        case .emptyDocument: return "The PDF appears to be empty."
        }
    }
}

// MARK: - Private Types

private struct PElement {
    enum Kind: String { case dialog, stage_direction, parenthetical }
    var kind: Kind
    var text: String
    var speaker: String? = nil
}

private struct PScene {
    var number: Int
    var title: String
    var elements: [PElement] = []
}

private struct PScript {
    var title: String
    var characters: [String] = []
    var scenes: [PScene] = []
}

// MARK: - Parser

private final class ScreenplayParser {
    private let document: PDFDocument
    private let pdfURL: URL

    init(document: PDFDocument, pdfURL: URL) {
        self.document = document
        self.pdfURL = pdfURL
    }

    // MARK: Parse

    func parse() throws -> ScriptSummary {
        guard document.pageCount > 0 else { throw ScreenplayParseError.emptyDocument }

        let lines = extractLines()
        guard !lines.isEmpty else { throw ScreenplayParseError.emptyDocument }

        let title = deriveTitle(from: lines)
        let heistCount = countHeistMarkers(in: lines)
        let playFmt = detectPlayFormat(in: lines)

        var script: PScript
        if playFmt == "colon_play" {
            script = parseColonPlay(lines: lines, title: title)
        } else if playFmt == "play" {
            script = parsePlay(lines: lines, title: title)
        } else if heistCount >= 2 {
            script = parseHeist(lines: lines, title: title)
        } else {
            script = parseGeneric(lines: lines, title: title)
        }

        collectCharacters(into: &script)
        return toSummary(script)
    }

    // MARK: Text Extraction

    private func extractLines() -> [String] {
        (0..<document.pageCount).flatMap { i -> [String] in
            guard let page = document.page(at: i),
                  let text = page.string else { return [] }
            return text.components(separatedBy: "\n")
        }
    }

    // MARK: Title

    private func deriveTitle(from lines: [String]) -> String {
        for line in lines.prefix(30) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3 else { continue }
            guard t.first?.isNumber == false else { continue }
            let low = t.lowercased()
            guard !low.hasPrefix("by "),
                  !low.hasPrefix("written by"),
                  !low.hasPrefix("draft") else { continue }
            return t
        }
        return pdfURL.deletingPathExtension().lastPathComponent
    }

    // MARK: Helpers

    /// Returns true if the string looks like an ALL-CAPS speaker name.
    private func isLikelySpeaker(_ s: String) -> Bool {
        guard (2...50).contains(s.count) else { return false }
        var hasLetter = false
        let allowed = CharacterSet.uppercaseLetters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".-'"))
        for scalar in s.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                hasLetter = true
            } else if !allowed.contains(scalar) {
                return false
            }
        }
        return hasLetter
    }

    /// Returns a scene title if the line matches a known scene-heading pattern.
    private func sceneHeading(from line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        // == TITLE ==, ** TITLE **, -- TITLE --
        for (open, close) in [("==", "=="), ("**", "**"), ("--", "--")] {
            if t.hasPrefix(open), t.hasSuffix(close), t.count > open.count * 2 {
                let inner = String(t.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { return inner }
            }
        }

        // SCENE N / ACT N (with optional subtitle)
        if t.range(of: #"^(?:SCENE|Scene|ACT|Act)\s+\S+"#, options: .regularExpression) != nil {
            return t
        }

        // Screenplay sluglines: INT. ... / EXT. ...
        if t.hasPrefix("INT.") || t.hasPrefix("EXT.") || t.hasPrefix("INT/EXT.") {
            return t
        }

        return nil
    }

    // MARK: Format Detection

    private func detectPlayFormat(in lines: [String]) -> String? {
        var capsCount = 0
        var colonCount = 0
        for line in lines.prefix(300) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.count <= 60 else { continue }
            if let colonIdx = t.firstIndex(of: ":") {
                let before = String(t[t.startIndex..<colonIdx])
                if isLikelySpeaker(before), before.count >= 2 {
                    colonCount += 1
                }
            } else if isLikelySpeaker(t) {
                capsCount += 1
            }
        }
        if colonCount >= 5, colonCount > capsCount { return "colon_play" }
        if capsCount >= 5 { return "play" }
        return nil
    }

    private func countHeistMarkers(in lines: [String]) -> Int {
        lines.filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("==") && t.hasSuffix("==") && t.count > 4
        }.count
    }

    // MARK: Play Parser  (ALL CAPS speaker on its own line)

    private func parsePlay(lines: [String], title: String) -> PScript {
        var scenes: [PScene] = []
        var current: PScene? = nil
        var currentSpeaker: String? = nil
        var sceneNum = 0

        func flush() { if let s = current, !s.elements.isEmpty { scenes.append(s) } }

        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            if t.isEmpty { currentSpeaker = nil; continue }

            if let heading = sceneHeading(from: t) {
                flush()
                sceneNum += 1
                current = PScene(number: sceneNum, title: heading)
                currentSpeaker = nil
                continue
            }

            if t.hasPrefix("("), t.hasSuffix(")"), t.count < 80 {
                current?.elements.append(PElement(kind: .parenthetical, text: t, speaker: currentSpeaker))
                continue
            }

            if isLikelySpeaker(t) {
                // Peek at next non-empty line: if it's also a caps line, treat current as stage direction.
                let nextT = lines[i...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !isLikelySpeaker(nextT) {
                    currentSpeaker = t
                    if current == nil {
                        sceneNum += 1
                        current = PScene(number: sceneNum, title: "Scene \(sceneNum)")
                    }
                    continue
                }
            }

            if let spk = currentSpeaker {
                current?.elements.append(PElement(kind: .dialog, text: t, speaker: spk))
            } else if current != nil {
                current?.elements.append(PElement(kind: .stage_direction, text: t))
            }
        }
        flush()

        if scenes.isEmpty {
            var scene = PScene(number: 1, title: title)
            var spk: String? = nil
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { spk = nil; continue }
                if isLikelySpeaker(t) {
                    spk = t
                } else if let s = spk {
                    scene.elements.append(PElement(kind: .dialog, text: t, speaker: s))
                } else {
                    scene.elements.append(PElement(kind: .stage_direction, text: t))
                }
            }
            if !scene.elements.isEmpty { scenes = [scene] }
        }

        return PScript(title: title, scenes: scenes)
    }

    // MARK: Colon Play Parser  (SPEAKER: dialog on the same line)

    private func parseColonPlay(lines: [String], title: String) -> PScript {
        var scenes: [PScene] = []
        var current: PScene? = nil
        var sceneNum = 0

        func flush() { if let s = current, !s.elements.isEmpty { scenes.append(s) } }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }

            if let heading = sceneHeading(from: t) {
                flush()
                sceneNum += 1
                current = PScene(number: sceneNum, title: heading)
                continue
            }

            if let colonIdx = t.firstIndex(of: ":") {
                let before = String(t[t.startIndex..<colonIdx])
                let after = String(t[t.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if isLikelySpeaker(before), !after.isEmpty {
                    if current == nil {
                        sceneNum += 1
                        current = PScene(number: sceneNum, title: "Scene \(sceneNum)")
                    }
                    current?.elements.append(PElement(kind: .dialog, text: after, speaker: before))
                    continue
                }
            }

            if current != nil {
                current?.elements.append(PElement(kind: .stage_direction, text: t))
            }
        }
        flush()

        return PScript(title: title, scenes: scenes.isEmpty ? [PScene(number: 1, title: title)] : scenes)
    }

    // MARK: Heist Parser  (== SCENE TITLE == markers)

    private func parseHeist(lines: [String], title: String) -> PScript {
        var scenes: [PScene] = []
        var current: PScene? = nil
        var sceneNum = 0
        var currentSpeaker: String? = nil

        func flush() { if let s = current, !s.elements.isEmpty { scenes.append(s) } }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { currentSpeaker = nil; continue }

            if t.hasPrefix("=="), t.hasSuffix("=="), t.count > 4 {
                flush()
                sceneNum += 1
                let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                current = PScene(number: sceneNum, title: inner)
                currentSpeaker = nil
                continue
            }

            if t.hasPrefix("("), t.hasSuffix(")"), t.count < 80 {
                current?.elements.append(PElement(kind: .parenthetical, text: t, speaker: currentSpeaker))
                continue
            }

            if isLikelySpeaker(t) {
                currentSpeaker = t
                if current == nil {
                    sceneNum += 1
                    current = PScene(number: sceneNum, title: "Scene \(sceneNum)")
                }
            } else if let spk = currentSpeaker {
                current?.elements.append(PElement(kind: .dialog, text: t, speaker: spk))
            } else if current != nil {
                current?.elements.append(PElement(kind: .stage_direction, text: t))
            }
        }
        flush()

        return PScript(title: title, scenes: scenes.isEmpty ? [PScene(number: 1, title: title)] : scenes)
    }

    // MARK: Generic Parser  (dash_dialog / SCENE N)

    private func parseGeneric(lines: [String], title: String) -> PScript {
        let dashCount = lines.prefix(100).filter {
            $0.trimmingCharacters(in: .whitespaces)
                .range(of: #"^-\s*[A-Z][A-Z '.\-]+\s+-\s+\S"#, options: .regularExpression) != nil
        }.count
        if dashCount >= 3 { return parseDashDialog(lines: lines, title: title) }

        let sceneNCount = lines.prefix(200).filter {
            $0.trimmingCharacters(in: .whitespaces)
                .range(of: #"^(?:SCENE|Scene)\s+\d+"#, options: .regularExpression) != nil
        }.count
        if sceneNCount >= 2 { return parseSceneN(lines: lines, title: title) }

        return parsePlay(lines: lines, title: title)
    }

    private func parseDashDialog(lines: [String], title: String) -> PScript {
        var scenes: [PScene] = []
        var current: PScene? = nil
        var sceneNum = 0

        func flush() { if let s = current, !s.elements.isEmpty { scenes.append(s) } }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }

            if let heading = sceneHeading(from: t) {
                flush()
                sceneNum += 1
                current = PScene(number: sceneNum, title: heading)
                continue
            }

            // "- SPEAKER - dialog text"
            if t.hasPrefix("-") {
                let inner = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let dashRange = inner.range(of: " - ") {
                    let spk = String(inner[inner.startIndex..<dashRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    let dialog = String(inner[dashRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    if isLikelySpeaker(spk), !dialog.isEmpty {
                        if current == nil {
                            sceneNum += 1
                            current = PScene(number: sceneNum, title: "Scene \(sceneNum)")
                        }
                        current?.elements.append(PElement(kind: .dialog, text: dialog, speaker: spk))
                        continue
                    }
                }
            }

            if current != nil {
                current?.elements.append(PElement(kind: .stage_direction, text: t))
            }
        }
        flush()

        return PScript(title: title, scenes: scenes.isEmpty ? [PScene(number: 1, title: title)] : scenes)
    }

    private func parseSceneN(lines: [String], title: String) -> PScript {
        var scenes: [PScene] = []
        var current: PScene? = nil
        var sceneNum = 0
        var currentSpeaker: String? = nil

        func flush() { if let s = current, !s.elements.isEmpty { scenes.append(s) } }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { currentSpeaker = nil; continue }

            if t.range(of: #"^(?:SCENE|Scene)\s+\d+"#, options: .regularExpression) != nil {
                flush()
                sceneNum += 1
                current = PScene(number: sceneNum, title: t)
                currentSpeaker = nil
                continue
            }

            if t.hasPrefix("("), t.hasSuffix(")"), t.count < 80 {
                current?.elements.append(PElement(kind: .parenthetical, text: t, speaker: currentSpeaker))
                continue
            }

            if isLikelySpeaker(t) {
                currentSpeaker = t
                if current == nil {
                    sceneNum += 1
                    current = PScene(number: sceneNum, title: "Scene \(sceneNum)")
                }
            } else if let spk = currentSpeaker {
                current?.elements.append(PElement(kind: .dialog, text: t, speaker: spk))
            } else if current != nil {
                current?.elements.append(PElement(kind: .stage_direction, text: t))
            }
        }
        flush()

        return PScript(title: title, scenes: scenes.isEmpty ? [PScene(number: 1, title: title)] : scenes)
    }

    // MARK: Characters

    private func collectCharacters(into script: inout PScript) {
        var seen = Set<String>()
        var order: [String] = []
        for scene in script.scenes {
            for elem in scene.elements {
                if let spk = elem.speaker, !spk.isEmpty, !seen.contains(spk) {
                    seen.insert(spk)
                    order.append(spk)
                }
            }
        }
        script.characters = order
    }

    // MARK: Conversion to ScriptSummary

    private func toSummary(_ script: PScript) -> ScriptSummary {
        let characters = script.characters.map {
            CharacterSummary(name: $0, genderHint: nil, roleHint: nil)
        }
        let scenes = script.scenes.map { scene -> SceneSummary in
            let elems = scene.elements.map {
                SceneElementSummary(kind: $0.kind.rawValue, speaker: $0.speaker, text: $0.text)
            }
            return SceneSummary(
                number: scene.number,
                title: scene.title,
                elementCount: elems.count,
                elements: elems
            )
        }
        return ScriptSummary(
            title: script.title,
            sceneCount: scenes.count,
            characterCount: characters.count,
            lineCount: script.scenes.reduce(0) { $0 + $1.elements.count },
            characters: characters,
            scenes: scenes
        )
    }
}
