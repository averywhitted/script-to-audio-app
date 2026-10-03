import Foundation
import CoreML
import CreateML

/// ML-powered script parser that learns from user corrections.
/// 
/// Training happens in two phases:
/// 1. **Offline**: Create base model from curated script dataset using Create ML
/// 2. **Online**: Fine-tune with user corrections collected via ParserCorrection
///
/// The model predicts element type ("dialog", "stage_direction", "parenthetical")
/// based on text features and PDF layout geometry.
@MainActor
final class AdaptiveScriptParser: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isTraining = false
    @Published var trainingProgress: Double = 0
    @Published var modelVersion: Int = 1
    @Published var trainingStats: TrainingStats?
    
    // MARK: - Private State
    
    private var baseModel: MLModel?
    private var userModel: MLModel?
    
    private let baseModelURL: URL
    private let userModelURL: URL
    private let trainingDataURL: URL
    
    // MARK: - Initialization
    
    init() {
        // Base model ships with the app
        self.baseModelURL = Bundle.main.url(
            forResource: "ScriptParserBase",
            withExtension: "mlmodelc"
        ) ?? URL(fileURLWithPath: "/dev/null")
        
        // User-specific model lives in Application Support
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TableRead/ML")
        
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        
        self.userModelURL = appSupport.appendingPathComponent("UserParser.mlmodelc")
        self.trainingDataURL = appSupport.appendingPathComponent("training_cache.json")
        
        loadModel()
        loadTrainingStats()
    }
    
    // MARK: - Model Loading
    
    private func loadModel() {
        // Prefer user-trained model if available
        if FileManager.default.fileExists(atPath: userModelURL.path),
           let model = try? MLModel(contentsOf: userModelURL) {
            self.userModel = model
            print("[ML] Loaded user-trained model")
        } else if let model = try? MLModel(contentsOf: baseModelURL) {
            self.baseModel = model
            print("[ML] Loaded base model")
        } else {
            print("[ML] No model available — predictions will use heuristics")
        }
    }
    
    private func loadTrainingStats() {
        guard let data = try? Data(contentsOf: trainingDataURL),
              let stats = try? JSONDecoder().decode(TrainingStats.self, from: data) else {
            return
        }
        self.trainingStats = stats
        self.modelVersion = stats.version
    }
    
    // MARK: - Prediction
    
    /// Predicts element kind from text and layout features.
    /// Falls back to Python parser when ML model unavailable or uncertain.
    func predict(
        text: String,
        xMin: Double,
        xMax: Double,
        capsRatio: Double,
        isBold: Bool,
        isItalic: Bool,
        fontSize: Double
    ) throws -> ElementPrediction {
        guard let model = userModel ?? baseModel else {
            return ElementPrediction(
                kind: "dialog",
                confidence: 0.0,
                source: .heuristic
            )
        }
        
        // Create input features
        let input = ScriptParserInput(
            text: text,
            xMin: xMin,
            xMax: xMax,
            capsRatio: capsRatio,
            isBold: isBold ? 1 : 0,
            isItalic: isItalic ? 1 : 0,
            fontSize: fontSize
        )
        
        let prediction = try model.prediction(from: input)
        
        // Extract confidence and predicted class
        let confidence = extractConfidence(from: prediction)
        let kind = extractKind(from: prediction)
        
        return ElementPrediction(
            kind: kind,
            confidence: confidence,
            source: .ml
        )
    }
    
    private func extractConfidence(from prediction: MLFeatureProvider) -> Double {
        // Extract probability from model output
        // (Implementation depends on your model's output format)
        if let probabilities = prediction.featureValue(for: "classProbability")?.dictionaryValue {
            return probabilities.values.map { $0.doubleValue }.max() ?? 0.5
        }
        return 0.5
    }
    
    private func extractKind(from prediction: MLFeatureProvider) -> String {
        prediction.featureValue(for: "classLabel")?.stringValue ?? "dialog"
    }
    
    // MARK: - Training
    
    /// Trains/updates the model using accumulated user corrections.
    /// 
    /// This should run in the background after the user has made at least
    /// 50–100 corrections to ensure meaningful signal.
    func train(corrections: [ParserCorrection]) async throws {
        guard corrections.count >= 20 else {
            throw MLError.insufficientData("Need at least 20 corrections to train")
        }
        
        isTraining = true
        trainingProgress = 0
        
        defer { isTraining = false }
        
        // Convert corrections to training examples
        let examples = corrections.compactMap(convertToTrainingExample)
        
        guard !examples.isEmpty else {
            throw MLError.insufficientData("No valid training examples")
        }
        
        // Build MLDataTable
        let table = try buildDataTable(from: examples)
        
        // Split into train/validation
        let (train, validation) = table.randomSplit(by: 0.8)
        
        trainingProgress = 0.1
        
        // Train classifier
        let parameters = MLClassifier.ModelParameters(
            validation: validation,
            maxIterations: 50,
            augmentation: nil
        )
        
        let classifier = try MLClassifier(
            trainingData: train,
            targetColumn: "kind",
            parameters: parameters
        )
        
        trainingProgress = 0.8
        
        // Evaluate
        let metrics = classifier.evaluation(on: validation)
        let accuracy = metrics.classificationError
        
        // Save model
        let metadata = MLModelMetadata(
            author: "TableRead User",
            shortDescription: "User-trained script parser",
            version: "\(modelVersion + 1)"
        )
        
        try classifier.write(to: userModelURL, metadata: metadata)
        
        // Update stats
        let stats = TrainingStats(
            version: modelVersion + 1,
            exampleCount: examples.count,
            accuracy: 1.0 - accuracy,
            trainedAt: Date()
        )
        
        let data = try JSONEncoder().encode(stats)
        try data.write(to: trainingDataURL)
        
        trainingProgress = 1.0
        
        // Reload model
        loadModel()
        loadTrainingStats()
    }
    
    // MARK: - Data Conversion
    
    private func convertToTrainingExample(_ correction: ParserCorrection) -> TrainingExample? {
        // You'd need to extend ParserCorrection to include layout features
        // For now, this is a placeholder showing the structure
        guard let kind = correction.correctedKind ?? Optional(correction.originalKind) else {
            return nil
        }
        
        return TrainingExample(
            text: correction.textKey.components(separatedBy: "|").last ?? "",
            xMin: 0, // TODO: Add to ParserCorrection
            xMax: 0,
            capsRatio: 0,
            isBold: false,
            isItalic: false,
            fontSize: 12,
            kind: kind
        )
    }
    
    private func buildDataTable(from examples: [TrainingExample]) throws -> MLDataTable {
        let dict: [String: [MLDataValueConvertible]] = [
            "text": examples.map { $0.text },
            "xMin": examples.map { $0.xMin },
            "xMax": examples.map { $0.xMax },
            "capsRatio": examples.map { $0.capsRatio },
            "isBold": examples.map { $0.isBold ? 1 : 0 },
            "isItalic": examples.map { $0.isItalic ? 1 : 0 },
            "fontSize": examples.map { $0.fontSize },
            "kind": examples.map { $0.kind }
        ]
        
        return try MLDataTable(dictionary: dict)
    }
}

// MARK: - Supporting Types

struct ElementPrediction {
    let kind: String
    let confidence: Double
    let source: PredictionSource
    
    enum PredictionSource {
        case ml
        case heuristic
    }
}

struct TrainingExample {
    let text: String
    let xMin: Double
    let xMax: Double
    let capsRatio: Double
    let isBold: Bool
    let isItalic: Bool
    let fontSize: Double
    let kind: String // "dialog", "stage_direction", "parenthetical"
}

struct TrainingStats: Codable {
    let version: Int
    let exampleCount: Int
    let accuracy: Double
    let trainedAt: Date
}

enum MLError: Error, LocalizedError {
    case insufficientData(String)
    case modelNotFound
    case predictionFailed
    
    var errorDescription: String? {
        switch self {
        case .insufficientData(let msg): msg
        case .modelNotFound: "ML model not found"
        case .predictionFailed: "Prediction failed"
        }
    }
}

// MARK: - Model Input (Generated by Create ML or defined manually)

struct ScriptParserInput: MLFeatureProvider {
    let text: String
    let xMin: Double
    let xMax: Double
    let capsRatio: Double
    let isBold: Int
    let isItalic: Int
    let fontSize: Double
    
    var featureNames: Set<String> {
        ["text", "xMin", "xMax", "capsRatio", "isBold", "isItalic", "fontSize"]
    }
    
    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "text": .string(text)
        case "xMin": .double(xMin)
        case "xMax": .double(xMax)
        case "capsRatio": .double(capsRatio)
        case "isBold": .int64(Int64(isBold))
        case "isItalic": .int64(Int64(isItalic))
        case "fontSize": .double(fontSize)
        default: nil
        }
    }
}
