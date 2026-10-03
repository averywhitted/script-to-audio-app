import XCTest
import CryptoKit
@testable import TableRead

// MARK: - Navigation logic

final class NavigationTests: XCTestCase {

    @MainActor func testImportAlwaysNavigable() {
        let state = AppState()
        XCTAssertTrue(state.canNavigate(to: .importScript))
    }

    @MainActor func testReviewRequiresScript() {
        let state = AppState()
        XCTAssertFalse(state.canNavigate(to: .review))
        XCTAssertFalse(state.canNavigate(to: .cast))
        XCTAssertFalse(state.canNavigate(to: .generate))
    }

    @MainActor func testNavigableAfterScriptLoaded() {
        let state = AppState()
        state.script = makeScript()
        XCTAssertTrue(state.canNavigate(to: .review))
        XCTAssertTrue(state.canNavigate(to: .cast))
        // macOS engine is always in installedEngines
        XCTAssertTrue(state.canNavigate(to: .generate))
    }

    @MainActor func testGoToUpdatesStep() {
        let state = AppState()
        state.script = makeScript()
        state.goTo(.review)
        XCTAssertEqual(state.step, .review)
    }

    @MainActor func testGoToBlockedWhenNotNavigable() {
        let state = AppState()
        // No script loaded — going to .review should be blocked
        state.goTo(.review)
        XCTAssertEqual(state.step, .importScript)
    }

    @MainActor func testNavigatingForwardFlag() {
        let state = AppState()
        state.script = makeScript()
        state.goTo(.cast)
        XCTAssertTrue(state.navigatingForward)
        state.goTo(.review)
        XCTAssertFalse(state.navigatingForward)
    }

    @MainActor func testResetForNewProject() {
        let state = AppState()
        state.script = makeScript()
        state.selectedPDF = URL(fileURLWithPath: "/tmp/test.pdf")
        state.goTo(.cast)
        state.resetForNewProject()
        XCTAssertNil(state.script)
        XCTAssertNil(state.selectedPDF)
        XCTAssertEqual(state.step, .importScript)
    }

    // MARK: Helper

    private func makeScript(sceneCount: Int = 3) -> ScriptSummary {
        let scenes = (1...sceneCount).map { n in
            SceneSummary(number: n, title: "Scene \(n)", elementCount: 2, elements: [
                SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Hello world."),
                SceneElementSummary(kind: "dialog", speaker: "BOB",   text: "Hello back."),
            ])
        }
        return ScriptSummary(
            title: "Test Script",
            sceneCount: sceneCount,
            characterCount: 2,
            lineCount: sceneCount * 2,
            characters: [
                CharacterSummary(name: "ALICE", genderHint: "F", roleHint: nil),
                CharacterSummary(name: "BOB",   genderHint: "M", roleHint: nil),
            ],
            scenes: scenes
        )
    }
}

// MARK: - Formatting helpers

final class FormatTests: XCTestCase {

    func testFormatSecondsUnderMinute() {
        XCTAssertEqual(formatSeconds(0),  "0s")
        XCTAssertEqual(formatSeconds(1),  "1s")
        XCTAssertEqual(formatSeconds(59), "59s")
    }

    func testFormatSecondsExactMinute() {
        XCTAssertEqual(formatSeconds(60),  "1m")
        XCTAssertEqual(formatSeconds(120), "2m")
    }

    func testFormatSecondsMinutesAndSeconds() {
        XCTAssertEqual(formatSeconds(90),  "1m 30s")
        XCTAssertEqual(formatSeconds(125), "2m 5s")
    }
}

// MARK: - Estimated TTS duration

final class EstimatedSecondsTests: XCTestCase {

    private func scene(words: Int) -> SceneSummary {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return SceneSummary(
            number: 1, title: "Test", elementCount: 1,
            elements: [SceneElementSummary(kind: "dialog", speaker: "A", text: text)]
        )
    }

    func testMacOSEstimate() {
        // macOS: 2.8 wps — 280 words ≈ 100s
        XCTAssertEqual(scene(words: 280).estimatedSeconds(engine: .macOS), 100)
    }

    func testKokoroFasterThanMacOS() {
        let s = scene(words: 100)
        XCTAssertLessThan(s.estimatedSeconds(engine: .kokoro),
                          s.estimatedSeconds(engine: .macOS))
    }

    func testOpenAIFastest() {
        let s = scene(words: 100)
        XCTAssertLessThan(s.estimatedSeconds(engine: .openAI),
                          s.estimatedSeconds(engine: .kokoro))
    }

    func testMinimumOneSecond() {
        // Even an empty scene should estimate at least 1s
        XCTAssertGreaterThanOrEqual(scene(words: 0).estimatedSeconds(engine: .macOS), 1)
    }
}

// MARK: - Scene element ID uniqueness

final class SceneElementIDTests: XCTestCase {

    func testDuplicateDialogLinesHaveUniqueIDs() {
        // Same speaker repeating the same short phrase (Cyrano-style). Once the
        // scene numbers its repeats, every row has its own id, so SwiftUI lists
        // keyed by id no longer drop or merge them.
        let elements = SceneSummary.numberingOccurrences([
            SceneElementSummary(kind: "dialog", speaker: "CYRANO", text: "say it"),
            SceneElementSummary(kind: "dialog", speaker: "CYRANO", text: "say it"),
            SceneElementSummary(kind: "dialog", speaker: "CYRANO", text: "say it"),
        ])
        XCTAssertEqual(elements.map(\.occurrence), [0, 1, 2])
        XCTAssertEqual(Set(elements.map(\.id)).count, 3)
    }
}

// MARK: - Corrections on repeated lines (#55)

final class DuplicateLineCorrectionTests: XCTestCase {

    private let pdf = "/tmp/echo.pdf"

    /// LOLA and ELLIOT say the same line, decoded the way a real parse arrives.
    private func echoScript() throws -> ScriptSummary {
        let json = """
        {"title":"Echo","sceneCount":1,"characterCount":0,"characters":[],"lineCount":3,"scenes":[{"number":1,"title":"One","elementCount":3,
         "elements":[{"kind":"dialog","speaker":"LOLA","text":"I'm looking at you.","confidence":1},
                     {"kind":"dialog","speaker":"ELLIOT","text":"I'm looking at you.","confidence":1},
                     {"kind":"stage_direction","text":"They stare.","confidence":1}]}]}
        """
        return try JSONDecoder().decode(ScriptSummary.self, from: Data(json.utf8))
    }

    private func correction(for el: SceneElementSummary, speaker: String) -> ParserCorrection {
        ParserCorrection(textKey: el.text, pdfIdentifier: pdf, sceneNumber: 1,
                         originalKind: el.kind, originalSpeaker: el.speaker,
                         correctedKind: nil, correctedSpeaker: speaker, correctedText: nil,
                         markedAsNoise: false, timestamp: Date(), contributed: false,
                         occurrence: el.occurrence)
    }

    func testDecodingNumbersRepeats() throws {
        let els = try echoScript().scenes[0].elements
        XCTAssertEqual(els.map(\.occurrence), [0, 1, 0])
    }

    func testFirstCopyKeepsTheOldKey() throws {
        // Corrections saved before #55 were keyed by text alone; they must still
        // find the first copy of the line.
        let first = try echoScript().scenes[0].elements[0]
        XCTAssertEqual(ParserCorrection.key(pdfIdentifier: pdf, sceneNumber: 1, element: first),
                       "\(pdf)|1|I'm looking at you.")
    }

    func testCorrectionToSecondCopyLeavesFirstAlone() throws {
        let script = try echoScript()
        let second = script.scenes[0].elements[1]
        let fix = correction(for: second, speaker: "MAX")
        let applied = script.applying([fix.storageKey: fix], pdfPath: pdf)
        XCTAssertEqual(applied.scenes[0].elements.map(\.speaker), ["LOLA", "MAX", nil])
    }

    func testManualOverlapAbsorbsOnlyTheNamedCopy() throws {
        let script = try echoScript()
        let els = script.scenes[0].elements
        var fix = correction(for: els[2], speaker: "NARRATOR")
        fix.correctedSpeaker = nil
        fix.manualOverlapPartnerKey = els[1].ref
        let applied = script.applying([fix.storageKey: fix], pdfPath: pdf)
        // ELLIOT's copy is absorbed into the pair; LOLA's identical line survives.
        XCTAssertEqual(applied.scenes[0].elements.map(\.speaker), ["LOLA", nil])
        XCTAssertEqual(applied.scenes[0].elements[1].overlapCue, ["Narrator", "ELLIOT"])
    }
}

// MARK: - Update signature verification

final class UpdateSignatureTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()
    private let archive = Data("TableRead.zip contents".utf8)

    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func sign(_ data: Data) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    func testEmbeddedPublicKeyIsWellFormed() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: AppUpdater.updatePublicKey))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }

    func testValidSignatureAccepted() throws {
        let sig = try sign(archive) + "\n"   // as written by update_signing.swift
        XCTAssertTrue(AppUpdater.isValidUpdateSignature(sig, for: archive, publicKey: publicKey))
    }

    func testTamperedArchiveRejected() throws {
        let sig = try sign(archive)
        var tampered = archive
        tampered[0] ^= 1
        XCTAssertFalse(AppUpdater.isValidUpdateSignature(sig, for: tampered, publicKey: publicKey))
    }

    func testOtherKeyRejected() throws {
        let sig = try Curve25519.Signing.PrivateKey().signature(for: archive).base64EncodedString()
        XCTAssertFalse(AppUpdater.isValidUpdateSignature(sig, for: archive, publicKey: publicKey))
    }

    func testGarbageSignatureRejected() {
        XCTAssertFalse(AppUpdater.isValidUpdateSignature("not base64!", for: archive, publicKey: publicKey))
        XCTAssertFalse(AppUpdater.isValidUpdateSignature("", for: archive, publicKey: publicKey))
    }
}
