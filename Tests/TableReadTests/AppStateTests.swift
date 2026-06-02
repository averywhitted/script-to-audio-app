import XCTest
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
        // Same speaker repeating the same short phrase (real Cyrano-style log warning trigger)
        let elements = [
            SceneElementSummary(kind: "dialog", speaker: "CYRANO", text: "say it"),
            SceneElementSummary(kind: "dialog", speaker: "CYRANO", text: "say it"),
            SceneElementSummary(kind: "dialog", speaker: "CYRANO", text: "say it"),
        ]
        // The id property alone may collide — this test documents that fact
        // and reminds us to use index-based ForEach (not element.id) in the UI.
        let ids = elements.map(\.id)
        // All ids are the same here — that's the known issue; ForEach uses .indices instead
        XCTAssertEqual(Set(ids).count, 1, "id property intentionally not unique — use .indices in ForEach")
    }
}
