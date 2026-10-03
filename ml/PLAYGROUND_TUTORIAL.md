# Your First Machine Learning Model - Step-by-Step Guide

## 🎯 What You'll Build

A classifier that looks at script text and predicts whether it's:
- Dialog (character speech)
- Stage direction (narration)
- Parenthetical (actor note like "softly")
- Scene heading (like "INT. COFFEE SHOP - DAY")

## 📝 Step 1: Create a New Playground

1. **Open Xcode**
2. **File → New → Playground...**
3. Choose **macOS** (top tab)
4. Choose **Blank** template
5. Name it: `ScriptMLTraining`
6. Save it anywhere you like

## ⌨️ Step 2: Paste the Starting Code

Delete everything in the playground and paste this:

```swift
import CreateML
import Foundation

print("🚀 Let's train your first ML model!")
```

**Run it** (click the ▶️ button at the bottom). You should see the print statement in the console.

✅ If you see the output, you're ready to go!

## 📊 Step 3: Add Training Data

Add this code after the print statement:

```swift
// This is our training data - examples the model will learn from
let examples = [
    // Character names - notice they're ALL CAPS and bold
    ("ALICE", "dialog"),
    ("BOB", "dialog"),
    ("CHARLIE", "dialog"),
    
    // What characters say - notice lowercase, longer text
    ("Hello, how are you?", "dialog"),
    ("I'm doing well, thanks.", "dialog"),
    ("What brings you here today?", "dialog"),
    
    // Stage directions - full sentences describing action
    ("She crosses to the window.", "stage_direction"),
    ("The lights fade to black.", "stage_direction"),
    ("A door slams offstage.", "stage_direction"),
    
    // Parentheticals - usually in parentheses
    ("(softly)", "parenthetical"),
    ("(beat)", "parenthetical"),
    ("(laughing)", "parenthetical"),
    
    // Scene headings - ALL CAPS with location
    ("INT. COFFEE SHOP - DAY", "scene_heading"),
    ("EXT. PARK - NIGHT", "scene_heading"),
    ("INT. APARTMENT - CONTINUOUS", "scene_heading"),
]

print("📚 Loaded \(examples.count) training examples")
```

**Run it again.** You should see it loaded 15 examples.

## 🔄 Step 4: Convert to ML Format

Create ML needs data in a special format. Add this:

```swift
// Convert our examples into a format Create ML understands
var rows: [[String: Any]] = []

for (text, label) in examples {
    rows.append([
        "text": text,
        "label": label
    ])
}

print("✅ Converted to ML format")
```

**Run it.** You should see the confirmation.

## 🧠 Step 5: Create and Train the Model

Now the exciting part - let's train! Add this:

```swift
do {
    // Create a CSV file instead - much more reliable in Playgrounds!
    var csvString = "text,label\n"
    for (text, label) in examples {
        // Escape quotes in text for CSV safety
        let escapedText = text.replacingOccurrences(of: "\"", with: "\"\"")
        csvString += "\"\(escapedText)\",\(label)\n"
    }
    
    // Save CSV to temp directory
    let csvURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("training_\(UUID().uuidString).csv")
    
    try csvString.write(to: csvURL, atomically: true, encoding: .utf8)
    
    print("📄 Created training CSV")
    
    // Load the CSV - this works much better in Playgrounds!
    let data = try MLDataTable(contentsOf: csvURL)
    
    print("🧠 Training the model...")
    print("   This might take 10-30 seconds...")
    
    // Train a text classifier
    let classifier = try MLTextClassifier(
        trainingData: data,
        textColumn: "text",
        labelColumn: "label"
    )
    
    print("🎉 Training complete!")
    
} catch {
    print("❌ Error: \(error)")
}
```

**Run it.** This will take 10-30 seconds. You'll see training progress in the console!

## 💾 Step 6: Save Your Model

Add this inside the `do` block, right after `print("🎉 Training complete!")`:

```swift
    // Save the model to your Desktop
    let desktopURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/ScriptClassifier.mlmodel")
    
    try classifier.write(to: desktopURL)
    
    print("💾 Model saved to Desktop/ScriptClassifier.mlmodel")
```

**Run it.** Check your Desktop - you should see a new file `ScriptClassifier.mlmodel`!

## 🧪 Step 7: Test Your Model

Let's see if it works! Add this at the end:

```swift
    print("\n🧪 Testing predictions...")
    
    // Test with new text it hasn't seen before
    let testCases = [
        "DIANA",
        "He walks slowly across the room.",
        "(angrily)",
        "EXT. BEACH - SUNSET"
    ]
    
    for testText in testCases {
        let prediction = try classifier.prediction(from: testText)
        print("   '\(testText)' → \(prediction)")
    }
```

**Run it.** You should see predictions like:
- "DIANA" → dialog
- "He walks slowly..." → stage_direction
- "(angrily)" → parenthetical
- "EXT. BEACH..." → scene_heading

## 🎓 Complete Code (Copy-Paste Ready)

Here's everything together - **this version works reliably in Playgrounds**:

```swift
import CreateML
import Foundation

print("🚀 Let's train your first ML model!")

// Training data
let examples = [
    ("ALICE", "dialog"),
    ("BOB", "dialog"),
    ("CHARLIE", "dialog"),
    ("Hello, how are you?", "dialog"),
    ("I'm doing well, thanks.", "dialog"),
    ("What brings you here today?", "dialog"),
    ("She crosses to the window.", "stage_direction"),
    ("The lights fade to black.", "stage_direction"),
    ("A door slams offstage.", "stage_direction"),
    ("(softly)", "parenthetical"),
    ("(beat)", "parenthetical"),
    ("(laughing)", "parenthetical"),
    ("INT. COFFEE SHOP - DAY", "scene_heading"),
    ("EXT. PARK - NIGHT", "scene_heading"),
    ("INT. APARTMENT - CONTINUOUS", "scene_heading"),
]

print("📚 Loaded \(examples.count) training examples")

do {
    // Create CSV (more reliable than dictionary in Playgrounds)
    var csvString = "text,label\n"
    for (text, label) in examples {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\"\"")
        csvString += "\"\(escapedText)\",\(label)\n"
    }
    
    let csvURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("training_\(UUID().uuidString).csv")
    
    try csvString.write(to: csvURL, atomically: true, encoding: .utf8)
    print("✅ Created training CSV")
    
    // Load CSV into MLDataTable
    let data = try MLDataTable(contentsOf: csvURL)
    
    print("🧠 Training the model...")
    print("   This might take 10-30 seconds...")
    
    // Train classifier
    let classifier = try MLTextClassifier(
        trainingData: data,
        textColumn: "text",
        labelColumn: "label"
    )
    
    print("🎉 Training complete!")
    
    // Save model
    let desktopURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/ScriptClassifier.mlmodel")
    
    try classifier.write(to: desktopURL)
    print("💾 Model saved to Desktop/ScriptClassifier.mlmodel")
    
    // Test predictions
    print("\n🧪 Testing predictions...")
    
    let testCases = [
        "DIANA",
        "He walks slowly across the room.",
        "(angrily)",
        "EXT. BEACH - SUNSET"
    ]
    
    for testText in testCases {
        let prediction = try classifier.prediction(from: testText)
        print("   '\(testText)' → \(prediction)")
    }
    
} catch {
    print("❌ Error: \(error)")
}
```

## 🚀 Next Steps - Add More Data!

Try adding more examples to make it smarter:

```swift
let examples = [
    // Your existing examples...
    
    // Add more variety:
    ("NARRATOR", "dialog"),
    ("Wait, stop!", "dialog"),
    ("I can't believe it!", "dialog"),
    ("Thunder rumbles in the distance.", "stage_direction"),
    ("He hesitates at the door.", "stage_direction"),
    ("(quietly)", "parenthetical"),
    ("(laughs)", "parenthetical"),
    ("INT. LIVING ROOM - MORNING", "scene_heading"),
]
```

The more examples you add, the smarter it gets!

## 🎨 Bonus: See Training Metrics

Want to see how well it learned? Add this after training:

```swift
    // Evaluate accuracy
    let metrics = classifier.evaluation(on: data)
    let accuracy = (1.0 - metrics.classificationError) * 100
    print("📊 Training accuracy: \(String(format: "%.1f", accuracy))%")
```

## 🎯 Challenge: Add Layout Features

Once you're comfortable, try the advanced version with PDF layout data (from `TrainBaseModel.swift`). It uses:
- Text position on page
- Bold/italic styling
- Font size
- Capitalization ratio

This makes predictions MUCH more accurate!

## ❓ Troubleshooting

**"CreateML not found"**
- Make sure you selected **macOS** (not iOS) when creating the playground

**Training takes forever**
- Normal for first run! Subsequent runs are faster
- Close other apps to free up CPU

**Model file not on Desktop**
- Check the console for the exact path
- Look in ~/Desktop/

**Predictions are wrong**
- Need more training examples (aim for 20+ per category)
- Add more variety in your examples

## 🎉 Congratulations!

You just:
1. ✅ Created training data
2. ✅ Trained a machine learning model
3. ✅ Saved it as a .mlmodel file
4. ✅ Made predictions with it

This is the foundation for TableRead's adaptive parser! Next, you can:
- Add this model to your Xcode project
- Use `AdaptiveScriptParser` to load it
- Let it learn from user corrections

**You're a machine learning developer now! 🎓**
