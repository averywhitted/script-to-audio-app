import Testing
import Foundation
@testable import TableRead

@Suite("Adaptive Script Parser - Training Data")
@MainActor
struct AdaptiveParserTrainingTests {
    
    @Test("Training example stores all layout features")
    func trainingExampleFields() async throws {
        let example = TrainingExample(
            text: "ALICE",
            xMin: 72.0,
            xMax: 144.0,
            capsRatio: 1.0,
            isBold: true,
            isItalic: false,
            fontSize: 12.0,
            kind: "dialog"
        )
        
        #expect(example.text == "ALICE")
        #expect(example.xMin == 72.0)
        #expect(example.xMax == 144.0)
        #expect(example.capsRatio == 1.0)
        #expect(example.isBold == true)
        #expect(example.isItalic == false)
        #expect(example.fontSize == 12.0)
        #expect(example.kind == "dialog")
    }
    
    @Test("Training stats tracks version and accuracy")
    func trainingStatsFields() async throws {
        let stats = TrainingStats(
            version: 2,
            exampleCount: 150,
            accuracy: 0.92,
            trainedAt: Date()
        )
        
        #expect(stats.version == 2)
        #expect(stats.exampleCount == 150)
        #expect(stats.accuracy == 0.92)
    }
    
    @Test("Training stats can be encoded and decoded")
    func trainingStatsCodable() async throws {
        let original = TrainingStats(
            version: 3,
            exampleCount: 200,
            accuracy: 0.95,
            trainedAt: Date()
        )
        
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrainingStats.self, from: data)
        
        #expect(decoded.version == original.version)
        #expect(decoded.exampleCount == original.exampleCount)
        #expect(decoded.accuracy == original.accuracy)
    }
}

@Suite("Adaptive Script Parser - Predictions")
@MainActor
struct AdaptiveParserPredictionTests {
    
    @Test("Element prediction stores kind and confidence")
    func predictionFields() async throws {
        let prediction = ElementPrediction(
            kind: "dialog",
            confidence: 0.87,
            source: .ml
        )
        
        #expect(prediction.kind == "dialog")
        #expect(prediction.confidence == 0.87)
    }
    
    @Test("Prediction source distinguishes ML from heuristic")
    func predictionSource() async throws {
        let mlPrediction = ElementPrediction(kind: "dialog", confidence: 0.9, source: .ml)
        let heuristicPrediction = ElementPrediction(kind: "dialog", confidence: 0.6, source: .heuristic)
        
        switch mlPrediction.source {
        case .ml: break
        case .heuristic: Issue.record("Should be ML source")
        }
        
        switch heuristicPrediction.source {
        case .heuristic: break
        case .ml: Issue.record("Should be heuristic source")
        }
    }
    
    @Test("High confidence predictions should use ML")
    func highConfidenceML() async throws {
        let prediction = ElementPrediction(kind: "stage_direction", confidence: 0.95, source: .ml)
        
        #expect(prediction.confidence > 0.8, "High confidence predictions should be reliable")
    }
}

@Suite("Adaptive Script Parser - Error Handling")
@MainActor
struct AdaptiveParserErrorTests {
    
    @Test("Insufficient data error has descriptive message")
    func insufficientDataError() async throws {
        let error = MLError.insufficientData("Need at least 20 examples")
        
        #expect(error.errorDescription == "Need at least 20 examples")
    }
    
    @Test("Model not found error has message")
    func modelNotFoundError() async throws {
        let error = MLError.modelNotFound
        
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("model") == true)
    }
    
    @Test("Prediction failed error has message")
    func predictionFailedError() async throws {
        let error = MLError.predictionFailed
        
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("Prediction") == true)
    }
}

@Suite("Adaptive Script Parser - Model Input")
@MainActor
struct AdaptiveParserInputTests {
    
    @Test("Model input has all required feature names")
    func featureNames() async throws {
        let input = ScriptParserInput(
            text: "Test",
            xMin: 0,
            xMax: 100,
            capsRatio: 0.5,
            isBold: 0,
            isItalic: 0,
            fontSize: 12
        )
        
        let expectedFeatures: Set<String> = [
            "text", "xMin", "xMax", "capsRatio", "isBold", "isItalic", "fontSize"
        ]
        
        #expect(input.featureNames == expectedFeatures)
    }
    
    @Test("Model input provides string feature value")
    func stringFeatureValue() async throws {
        let input = ScriptParserInput(
            text: "ALICE",
            xMin: 0,
            xMax: 100,
            capsRatio: 1.0,
            isBold: 0,
            isItalic: 0,
            fontSize: 12
        )
        
        let textValue = input.featureValue(for: "text")
        
        #expect(textValue != nil)
        #expect(textValue?.stringValue == "ALICE")
    }
    
    @Test("Model input provides double feature values")
    func doubleFeatureValues() async throws {
        let input = ScriptParserInput(
            text: "Test",
            xMin: 72.5,
            xMax: 200.3,
            capsRatio: 0.85,
            isBold: 0,
            isItalic: 0,
            fontSize: 14.5
        )
        
        #expect(input.featureValue(for: "xMin")?.doubleValue == 72.5)
        #expect(input.featureValue(for: "xMax")?.doubleValue == 200.3)
        #expect(input.featureValue(for: "capsRatio")?.doubleValue == 0.85)
        #expect(input.featureValue(for: "fontSize")?.doubleValue == 14.5)
    }
    
    @Test("Model input provides int64 feature values")
    func int64FeatureValues() async throws {
        let input = ScriptParserInput(
            text: "Test",
            xMin: 0,
            xMax: 100,
            capsRatio: 0.5,
            isBold: 1,
            isItalic: 0,
            fontSize: 12
        )
        
        #expect(input.featureValue(for: "isBold")?.int64Value == 1)
        #expect(input.featureValue(for: "isItalic")?.int64Value == 0)
    }
    
    @Test("Model input returns nil for unknown feature")
    func unknownFeature() async throws {
        let input = ScriptParserInput(
            text: "Test",
            xMin: 0,
            xMax: 100,
            capsRatio: 0.5,
            isBold: 0,
            isItalic: 0,
            fontSize: 12
        )
        
        #expect(input.featureValue(for: "unknownFeature") == nil)
    }
}

@Suite("Adaptive Script Parser - Integration Scenarios")
@MainActor
struct AdaptiveParserIntegrationTests {
    
    @Test("Parser should start at version 1")
    func initialVersion() async throws {
        let parser = AdaptiveScriptParser()
        
        #expect(parser.modelVersion >= 1)
    }
    
    @Test("Parser should not be training on initialization")
    func notTrainingInitially() async throws {
        let parser = AdaptiveScriptParser()
        
        #expect(parser.isTraining == false)
    }
    
    @Test("Training progress starts at zero")
    func trainingProgressZero() async throws {
        let parser = AdaptiveScriptParser()
        
        #expect(parser.trainingProgress == 0)
    }
    
    @Test("Parser handles missing model gracefully")
    func missingModelFallback() async throws {
        let parser = AdaptiveScriptParser()
        
        // Even without a trained model, prediction should return something
        let prediction = try parser.predict(
            text: "ALICE",
            xMin: 72,
            xMax: 144,
            capsRatio: 1.0,
            isBold: true,
            isItalic: false,
            fontSize: 12
        )
        
        #expect(prediction.kind.isEmpty == false)
    }
}

@Suite("ML Training Workflow")
@MainActor
struct MLTrainingWorkflowTests {
    
    @Test("Collecting corrections creates training signal")
    func correctionsAsTrainingData() async throws {
        // Simulate user correcting misclassified elements
        let corrections: [ParserCorrection] = [
            ParserCorrection(
                textKey: "test.pdf|1|Stage direction text here",
                pdfIdentifier: "test.pdf",
                sceneNumber: 1,
                originalKind: "dialog",
                originalSpeaker: nil,
                correctedKind: "stage_direction",
                correctedSpeaker: nil,
                correctedText: nil,
                markedAsNoise: false,
                timestamp: Date(),
                contributed: true
            ),
            ParserCorrection(
                textKey: "test.pdf|1|Another stage direction",
                pdfIdentifier: "test.pdf",
                sceneNumber: 1,
                originalKind: "dialog",
                originalSpeaker: nil,
                correctedKind: "stage_direction",
                correctedSpeaker: nil,
                correctedText: nil,
                markedAsNoise: false,
                timestamp: Date(),
                contributed: true
            )
        ]
        
        #expect(corrections.count == 2)
        #expect(corrections.allSatisfy { $0.correctedKind == "stage_direction" })
    }
    
    @Test("Training requires minimum corrections threshold")
    func minimumCorrectionsThreshold() async throws {
        let parser = AdaptiveScriptParser()
        let fewCorrections: [ParserCorrection] = [
            ParserCorrection(
                textKey: "test.pdf|1|Text",
                pdfIdentifier: "test.pdf",
                sceneNumber: 1,
                originalKind: "dialog",
                originalSpeaker: nil,
                correctedKind: "stage_direction",
                correctedSpeaker: nil,
                correctedText: nil,
                markedAsNoise: false,
                timestamp: Date(),
                contributed: true
            )
        ]
        
        // Training should fail with too few corrections
        do {
            try await parser.train(corrections: fewCorrections)
            Issue.record("Should have thrown insufficientData error")
        } catch MLError.insufficientData {
            // Expected
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}
