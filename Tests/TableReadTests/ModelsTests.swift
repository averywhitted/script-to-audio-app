import XCTest
@testable import TableRead

// MARK: - SceneElementSummary

final class SceneElementSummaryTests: XCTestCase {

    func testDialogWithoutOverlapDisplaysSpeakerName() {
        let element = SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Hello")
        XCTAssertEqual(element.displaySpeaker, "ALICE")
    }

    func testOverlapElementDisplaysJoinedSpeakers() {
        let element = SceneElementSummary(
            kind: "dialog",
            speaker: "ALICE",
            text: "Hello",
            overlapCue: ["ALICE", "BOB"]
        )
        XCTAssertEqual(element.displaySpeaker, "ALICE & BOB")
    }

    func testStageDirectionDisplaysAsNarrator() {
        let element = SceneElementSummary(kind: "stage_direction", speaker: nil, text: "The lights dim.")
        XCTAssertEqual(element.displaySpeaker, "Narrator")
    }

    func testParentheticalDisplaysAsNarrator() {
        let element = SceneElementSummary(kind: "parenthetical", speaker: nil, text: "(softly)")
        XCTAssertEqual(element.displaySpeaker, "Narrator")
    }

    func testDialogWithoutSpeakerDisplaysAsNarrator() {
        let element = SceneElementSummary(kind: "dialog", speaker: nil, text: "Voiceover")
        XCTAssertEqual(element.displaySpeaker, "Narrator")
    }

    func testIsOverlapDetectsMultipleSpeakers() {
        let overlap = SceneElementSummary(
            kind: "dialog",
            speaker: "ALICE",
            text: "Yes!",
            overlapCue: ["ALICE", "BOB"]
        )
        XCTAssertTrue(overlap.isOverlap)

        let single = SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Yes!")
        XCTAssertFalse(single.isOverlap)
    }

    func testHasSplitTextDetectsPerVoiceTexts() {
        let split = SceneElementSummary(
            kind: "dialog",
            speaker: "ALICE",
            text: "Default",
            overlapCue: ["ALICE", "BOB"],
            overlapTexts: ["I say this", "I say that"]
        )
        XCTAssertTrue(split.hasSplitText)

        let unified = SceneElementSummary(
            kind: "dialog",
            speaker: "ALICE",
            text: "We both say this",
            overlapCue: ["ALICE", "BOB"]
        )
        XCTAssertFalse(unified.hasSplitText)
    }

    func testKindLabelFormatsDialog() {
        let element = SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "Hello")
        XCTAssertEqual(element.kindLabel, "Dialog")
    }

    func testKindLabelFormatsOverlap() {
        let element = SceneElementSummary(
            kind: "dialog",
            speaker: "ALICE",
            text: "Hello",
            overlapCue: ["ALICE", "BOB"]
        )
        XCTAssertEqual(element.kindLabel, "Overlap")
    }

    func testKindLabelFormatsStageDirectionAsNarration() {
        let element = SceneElementSummary(kind: "stage_direction", speaker: nil, text: "Lights dim")
        XCTAssertEqual(element.kindLabel, "Narration")
    }

    func testKindLabelFormatsParentheticalAsAside() {
        let element = SceneElementSummary(kind: "parenthetical", speaker: nil, text: "(quietly)")
        XCTAssertEqual(element.kindLabel, "Aside")
    }
}

// MARK: - OpenAI Estimate

final class OpenAIEstimateTests: XCTestCase {

    func testDurationTextFormatsMinutesUnder60() {
        let estimate = OpenAIEstimate(requestCount: 10, requestsPerMinute: 3, minimumSeconds: 180)
        XCTAssertEqual(estimate.durationText, "3 min")
    }

    func testDurationTextFormatsHoursAndMinutes() {
        let estimate = OpenAIEstimate(requestCount: 100, requestsPerMinute: 3, minimumSeconds: 7200)
        XCTAssertEqual(estimate.durationText, "2h 0m")
    }

    func testDurationTextShowsMinimumOneMinute() {
        let estimate = OpenAIEstimate(requestCount: 1, requestsPerMinute: 60, minimumSeconds: 30)
        XCTAssertEqual(estimate.durationText, "1 min")
    }

    func testCostTextShowsLessThanPennyForSmallCosts() {
        let estimate = OpenAIEstimate(
            requestCount: 1, requestsPerMinute: 1, minimumSeconds: 60,
            totalChars: 100, estimatedCostUSD: 0.005
        )
        XCTAssertEqual(estimate.costText, "< $0.01")
    }

    func testCostTextShowsCents() {
        let estimate = OpenAIEstimate(
            requestCount: 1, requestsPerMinute: 1, minimumSeconds: 60,
            totalChars: 1000, estimatedCostUSD: 0.45
        )
        XCTAssertEqual(estimate.costText, "$0.45")
    }

    func testCostTextShowsDollars() {
        let estimate = OpenAIEstimate(
            requestCount: 100, requestsPerMinute: 3, minimumSeconds: 2000,
            totalChars: 100000, estimatedCostUSD: 15.75
        )
        XCTAssertEqual(estimate.costText, "$15.75")
    }

    func testCharsTextShowsRawCountUnder1000() {
        let estimate = OpenAIEstimate(
            requestCount: 1, requestsPerMinute: 1, minimumSeconds: 60, totalChars: 500
        )
        XCTAssertEqual(estimate.charsText, "500")
    }

    func testCharsTextShowsThousandsWithKSuffix() {
        let estimate = OpenAIEstimate(
            requestCount: 10, requestsPerMinute: 3, minimumSeconds: 200, totalChars: 42300
        )
        XCTAssertEqual(estimate.charsText, "42.3k")
    }
}

// MARK: - SceneSummary Estimates

final class SceneSummaryEstimateTests: XCTestCase {

    private func scene(words: Int) -> SceneSummary {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return SceneSummary(
            number: 1,
            title: "Test Scene",
            elementCount: 1,
            elements: [SceneElementSummary(kind: "dialog", speaker: "A", text: text)]
        )
    }

    func testMacOSEstimateUses28WordsPerSecond() {
        // 280 words at 2.8 wps = 100 seconds
        let s = scene(words: 280)
        XCTAssertEqual(s.estimatedSeconds(engine: .macOS), 100)
    }

    func testKokoroIsFasterThanMacOS() {
        let s = scene(words: 100)
        XCTAssertLessThan(s.estimatedSeconds(engine: .kokoro), s.estimatedSeconds(engine: .macOS))
    }

    func testOpenAIIsFastest() {
        let s = scene(words: 100)
        XCTAssertLessThan(s.estimatedSeconds(engine: .openAI), s.estimatedSeconds(engine: .kokoro))
    }

    func testMinimumEstimateIsOneSecond() {
        let s = scene(words: 0)
        XCTAssertGreaterThanOrEqual(s.estimatedSeconds(engine: .macOS), 1)
        XCTAssertGreaterThanOrEqual(s.estimatedSeconds(engine: .kokoro), 1)
        XCTAssertGreaterThanOrEqual(s.estimatedSeconds(engine: .openAI), 1)
    }

    func testMultipleElementsAccumulateWordCount() {
        let scene = SceneSummary(
            number: 1,
            title: "Test",
            elementCount: 3,
            elements: [
                SceneElementSummary(kind: "dialog", speaker: "A", text: "word word word"),
                SceneElementSummary(kind: "dialog", speaker: "B", text: "word word"),
                SceneElementSummary(kind: "dialog", speaker: "A", text: "word")
            ]
        )
        // Total: 6 words at 2.8 wps ≈ 2.14 seconds, rounds to 2
        XCTAssertGreaterThanOrEqual(scene.estimatedSeconds(engine: .macOS), 2)
    }
}

// MARK: - Parser Corrections

final class ParserCorrectionTests: XCTestCase {

    func testCorrectionKeyIncludesPdfPathSceneNumberAndTextPrefix() {
        let key = ParserCorrection.key(
            pdfIdentifier: "/path/to/script.pdf",
            sceneNumber: 3,
            text: "This is a very long line of dialogue that will be truncated at sixty characters for the key"
        )
        XCTAssertTrue(key.contains("/path/to/script.pdf"))
        XCTAssertTrue(key.contains("|3|"))
        XCTAssertTrue(key.contains("This is a very long line of dialogue that will be truncated"))
    }

    func testCorrectionKeyTruncatesTextTo60Characters() {
        let longText = String(repeating: "x", count: 100)
        let key = ParserCorrection.key(pdfIdentifier: "/test.pdf", sceneNumber: 1, text: longText)

        let components = key.components(separatedBy: "|")
        let textPart = components.last ?? ""

        XCTAssertEqual(textPart.count, 60)
    }

    func testAnonymizedCorrectionStripsPersonalInfo() {
        let correction = ParserCorrection(
            textKey: "/Users/alice/Documents/my-secret-script.pdf|1|Hello world this is the dialogue",
            pdfIdentifier: "/Users/alice/Documents/my-secret-script.pdf",
            sceneNumber: 1,
            originalKind: "dialog",
            originalSpeaker: "ALICE",
            correctedKind: nil,
            correctedSpeaker: "BOB",
            correctedText: nil,
            markedAsNoise: false,
            timestamp: Date(),
            contributed: true
        )

        let anon = correction.anonymized(appVersion: "1.0")

        XCTAssertEqual(anon.sceneNumber, 1)
        XCTAssertEqual(anon.originalKind, "dialog")
        XCTAssertEqual(anon.correctedSpeaker, "BOB")
        XCTAssertEqual(anon.appVersion, "1.0")
        // Original text should be extracted without file path
        XCTAssertEqual(anon.originalText, "Hello world this is the dialogue")
    }
}

// MARK: - ScriptSummary Corrections

final class ScriptSummaryCorrectionTests: XCTestCase {

    private func makeScript() -> ScriptSummary {
        ScriptSummary(
            title: "Test",
            sceneCount: 1,
            characterCount: 2,
            lineCount: 3,
            characters: [
                CharacterSummary(name: "ALICE", genderHint: "F", roleHint: nil),
                CharacterSummary(name: "BOB", genderHint: "M", roleHint: nil)
            ],
            scenes: [
                SceneSummary(number: 1, title: "Scene", elementCount: 3, elements: [
                    SceneElementSummary(kind: "dialog", speaker: "ALICE", text: "First line"),
                    SceneElementSummary(kind: "dialog", speaker: "BOB", text: "Second line"),
                    SceneElementSummary(kind: "stage_direction", speaker: nil, text: "She exits")
                ])
            ]
        )
    }

    func testApplyingCorrectionChangesSpeaker() {
        let script = makeScript()
        let pdfPath = "/test.pdf"

        let correction = ParserCorrection(
            textKey: ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: 1, text: "First line"),
            pdfIdentifier: pdfPath,
            sceneNumber: 1,
            originalKind: "dialog",
            originalSpeaker: "ALICE",
            correctedKind: nil,
            correctedSpeaker: "CHARLIE",
            correctedText: nil,
            markedAsNoise: false,
            timestamp: Date(),
            contributed: false
        )

        let corrected = script.applying([correction.textKey: correction], pdfPath: pdfPath)

        XCTAssertEqual(corrected.scenes[0].elements[0].speaker, "CHARLIE")
    }

    func testApplyingCorrectionChangesText() {
        let script = makeScript()
        let pdfPath = "/test.pdf"

        let correction = ParserCorrection(
            textKey: ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: 1, text: "First line"),
            pdfIdentifier: pdfPath,
            sceneNumber: 1,
            originalKind: "dialog",
            originalSpeaker: "ALICE",
            correctedKind: nil,
            correctedSpeaker: nil,
            correctedText: "Corrected line",
            markedAsNoise: false,
            timestamp: Date(),
            contributed: false
        )

        let corrected = script.applying([correction.textKey: correction], pdfPath: pdfPath)

        XCTAssertEqual(corrected.scenes[0].elements[0].text, "Corrected line")
    }

    func testApplyingCorrectionMarkedAsNoiseRemovesIt() {
        let script = makeScript()
        let pdfPath = "/test.pdf"

        let correction = ParserCorrection(
            textKey: ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: 1, text: "Second line"),
            pdfIdentifier: pdfPath,
            sceneNumber: 1,
            originalKind: "dialog",
            originalSpeaker: "BOB",
            correctedKind: nil,
            correctedSpeaker: nil,
            correctedText: nil,
            markedAsNoise: true,
            timestamp: Date(),
            contributed: false
        )

        let corrected = script.applying([correction.textKey: correction], pdfPath: pdfPath)

        XCTAssertEqual(corrected.scenes[0].elements.count, 2, "Noise element should be removed")
        XCTAssertEqual(corrected.lineCount, 2, "Line count should be updated")
    }

    func testApplyingCorrectionChangesKind() {
        let script = makeScript()
        let pdfPath = "/test.pdf"

        let correction = ParserCorrection(
            textKey: ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: 1, text: "She exits"),
            pdfIdentifier: pdfPath,
            sceneNumber: 1,
            originalKind: "stage_direction",
            originalSpeaker: nil,
            correctedKind: "dialog",
            correctedSpeaker: "ALICE",
            correctedText: nil,
            markedAsNoise: false,
            timestamp: Date(),
            contributed: false
        )

        let corrected = script.applying([correction.textKey: correction], pdfPath: pdfPath)

        XCTAssertEqual(corrected.scenes[0].elements[2].kind, "dialog")
        XCTAssertEqual(corrected.scenes[0].elements[2].speaker, "ALICE")
    }

    func testConvertingDialogToNarrationStripsOverlapData() {
        let script = ScriptSummary(
            title: "Test",
            sceneCount: 1,
            characterCount: 2,
            lineCount: 1,
            characters: [],
            scenes: [
                SceneSummary(number: 1, title: "Scene", elementCount: 1, elements: [
                    SceneElementSummary(
                        kind: "dialog",
                        speaker: "ALICE",
                        text: "Together!",
                        overlapCue: ["ALICE", "BOB"]
                    )
                ])
            ]
        )

        let pdfPath = "/test.pdf"
        let correction = ParserCorrection(
            textKey: ParserCorrection.key(pdfIdentifier: pdfPath, sceneNumber: 1, text: "Together!"),
            pdfIdentifier: pdfPath,
            sceneNumber: 1,
            originalKind: "dialog",
            originalSpeaker: "ALICE",
            correctedKind: "stage_direction",
            correctedSpeaker: nil,
            correctedText: nil,
            markedAsNoise: false,
            timestamp: Date(),
            contributed: false
        )

        let corrected = script.applying([correction.textKey: correction], pdfPath: pdfPath)

        XCTAssertEqual(corrected.scenes[0].elements[0].kind, "stage_direction")
        XCTAssertNil(corrected.scenes[0].elements[0].overlapCue)
    }
}

// MARK: - Review confidence

final class ElementConfidenceTests: XCTestCase {

    private func element(confidence: Double = 1.0, kindConfidence: Double = 1.0,
                         reason: String? = nil, kindReason: String? = nil) -> SceneElementSummary {
        SceneElementSummary(
            kind: "dialog", speaker: "ALICE", text: "Hello",
            confidence: confidence, reason: reason,
            kindConfidence: kindConfidence, kindReason: kindReason
        )
    }

    /// Regression test for a bug where this warning never rendered.
    ///
    /// `_mark_single_occurrence_confidence` in parser.py writes exactly 0.7, but
    /// the view tested `confidence < 0.7`, so that whole category of flagged line
    /// was silently invisible. The threshold is inclusive for that reason.
    func testSpeakerConfidenceOfExactly0_7NeedsReview() {
        XCTAssertTrue(element(confidence: 0.7).needsReview,
                      "0.7 is the value the parser actually writes; a strict < 0.7 test hides it")
    }

    func testConfidentElementDoesNotNeedReview() {
        XCTAssertFalse(element().needsReview)
        XCTAssertFalse(element(confidence: 0.8, kindConfidence: 0.9).needsReview)
    }

    func testLowSpeakerConfidenceNeedsReview() {
        XCTAssertTrue(element(confidence: 0.5).needsReview)
    }

    func testLowKindConfidenceNeedsReview() {
        XCTAssertTrue(element(kindConfidence: 0.4).needsReview,
                      "kind confidence is an independent axis from speaker confidence")
    }

    func testKindConfidenceAtThresholdDoesNotNeedReview() {
        XCTAssertFalse(element(kindConfidence: SceneElementSummary.kindConfidenceThreshold).needsReview)
    }

    func testReviewReasonPrefersTheAxisThatIsActuallyUncertain() {
        let speakerFlagged = element(confidence: 0.5, reason: "No speaker detected.",
                                     kindReason: "kind note")
        XCTAssertEqual(speakerFlagged.reviewReason, "No speaker detected.")

        let kindFlagged = element(kindConfidence: 0.4, kindReason: "Model unsure this is dialogue.")
        XCTAssertEqual(kindFlagged.reviewReason, "Model unsure this is dialogue.")
    }

    /// Old parses (and any JSON predating the model) must still decode.
    func testDefaultsWhenBackendOmitsKindConfidence() throws {
        let json = """
        {"kind":"dialog","speaker":"ALICE","text":"Hello","confidence":1.0}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let el = try JSONDecoder().decode(SceneElementSummary.self, from: data)
        XCTAssertEqual(el.kindConfidence, 1.0, "absent kindConfidence must mean 'not assessed'")
        XCTAssertNil(el.kindReason)
        XCTAssertFalse(el.needsReview)
    }

    /// The wire contract: these keys are what audio_worker.py emits.
    func testDecodesBackendFixtureWithKindConfidence() throws {
        let json = """
        {"kind":"stage_direction","speaker":null,"text":"Silence.","confidence":1.0,
         "reason":null,"kindConfidence":0.53,"kindReason":"Model is unsure this is narration."}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let el = try JSONDecoder().decode(SceneElementSummary.self, from: data)
        XCTAssertEqual(el.kindConfidence, 0.53, accuracy: 1e-9)
        XCTAssertTrue(el.needsReview)
        XCTAssertEqual(el.reviewReason, "Model is unsure this is narration.")
    }
}

// MARK: - Engine Kind

final class EngineKindTests: XCTestCase {

    func testMacOSEngineIsAlwaysSupported() {
        XCTAssertTrue(EngineKind.macOS.isSupported)
    }

    func testOpenAIEngineIsSupported() {
        XCTAssertTrue(EngineKind.openAI.isSupported)
    }

    func testKokoroEngineIsSupported() {
        XCTAssertTrue(EngineKind.kokoro.isSupported)
    }

    func testPiperEngineIsNotYetSupported() {
        XCTAssertFalse(EngineKind.piper.isSupported)
    }

    func testAllEnginesHaveUniqueIDs() {
        let ids = EngineKind.allCases.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count, "All engine IDs should be unique")
    }

    func testAllEnginesHaveTitles() {
        for engine in EngineKind.allCases {
            XCTAssertFalse(engine.title.isEmpty, "Engine \(engine.id) should have a title")
        }
    }
}
