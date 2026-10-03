# Using Your ScriptClassifier Model - Quick Start Guide

## ✅ You Have: ScriptClassifier.mlmodel on your Desktop

## 🎯 What To Do Next

### Step 1: Add Model to Xcode (2 minutes)

1. **Locate** `ScriptClassifier.mlmodel` on your Desktop
2. **Drag it** into Xcode project navigator (left sidebar)
3. **Drop it** near your other `.swift` files
4. In the dialog:
   - ✅ Check "Copy items if needed"
   - ✅ Select your app target (TableRead)
   - Click **Finish**

**✅ Success:** You'll see `ScriptClassifier.mlmodel` in your project!

### Step 2: Verify Xcode Generated the Swift Class

1. **Click** on `ScriptClassifier.mlmodel` in Xcode
2. You should see model details, inputs/outputs
3. Xcode automatically created a `ScriptClassifier` Swift class you can use!

### Step 3: Test It Works (5 minutes)

Add this to any Swift file (or create `MLTest.swift`):

```swift
import CoreML

func quickMLTest() {
    print("🧪 Testing your ML model...")
    
    do {
        let model = try ScriptClassifier(configuration: MLModelConfiguration())
        
        let tests = [
            "ROMEO": "dialog",
            "She exits.": "stage_direction",
            "(quietly)": "parenthetical",
            "INT. BALCONY - NIGHT": "scene_heading"
        ]
        
        for (text, expected) in tests {
            let prediction = try model.prediction(text: text)
            let match = prediction.label == expected ? "✅" : "❌"
            print("\(match) '\(text)' → \(prediction.label) (expected: \(expected))")
        }
        
        print("🎉 Model loaded and working!")
    } catch {
        print("❌ Error: \(error)")
    }
}
```

Then call `quickMLTest()` somewhere (maybe in your app's initialization) and check the console!

---

## 🚀 Three Ways to Use It

### Option A: Simple Text-Only Predictions (Easiest!)

Just use the auto-generated class:

```swift
import CoreML

class SimpleMLParser {
    private let model: ScriptClassifier
    
    init() throws {
        self.model = try ScriptClassifier(configuration: MLModelConfiguration())
    }
    
    func classify(_ text: String) -> String {
        guard let prediction = try? model.prediction(text: text) else {
            return "dialog" // fallback
        }
        return prediction.label
    }
    
    func classifyWithConfidence(_ text: String) -> (label: String, confidence: Double) {
        guard let prediction = try? model.prediction(text: text) else {
            return ("dialog", 0.0)
        }
        
        let confidence = prediction.labelProbability?[prediction.label] ?? 0.0
        return (prediction.label, confidence)
    }
}

// Usage:
let parser = try SimpleMLParser()
let kind = parser.classify("HAMLET")  // → "dialog"
```

### Option B: Integration with Existing Parser (Recommended!)

Add ML as a validation/confidence layer:

```swift
// In your existing parsing code:
extension AppState {
    
    func parseWithMLValidation(pdf: URL) async throws -> ScriptSummary {
        // 1. Parse with your existing Python backend
        let script = try await pythonBridge.parse(pdf: pdf)
        
        // 2. Add ML confidence scores
        let mlClassifier = try? ScriptClassifier(configuration: MLModelConfiguration())
        
        var enhancedScript = script
        enhancedScript.scenes = script.scenes.map { scene in
            var enhancedScene = scene
            enhancedScene.elements = scene.elements.map { element in
                var enhanced = element
                
                // Get ML prediction
                if let ml = mlClassifier,
                   let prediction = try? ml.prediction(text: element.text) {
                    
                    let mlConfidence = prediction.labelProbability?[prediction.label] ?? 0.0
                    
                    // Flag if ML disagrees with parser
                    if prediction.label != element.kind {
                        enhanced.confidence = mlConfidence
                        enhanced.reason = "ML suggests '\(prediction.label)' (\(Int(mlConfidence * 100))% confident)"
                    } else {
                        // ML agrees - high confidence!
                        enhanced.confidence = mlConfidence
                    }
                }
                
                return enhanced
            }
            return enhancedScene
        }
        
        return enhancedScript
    }
}
```

Now elements flagged for review will include ML suggestions!

### Option C: Full AdaptiveScriptParser (Advanced)

Use the full `AdaptiveScriptParser` class I created, which:
- Loads your model automatically
- Can train on user corrections
- Tracks accuracy over time
- Supports model versioning

```swift
// In AppState or wherever you manage parsing:
@Published var mlParser = AdaptiveScriptParser()

// The parser will automatically find ScriptClassifier.mlmodel and use it!
```

---

## 🎨 Show ML Predictions in Your UI

Add visual feedback when ML disagrees with the parser:

```swift
// In your Review scene element view:
HStack {
    Text(element.displaySpeaker)
        .font(.headline)
    
    if let reason = element.reason, reason.contains("ML suggests") {
        Image(systemName: "brain")
            .foregroundColor(.blue)
            .help(reason)  // Tooltip on hover
    }
}
```

---

## 📊 What You Can Do Now

### Immediate:
✅ Classify any script text  
✅ Get confidence scores  
✅ Flag uncertain elements  

### Short-term (after collecting corrections):
✅ Retrain with real data from your app  
✅ Improve accuracy on your specific script formats  
✅ Version models and track improvement  

### Long-term:
✅ Auto-improve as users correct misclassifications  
✅ Build format-specific models (plays vs. screenplays)  
✅ Share anonymized improvements across all users  

---

## 🧪 Testing Your Integration

I created `TestScriptClassifier.swift` for you. Just:

1. Uncomment the last line: `testScriptClassifier()`
2. Run your app
3. Check the console for predictions

---

## 💡 Pro Tips

### Tip 1: Check Confidence Before Using
```swift
let (label, confidence) = parser.classifyWithConfidence(text)
if confidence > 0.8 {
    // Trust the ML prediction
    useLabel(label)
} else {
    // Fall back to heuristics or flag for review
    flagForReview(text)
}
```

### Tip 2: Log Disagreements
```swift
if mlPrediction != heuristicPrediction {
    print("⚠️ Disagreement on '\(text.prefix(30))':")
    print("   ML: \(mlPrediction) (\(mlConfidence))")
    print("   Heuristic: \(heuristicPrediction)")
}
```

### Tip 3: Add More Training Data Later
Your current model is trained on ~35 examples. To improve:

1. **Export real corrections** from your app
2. **Add them to training data** in the playground
3. **Retrain** the model
4. **Replace** the old .mlmodel file
5. **Accuracy improves automatically!**

---

## 🎉 What You've Accomplished

You just:
1. ✅ Trained your first ML model
2. ✅ Integrated it into a real app
3. ✅ Can make predictions on script text
4. ✅ Have a foundation for continuous improvement

**This is production-ready ML!** Start simple (Option A), then grow into Option B or C as you collect more data.

---

## ❓ Need Help?

- **Model not found?** Make sure you dragged it into Xcode and checked "Copy items"
- **Predictions wrong?** Normal with only 35 training examples - will improve with more data
- **Want layout features?** See `TrainBaseModel.swift` for the advanced version with PDF geometry

**Next:** Try `quickMLTest()` to see your model in action! 🚀
