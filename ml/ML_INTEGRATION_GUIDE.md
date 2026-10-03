# Machine Learning Integration Guide for TableRead

## Overview

This guide explains how to add adaptive, self-improving ML to TableRead's script parser.

## 🎯 Goal

Learn from user corrections to improve script element classification over time, making the parser better at handling diverse script formats without manual rule updates.

## 📊 What Gets Learned

The ML model learns to classify script elements based on:

### Text Features
- Raw text content
- Word count
- Capitalization ratio
- Presence of punctuation

### Layout Features (from PDF)
- Horizontal position (xMin, xMax)
- Bold/italic style
- Font size
- Vertical spacing

### Output Classes
- `dialog` - Character speech
- `stage_direction` - Action/scene description
- `parenthetical` - Actor direction (e.g., "quietly")
- `scene_heading` - Scene/location headers

## 🔧 Implementation Steps

### Step 1: Create Base Training Dataset

Create a `.playground` or command-line tool to build your initial model:

```swift
import CreateML
import Foundation

// 1. Prepare training data (manually labeled examples)
let trainingCSV = """
text,xMin,xMax,capsRatio,isBold,isItalic,fontSize,kind
"ALICE",72,144,1.0,1,0,12,dialog
"(softly)",144,200,0.1,0,1,10,parenthetical
"She exits.",72,500,0.05,0,0,12,stage_direction
"INT. COFFEE SHOP - DAY",72,500,0.8,1,0,12,scene_heading
"""

let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("training.csv")
try trainingCSV.write(to: tempURL, atomically: true, encoding: .utf8)

// 2. Load as MLDataTable
let data = try MLDataTable(contentsOf: tempURL)

// 3. Train classifier
let classifier = try MLClassifier(
    trainingData: data,
    targetColumn: "kind"
)

// 4. Evaluate
let evaluation = classifier.evaluation(on: data)
print("Training accuracy: \(1.0 - evaluation.classificationError)")

// 5. Save model
let outputURL = URL(fileURLWithPath: "/path/to/TableRead/Resources/ScriptParserBase.mlmodel")
try classifier.write(to: outputURL)
```

### Step 2: Extend ParserCorrection with Layout Data

Update `ParserCorrection` to capture the geometric features needed for training:

```swift
struct ParserCorrection: Codable, Equatable, Sendable {
    // ... existing fields ...
    
    // NEW: Layout features for ML training
    var layoutFeatures: LayoutFeatures?
}

struct LayoutFeatures: Codable, Equatable, Sendable {
    var xMin: Double
    var xMax: Double
    var capsRatio: Double
    var isBold: Bool
    var isItalic: Bool
    var fontSize: Double
}
```

### Step 3: Capture Layout Data in Python Backend

Modify `backend/parser.py` to include layout features in corrections:

```python
# When returning parsed elements, include layout metadata
element = {
    "kind": "dialog",
    "speaker": "ALICE",
    "text": "Hello world",
    "layoutFeatures": {
        "xMin": float(span.x0),
        "xMax": float(span.x1),
        "capsRatio": calculate_caps_ratio(span.text),
        "isBold": "Bold" in span.font,
        "isItalic": "Italic" in span.font,
        "fontSize": float(span.size)
    }
}
```

### Step 4: Hook Up Training in AppState

Add periodic training when corrections accumulate:

```swift
extension AppState {
    
    /// Call this after user saves a correction
    func onCorrectionSaved(_ correction: ParserCorrection) {
        // Store correction (existing code)
        // ...
        
        // Check if we should trigger training
        Task {
            await maybeTrainMLModel()
        }
    }
    
    private func maybeTrainMLModel() async {
        let corrections = loadAllCorrections() // your existing method
        
        // Only train when we have enough new data
        guard corrections.count >= 50,
              corrections.count % 50 == 0 else { // every 50 corrections
            return
        }
        
        do {
            try await adaptiveParser.train(corrections: corrections)
            print("[ML] Model updated! New version: \(adaptiveParser.modelVersion)")
        } catch {
            print("[ML] Training failed: \(error)")
        }
    }
}
```

### Step 5: Use ML Predictions (Optional Hybrid Mode)

Enhance your Python parser to accept ML predictions:

```swift
// In PythonBridge.swift
func parseWithML(pdf: URL) async throws -> ScriptSummary {
    let parser = AdaptiveScriptParser()
    
    // Get raw blocks from Python
    let rawBlocks = try await pythonBridge.extractRawBlocks(pdf: pdf)
    
    // Classify with ML
    var classifiedElements: [SceneElementSummary] = []
    for block in rawBlocks {
        let prediction = try parser.predict(
            text: block.text,
            xMin: block.xMin,
            xMax: block.xMax,
            capsRatio: block.capsRatio,
            isBold: block.isBold,
            isItalic: block.isItalic,
            fontSize: block.fontSize
        )
        
        // Use ML prediction if confident, otherwise fall back to heuristics
        let kind = prediction.confidence > 0.7 ? prediction.kind : block.heuristicKind
        
        classifiedElements.append(SceneElementSummary(
            kind: kind,
            speaker: extractSpeaker(block, kind: kind),
            text: block.text,
            confidence: prediction.confidence
        ))
    }
    
    // Assemble into ScriptSummary
    return assembleScript(elements: classifiedElements)
}
```

## 📈 Training Workflow

### Initial Training (one-time)
1. Manually label 200–500 diverse script examples
2. Use Create ML to build `ScriptParserBase.mlmodel`
3. Ship this base model with your app

### Continuous Learning (ongoing)
1. User corrects a misclassified element
2. Correction stored with layout features
3. Every 50 corrections, trigger background training
4. Updated model saved to `~/Library/Application Support/TableRead/ML/`
5. New predictions use updated model

### Model Versioning
```swift
// Track improvements over time
struct TrainingStats: Codable {
    let version: Int
    let exampleCount: Int
    let accuracy: Double
    let trainedAt: Date
}

// Show in Settings UI
Text("Model v\(parser.modelVersion) • \(parser.trainingStats?.accuracy ?? 0)% accurate")
    .font(.caption)
    .foregroundColor(.secondary)
```

## 🧪 Testing Your ML Integration

The `AdaptiveParserTests.swift` file includes tests for:

- Training data format
- Prediction accuracy expectations
- Error handling (insufficient data, missing model)
- Model input feature extraction

Run tests with **⌘U** or in the Test Navigator.

## 🎨 Optional: Show Learning in UI

Add a "ML Training" section to your Settings:

```swift
Section("Machine Learning") {
    if let stats = adaptiveParser.trainingStats {
        LabeledContent("Model Version", value: "\(stats.version)")
        LabeledContent("Training Examples", value: "\(stats.exampleCount)")
        LabeledContent("Accuracy", value: "\(Int(stats.accuracy * 100))%")
        LabeledContent("Last Updated") {
            Text(stats.trainedAt, style: .relative)
        }
    }
    
    if adaptiveParser.isTraining {
        ProgressView(value: adaptiveParser.trainingProgress) {
            Text("Training model...")
        }
    }
    
    Button("Retrain Model Now") {
        Task {
            let corrections = loadAllCorrections()
            try? await adaptiveParser.train(corrections: corrections)
        }
    }
    .disabled(adaptiveParser.isTraining)
}
```

## 🚀 Advanced: Federated Learning

To improve the model across all users while preserving privacy:

1. **Aggregate corrections** (already anonymized via `AnonymousCorrection`)
2. **Train centrally** on your server with combined data
3. **Distribute updated base model** via app updates

This way, everyone benefits from improvements without sharing personal scripts.

## 📊 Metrics to Track

Monitor these to gauge ML effectiveness:

```swift
struct MLMetrics: Codable {
    var predictionsUsed: Int = 0
    var predictionsCorrect: Int = 0  // user didn't correct
    var predictionsCorrected: Int = 0 // user did correct
    
    var accuracy: Double {
        guard predictionsUsed > 0 else { return 0 }
        return Double(predictionsCorrect) / Double(predictionsUsed)
    }
}
```

## 💡 Tips

1. **Start simple**: Text classifier first, add layout features later
2. **Validate regularly**: Keep a held-out test set to catch overfitting
3. **Progressive enhancement**: ML predictions are optional hints, not requirements
4. **Privacy first**: Never upload raw script text, only anonymized corrections
5. **Feedback loop**: Show prediction confidence in UI so users know when to review

## 🔗 Apple Resources

- [Create ML Documentation](https://developer.apple.com/documentation/createml)
- [Core ML Framework](https://developer.apple.com/documentation/coreml)
- [MLUpdateTask (on-device training)](https://developer.apple.com/documentation/coreml/mlupdatetask)
- [WWDC22: What's new in Create ML](https://developer.apple.com/videos/play/wwdc2022/110332/)

---

**Next Steps**: Try building a small base model with 50 examples in a Swift Playground, then integrate `AdaptiveScriptParser` into your app!
