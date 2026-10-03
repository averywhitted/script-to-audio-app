import XCTest
@testable import TableRead

// MARK: - PythonBridge Error Handling

final class PythonBridgeErrorTests: XCTestCase {

    func testWorkerMissingErrorHasDescriptiveMessage() {
        let error = PythonBridgeError.workerMissing
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Python worker") == true)
    }

    func testFailedErrorIncludesCustomMessage() {
        let error = PythonBridgeError.failed("Custom failure reason")
        XCTAssertEqual(error.errorDescription, "Custom failure reason")
    }

    func testBadResponseErrorHasDescriptiveMessage() {
        let error = PythonBridgeError.badResponse
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("unexpected") == true)
    }
}

// MARK: - formatSeconds

final class FormatSecondsTests: XCTestCase {

    func testZeroSecondsFormatsCorrectly() {
        XCTAssertEqual(formatSeconds(0), "0s")
    }

    func testSecondsUnderAMinuteShowSecondsOnly() {
        XCTAssertEqual(formatSeconds(1), "1s")
        XCTAssertEqual(formatSeconds(45), "45s")
        XCTAssertEqual(formatSeconds(59), "59s")
    }

    func testExactMinutesShowMinutesOnly() {
        XCTAssertEqual(formatSeconds(60), "1m")
        XCTAssertEqual(formatSeconds(120), "2m")
        XCTAssertEqual(formatSeconds(180), "3m")
    }

    func testMinutesAndSecondsShowBothComponents() {
        XCTAssertEqual(formatSeconds(61), "1m 1s")
        XCTAssertEqual(formatSeconds(90), "1m 30s")
        XCTAssertEqual(formatSeconds(125), "2m 5s")
        XCTAssertEqual(formatSeconds(185), "3m 5s")
    }

    func testLargeDurationsFormatCorrectly() {
        XCTAssertEqual(formatSeconds(3600), "60m")
        XCTAssertEqual(formatSeconds(3661), "61m 1s")
    }
}

// MARK: - User Added Elements

final class UserAddedElementTests: XCTestCase {

    func testUserAddedElementHasUniqueID() {
        let elem1 = UserAddedElement(
            pdfPath: "/test.pdf", sceneNumber: 1, afterElementTextKey: "First line",
            speaker: "ALICE", text: "Added line", kind: "dialog", timestamp: Date()
        )
        let elem2 = UserAddedElement(
            pdfPath: "/test.pdf", sceneNumber: 1, afterElementTextKey: "First line",
            speaker: "ALICE", text: "Added line", kind: "dialog", timestamp: Date()
        )
        XCTAssertNotEqual(elem1.id, elem2.id, "Each element should have a unique ID")
    }

    func testUserAddedElementStoresAllRequiredFields() {
        let timestamp = Date()
        let elem = UserAddedElement(
            pdfPath: "/path/script.pdf", sceneNumber: 5, afterElementTextKey: "Previous line text",
            speaker: "BOB", text: "My new line", kind: "dialog", timestamp: timestamp
        )

        XCTAssertEqual(elem.pdfPath, "/path/script.pdf")
        XCTAssertEqual(elem.sceneNumber, 5)
        XCTAssertEqual(elem.afterElementTextKey, "Previous line text")
        XCTAssertEqual(elem.speaker, "BOB")
        XCTAssertEqual(elem.text, "My new line")
        XCTAssertEqual(elem.kind, "dialog")
        XCTAssertEqual(elem.timestamp, timestamp)
        XCTAssertFalse(elem.isSplitFragment)
    }
}

// MARK: - Merged Scene Elements

final class MergedSceneElementTests: XCTestCase {

    func testParsedElementHasCorrectIDPrefix() {
        let parsed = SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Hello")
        let merged = MergedSceneElement.parsed(parsed)
        XCTAssertTrue(merged.id.hasPrefix("p-"))
    }

    func testAddedElementHasCorrectIDPrefix() {
        let added = UserAddedElement(
            pdfPath: "/test.pdf", sceneNumber: 1, afterElementTextKey: "key",
            speaker: "BOB", text: "Added", kind: "dialog", timestamp: Date()
        )
        let merged = MergedSceneElement.added(added)
        XCTAssertTrue(merged.id.hasPrefix("a-"))
    }

    func testManualOverlapHasCorrectIDPrefix() {
        let elem1 = SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "One")
        let elem2 = SceneElementSummary(kind: "dialog", speaker: "BOB", text: "Two")
        let merged = MergedSceneElement.manualOverlap(elem1, elem2)
        XCTAssertTrue(merged.id.hasPrefix("mo-"))
    }
}

// MARK: - Scene Cue Map

final class SceneCueMapTests: XCTestCase {

    func testSceneCueUsesIndexAsID() {
        let cue = SceneCue(index: 42, kind: "dialog", speaker: "ALICE", text: "Hello", startTime: 0, endTime: 1)
        XCTAssertEqual(cue.id, 42)
    }

    func testSceneCueMapStoresMetadata() {
        let now = Date()
        let cueMap = SceneCueMap(
            schemaVersion: 1, sceneNumber: 3, sceneTitle: "The Confrontation",
            generatedAt: now, totalDuration: 120.5, cues: []
        )

        XCTAssertEqual(cueMap.schemaVersion, 1)
        XCTAssertEqual(cueMap.sceneNumber, 3)
        XCTAssertEqual(cueMap.sceneTitle, "The Confrontation")
        XCTAssertEqual(cueMap.generatedAt, now)
        XCTAssertEqual(cueMap.totalDuration, 120.5)
    }
}

// MARK: - Voice Summary

final class VoiceSummaryTests: XCTestCase {

    func testVoiceSummaryUsesIDAsIdentifier() {
        let voice = VoiceSummary(
            id: "com.apple.voice.compact.en-US.Samantha", label: "Samantha",
            gender: "F", locale: "en-US", note: nil, display: "Samantha (en-US)"
        )
        XCTAssertEqual(voice.id, "com.apple.voice.compact.en-US.Samantha")
    }

    func testVoiceSummaryEqualityComparesAllFields() {
        let voice1 = VoiceSummary(id: "voice1", label: "Voice One", gender: "F", locale: "en-US", note: nil, display: "Voice One")
        let voice2 = VoiceSummary(id: "voice1", label: "Voice One", gender: "F", locale: "en-US", note: nil, display: "Voice One")
        XCTAssertEqual(voice1, voice2)
    }

    func testDifferentVoiceIDsAreNotEqual() {
        let voice1 = VoiceSummary(id: "voice1", label: "V1", gender: nil, locale: nil, note: nil, display: "V1")
        let voice2 = VoiceSummary(id: "voice2", label: "V1", gender: nil, locale: nil, note: nil, display: "V1")
        XCTAssertNotEqual(voice1, voice2)
    }
}

// MARK: - Recent Scripts

final class RecentScriptTests: XCTestCase {

    func testRecentScriptUsesPathAsID() {
        let recent = RecentScript(path: "/path/to/script.pdf", title: "My Script", lastOpened: Date())
        XCTAssertEqual(recent.id, "/path/to/script.pdf")
    }

    func testRecentScriptProvidesURLProperty() {
        let recent = RecentScript(path: "/path/to/script.pdf", title: "My Script", lastOpened: Date())
        XCTAssertEqual(recent.url, URL(fileURLWithPath: "/path/to/script.pdf"))
    }

    /// `RecentScript`'s `Equatable` is the plain synthesized one (compares every
    /// field, including `lastOpened`) — nothing in the codebase asks it to treat
    /// two different timestamps as equal. The de-duplication a "recent scripts"
    /// list actually needs happens explicitly by path in
    /// `AppState.rememberRecentScript` (`recentScripts.removeAll { $0.path ==
    /// item.path }`), not via `==`. This test previously asserted the opposite
    /// (same path, different `lastOpened`, expected equal) and had never been run
    /// until this session wired the file into the test target — it was failing
    /// from the moment it was written.
    func testRecentScriptEqualityComparesAllFields() {
        let date = Date()
        let same = RecentScript(path: "/test.pdf", title: "Test", lastOpened: date)
        let identical = RecentScript(path: "/test.pdf", title: "Test", lastOpened: date)
        XCTAssertEqual(same, identical)

        let differentDate = RecentScript(path: "/test.pdf", title: "Test",
                                         lastOpened: date.addingTimeInterval(100))
        XCTAssertNotEqual(same, differentDate,
                          "lastOpened is part of equality; path-based de-duplication is a "
                          + "separate, explicit step in AppState, not something == does")
    }
}

// MARK: - Character Summary

final class CharacterSummaryTests: XCTestCase {

    func testCharacterUsesNameAsID() {
        let char = CharacterSummary(name: "ALICE", genderHint: "F", roleHint: "lead")
        XCTAssertEqual(char.id, "ALICE")
    }

    func testCharactersCanHaveOptionalHints() {
        let minimal = CharacterSummary(name: "ALICE", genderHint: nil, roleHint: nil)
        XCTAssertEqual(minimal.name, "ALICE")
        XCTAssertNil(minimal.genderHint)
        XCTAssertNil(minimal.roleHint)
    }

    func testCharactersWithSameNameAreEqual() {
        let char1 = CharacterSummary(name: "BOB", genderHint: "M", roleHint: "support")
        let char2 = CharacterSummary(name: "BOB", genderHint: "M", roleHint: "support")
        XCTAssertEqual(char1, char2)
    }
}

// MARK: - Scene Summary

final class SceneSummaryTests: XCTestCase {

    func testSceneUsesNumberAsID() {
        let scene = SceneSummary(number: 7, title: "The Showdown", elementCount: 10, elements: [])
        XCTAssertEqual(scene.id, 7)
    }

    func testSceneStoresAllMetadata() {
        let elements = [
            SceneElementSummary(kind: "dialog", speaker: "A", text: "Line 1"),
            SceneElementSummary(kind: "dialog", speaker: "B", text: "Line 2")
        ]
        let scene = SceneSummary(number: 1, title: "Opening", elementCount: 2, elements: elements)

        XCTAssertEqual(scene.number, 1)
        XCTAssertEqual(scene.title, "Opening")
        XCTAssertEqual(scene.elementCount, 2)
        XCTAssertEqual(scene.elements.count, 2)
    }
}

// MARK: - Workflow Steps

final class WorkflowStepTests: XCTestCase {

    func testWorkflowStepsHaveCorrectNumbers() {
        XCTAssertEqual(WorkflowStep.importScript.number, 1)
        XCTAssertEqual(WorkflowStep.review.number, 2)
        XCTAssertEqual(WorkflowStep.cast.number, 3)
        XCTAssertEqual(WorkflowStep.generate.number, 4)
    }

    func testAllWorkflowStepsHaveUniqueNumbers() {
        let numbers = WorkflowStep.allCases.map(\.number)
        let uniqueNumbers = Set(numbers)
        XCTAssertEqual(numbers.count, uniqueNumbers.count)
    }

    func testWorkflowStepIDMatchesRawValue() {
        for step in WorkflowStep.allCases {
            XCTAssertEqual(step.id, step.rawValue)
        }
    }
}

// MARK: - Generation Log

final class GenerationLogTests: XCTestCase {

    func testLogLinesHaveUniqueIDs() {
        let line1 = GenerationLogLine(text: "Message 1", style: .info)
        let line2 = GenerationLogLine(text: "Message 1", style: .info)
        XCTAssertNotEqual(line1.id, line2.id)
    }

    func testLogStyleEqualityWorks() {
        XCTAssertEqual(LogStyle.info, LogStyle.info)
        XCTAssertEqual(LogStyle.error, LogStyle.error)
        XCTAssertNotEqual(LogStyle.info, LogStyle.error)
    }
}

// MARK: - Debug Log Entry

final class DebugLogEntryTests: XCTestCase {

    func testDebugLogEntryFormatsTimestamp() {
        let date = Date(timeIntervalSince1970: 1609459200) // 2021-01-01 00:00:00 UTC
        let entry = DebugLogEntry(timestamp: date, text: "Test", style: .debug)

        let formatted = entry.timestampString

        XCTAssertGreaterThan(formatted.count, 0)
        XCTAssertTrue(formatted.contains(":"))
    }

    func testDebugLogEntriesHaveUniqueIDs() {
        let entry1 = DebugLogEntry(timestamp: Date(), text: "Same text", style: .info)
        let entry2 = DebugLogEntry(timestamp: Date(), text: "Same text", style: .info)
        XCTAssertNotEqual(entry1.id, entry2.id)
    }
}
