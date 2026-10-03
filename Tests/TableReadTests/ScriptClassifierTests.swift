import XCTest
import CoreML
@testable import TableRead

// MARK: - ScriptClassifier
//
// ScriptClassifier.mlmodel is a proof-of-concept Create ML text classifier
// trained on ~28 hand-written examples (see ml/SimpleMLPlayground.swift for
// the training script). It is NOT wired into the parser — this test only
// confirms the model loads and produces a coherent prediction, not that its
// classifications are production-accurate.

final class ScriptClassifierTests: XCTestCase {

    private static let knownLabels: Set<String> = [
        "dialog", "stage_direction", "parenthetical", "scene_heading"
    ]

    func testModelLoads() throws {
        XCTAssertNoThrow(try ScriptClassifier(configuration: MLModelConfiguration()))
    }

    func testPredictionReturnsKnownLabel() throws {
        let model = try ScriptClassifier(configuration: MLModelConfiguration())

        let testInputs = [
            "HAMLET",
            "To be or not to be, that is the question.",
            "(aside)",
            "She storms out of the room.",
            "INT. CASTLE - NIGHT"
        ]

        for text in testInputs {
            let prediction = try model.prediction(text: text)
            print("[ScriptClassifier] '\(text)' → \(prediction.label)")

            XCTAssertTrue(
                Self.knownLabels.contains(prediction.label),
                "Predicted label '\(prediction.label)' for '\(text)' should be one of \(Self.knownLabels)"
            )
        }
    }
}
