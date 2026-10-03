import XCTest
@testable import TableRead

// MARK: - Scene Management

final class PlayerStateSceneTests: XCTestCase {

    @MainActor func testLoadScenesFromAppStatePopulatesPlayer() {
        let state = PlayerState()
        let appState = AppState()

        appState.script = ScriptSummary(
            title: "Test",
            sceneCount: 2,
            characterCount: 1,
            lineCount: 2,
            characters: [CharacterSummary(name: "ALICE", genderHint: "F", roleHint: nil)],
            scenes: [
                SceneSummary(number: 1, title: "Opening", elementCount: 1, elements: [
                    SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Hello")
                ]),
                SceneSummary(number: 2, title: "Ending", elementCount: 1, elements: [
                    SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Goodbye")
                ])
            ]
        )

        appState.selectedPDF = URL(fileURLWithPath: "/tmp/test.pdf")
        appState.sceneFileInfo[1] = SceneOutputInfo(exists: true, filename: "scene_01.m4a", title: "Opening")
        appState.sceneFileInfo[2] = SceneOutputInfo(exists: true, filename: "scene_02.m4a", title: "Ending")

        state.load(from: appState)

        XCTAssertEqual(state.scenes.count, 2)
        XCTAssertEqual(state.scenes[0].sceneNumber, 1)
        XCTAssertEqual(state.scenes[1].sceneNumber, 2)
    }

    @MainActor func testLoadScenesFiltersNonExistentFiles() {
        let state = PlayerState()
        let appState = AppState()

        appState.script = ScriptSummary(
            title: "Test",
            sceneCount: 2,
            characterCount: 1,
            lineCount: 2,
            characters: [CharacterSummary(name: "ALICE", genderHint: "F", roleHint: nil)],
            scenes: [
                SceneSummary(number: 1, title: "Opening", elementCount: 1, elements: []),
                SceneSummary(number: 2, title: "Ending", elementCount: 1, elements: [])
            ]
        )

        appState.selectedPDF = URL(fileURLWithPath: "/tmp/test.pdf")
        appState.sceneFileInfo[1] = SceneOutputInfo(exists: true, filename: "scene_01.m4a", title: "Opening")
        appState.sceneFileInfo[2] = SceneOutputInfo(exists: false, filename: "scene_02.m4a", title: "Ending")

        state.load(from: appState)

        XCTAssertEqual(state.scenes.count, 1, "Only scene 1 should load since scene 2 doesn't exist")
        XCTAssertEqual(state.scenes[0].sceneNumber, 1)
    }

    @MainActor func testSwitchingScenesUpdatesIndexAndResetsPlayback() {
        let state = PlayerState()
        state.scenes = [
            ScenePlayerItem(sceneNumber: 1, sceneTitle: "Scene 1", audioURL: URL(fileURLWithPath: "/tmp/s1.m4a")),
            ScenePlayerItem(sceneNumber: 2, sceneTitle: "Scene 2", audioURL: URL(fileURLWithPath: "/tmp/s2.m4a"))
        ]
        state.currentSceneIndex = 0
        state.currentTime = 42.0
        state.currentCueIndex = 5

        state.switchToScene(1, autoPlay: false)

        XCTAssertEqual(state.currentSceneIndex, 1)
        XCTAssertEqual(state.currentTime, 0)
        XCTAssertEqual(state.currentCueIndex, -1)
    }

    @MainActor func testSwitchingToInvalidSceneIsIgnored() {
        let state = PlayerState()
        state.scenes = [
            ScenePlayerItem(sceneNumber: 1, sceneTitle: "Scene 1", audioURL: URL(fileURLWithPath: "/tmp/s1.m4a"))
        ]
        state.currentSceneIndex = 0

        state.switchToScene(5, autoPlay: false)

        XCTAssertEqual(state.currentSceneIndex, 0, "Should remain at original scene")
    }
}

// MARK: - Transport Controls

final class PlayerStateTransportTests: XCTestCase {

    @MainActor func testSettingPlaybackRateClampsToValidRange() {
        let state = PlayerState()

        state.setRate(3.0)
        XCTAssertLessThanOrEqual(state.playbackRate, 2.0, "Rate should be clamped to maximum of 2.0")

        state.setRate(0.1)
        XCTAssertGreaterThanOrEqual(state.playbackRate, 0.5, "Rate should be clamped to minimum of 0.5")
    }

    @MainActor func testSettingPlaybackRateSnapsTo005Increments() {
        let state = PlayerState()

        state.setRate(1.234)

        // Should snap to nearest 0.05: 1.23 or 1.24
        let remainder = (state.playbackRate * 20).truncatingRemainder(dividingBy: 1.0)
        XCTAssertLessThan(remainder, 0.01, "Rate should snap to 0.05 increments")
    }

    @MainActor func testStepRateIncreasesByDelta() {
        let state = PlayerState()
        state.playbackRate = 1.0

        state.stepRate(by: 0.1)

        XCTAssertGreaterThan(state.playbackRate, 1.0)
        XCTAssertLessThanOrEqual(state.playbackRate, 1.1)
    }

    @MainActor func testStepRateDecreasesByDelta() {
        let state = PlayerState()
        state.playbackRate = 1.0

        state.stepRate(by: -0.1)

        XCTAssertLessThan(state.playbackRate, 1.0)
        XCTAssertGreaterThanOrEqual(state.playbackRate, 0.9)
    }

    @MainActor func testNextSceneIncrementsIndex() {
        let state = PlayerState()
        state.scenes = [
            ScenePlayerItem(sceneNumber: 1, sceneTitle: "Scene 1", audioURL: URL(fileURLWithPath: "/tmp/s1.m4a")),
            ScenePlayerItem(sceneNumber: 2, sceneTitle: "Scene 2", audioURL: URL(fileURLWithPath: "/tmp/s2.m4a"))
        ]
        state.currentSceneIndex = 0

        state.nextScene()

        XCTAssertEqual(state.currentSceneIndex, 1)
    }

    @MainActor func testNextSceneAtEndDoesNothing() {
        let state = PlayerState()
        state.scenes = [
            ScenePlayerItem(sceneNumber: 1, sceneTitle: "Scene 1", audioURL: URL(fileURLWithPath: "/tmp/s1.m4a"))
        ]
        state.currentSceneIndex = 0

        state.nextScene()

        XCTAssertEqual(state.currentSceneIndex, 0)
    }

    @MainActor func testPreviousSceneDecrementsIndex() {
        let state = PlayerState()
        state.scenes = [
            ScenePlayerItem(sceneNumber: 1, sceneTitle: "Scene 1", audioURL: URL(fileURLWithPath: "/tmp/s1.m4a")),
            ScenePlayerItem(sceneNumber: 2, sceneTitle: "Scene 2", audioURL: URL(fileURLWithPath: "/tmp/s2.m4a"))
        ]
        state.currentSceneIndex = 1

        state.prevScene()

        XCTAssertEqual(state.currentSceneIndex, 0)
    }
}

// MARK: - Role and Line Muting

final class PlayerStateRoleTests: XCTestCase {

    @MainActor func testIsMyLineReturnsFalseWhenMyRoleIsEmpty() {
        let state = PlayerState()
        state.myRole = ""

        let cue = SceneCue(index: 0, kind: "dialog", speaker: "ALICE", text: "Hello", startTime: 0, endTime: 1)

        XCTAssertFalse(state.isMyLine(cue))
    }

    @MainActor func testIsMyLineMatchesSingleSpeaker() {
        let state = PlayerState()
        state.myRole = "ALICE"

        let cue = SceneCue(index: 0, kind: "dialog", speaker: "ALICE", text: "Hello", startTime: 0, endTime: 1)

        XCTAssertTrue(state.isMyLine(cue))
    }

    @MainActor func testIsMyLineMatchesInSlashSeparatedOverlap() {
        let state = PlayerState()
        state.myRole = "ALICE"

        let cue = SceneCue(index: 0, kind: "dialog", speaker: "ALICE/BOB", text: "Hello", startTime: 0, endTime: 1)

        XCTAssertTrue(state.isMyLine(cue))
    }

    @MainActor func testIsMyLineDoesNotMatchDifferentSpeaker() {
        let state = PlayerState()
        state.myRole = "ALICE"

        let cue = SceneCue(index: 0, kind: "dialog", speaker: "BOB", text: "Hello", startTime: 0, endTime: 1)

        XCTAssertFalse(state.isMyLine(cue))
    }
}

// MARK: - Cue Navigation

final class PlayerStateCueTests: XCTestCase {

    @MainActor func testNextLineSeeksToNextCueStartTime() {
        let state = PlayerState()
        state.cues = [
            SceneCue(index: 0, kind: "dialog", speaker: "A", text: "First", startTime: 0, endTime: 2),
            SceneCue(index: 1, kind: "dialog", speaker: "B", text: "Second", startTime: 2, endTime: 4)
        ]
        state.currentCueIndex = 0
        state.currentTime = 1.0

        state.nextLine()

        XCTAssertEqual(state.currentTime, 2.0)
    }

    @MainActor func testNextLineAtLastCueDoesNothing() {
        let state = PlayerState()
        state.cues = [
            SceneCue(index: 0, kind: "dialog", speaker: "A", text: "Only", startTime: 0, endTime: 2)
        ]
        state.currentCueIndex = 0
        state.currentTime = 1.0

        state.nextLine()

        XCTAssertEqual(state.currentTime, 1.0, "Time should not change when at last cue")
    }

    @MainActor func testPreviousLineEarlyInCueGoesToPreviousCue() {
        let state = PlayerState()
        state.cues = [
            SceneCue(index: 0, kind: "dialog", speaker: "A", text: "First", startTime: 0, endTime: 2),
            SceneCue(index: 1, kind: "dialog", speaker: "B", text: "Second", startTime: 2, endTime: 4)
        ]
        state.currentCueIndex = 1
        state.currentTime = 2.5  // 0.5 seconds into cue 1

        state.prevLine()

        XCTAssertEqual(state.currentTime, 0.0, "Should seek to previous cue")
    }

    @MainActor func testPreviousLineLateInCueRestartsCurrentCue() {
        let state = PlayerState()
        state.cues = [
            SceneCue(index: 0, kind: "dialog", speaker: "A", text: "First", startTime: 0, endTime: 2),
            SceneCue(index: 1, kind: "dialog", speaker: "B", text: "Second", startTime: 2, endTime: 4)
        ]
        state.currentCueIndex = 1
        state.currentTime = 3.6  // 1.6 seconds into cue 1 (more than 1.5s threshold)

        state.prevLine()

        XCTAssertEqual(state.currentTime, 2.0, "Should restart current cue")
    }

    @MainActor func testPreviousLineAtFirstCueSeeksToZero() {
        let state = PlayerState()
        state.cues = [
            SceneCue(index: 0, kind: "dialog", speaker: "A", text: "First", startTime: 0, endTime: 2)
        ]
        state.currentCueIndex = 0
        state.currentTime = 0.5

        state.prevLine()

        XCTAssertEqual(state.currentTime, 0.0)
    }
}
