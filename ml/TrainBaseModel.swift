import CreateML
import Foundation

/// Sample script for creating the initial base model for TableRead.
/// Run this in a Swift Playground or as a command-line tool.
///
/// This creates a text classifier that predicts script element types
/// based on text content and PDF layout features.

// MARK: - Sample Training Data

/// In production, you'd load this from real script PDFs you've manually labeled.
/// This minimal example shows the data structure.
let sampleData = [
    // Character names (dialog) - ALL CAPS, left-aligned, bold
    ("ALICE", 72.0, 144.0, 1.0, true, false, 12.0, "dialog"),
    ("BOB", 72.0, 120.0, 1.0, true, false, 12.0, "dialog"),
    ("NARRATOR", 72.0, 180.0, 1.0, true, false, 12.0, "dialog"),
    
    // Dialogue text - indented, mixed case
    ("Hello, how are you?", 144.0, 450.0, 0.05, false, false, 12.0, "dialog"),
    ("I'm doing well, thanks.", 144.0, 450.0, 0.05, false, false, 12.0, "dialog"),
    ("What brings you here today?", 144.0, 450.0, 0.04, false, false, 12.0, "dialog"),
    
    // Parentheticals - indented, lowercase, italics or parens
    ("(softly)", 180.0, 250.0, 0.1, false, true, 10.0, "parenthetical"),
    ("(beat)", 180.0, 230.0, 0.1, false, true, 10.0, "parenthetical"),
    ("(laughing)", 180.0, 260.0, 0.1, false, true, 10.0, "parenthetical"),
    
    // Stage directions - full width, mixed case, sometimes italic
    ("She crosses to the window.", 72.0, 500.0, 0.05, false, false, 12.0, "stage_direction"),
    ("The lights fade to black.", 72.0, 500.0, 0.05, false, true, 12.0, "stage_direction"),
    ("A door slams offstage.", 72.0, 500.0, 0.08, false, false, 12.0, "stage_direction"),
    
    // Scene headings - ALL CAPS, full width, bold
    ("INT. COFFEE SHOP - DAY", 72.0, 500.0, 0.8, true, false, 12.0, "scene_heading"),
    ("EXT. PARK - NIGHT", 72.0, 500.0, 0.8, true, false, 12.0, "scene_heading"),
    ("INT. APARTMENT - CONTINUOUS", 72.0, 500.0, 0.75, true, false, 12.0, "scene_heading"),
    
    // More dialog examples with variety
    ("CHARLIE", 72.0, 156.0, 1.0, true, false, 12.0, "dialog"),
    ("Wait, stop!", 144.0, 450.0, 0.1, false, false, 12.0, "dialog"),
    ("This can't be happening.", 144.0, 450.0, 0.05, false, false, 12.0, "dialog"),
    
    // More stage directions
    ("Thunder rumbles in the distance.", 72.0, 500.0, 0.06, false, false, 12.0, "stage_direction"),
    ("He hesitates at the door.", 72.0, 500.0, 0.08, false, false, 12.0, "stage_direction"),
    
    // Edge cases - questions, exclamations
    ("What did you say?", 144.0, 450.0, 0.1, false, false, 12.0, "dialog"),
    ("I can't believe it!", 144.0, 450.0, 0.05, false, false, 12.0, "dialog"),
]

// MARK: - Build Training CSV

func createTrainingCSV() throws -> URL {
    var csv = "text,xMin,xMax,capsRatio,isBold,isItalic,fontSize,kind\n"
    
    for (text, xMin, xMax, capsRatio, isBold, isItalic, fontSize, kind) in sampleData {
        // Escape quotes in text
        let escapedText = text.replacingOccurrences(of: "\"", with: "\"\"")
        csv += "\"\(escapedText)\",\(xMin),\(xMax),\(capsRatio),\(isBold ? 1 : 0),\(isItalic ? 1 : 0),\(fontSize),\(kind)\n"
    }
    
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("script_training_\(UUID().uuidString).csv")
    
    try csv.write(to: tempURL, atomically: true, encoding: .utf8)
    
    print("✅ Created training CSV at: \(tempURL.path)")
    return tempURL
}

// MARK: - Train Model

func trainBaseModel() throws {
    print("🚀 Starting Create ML training...")
    
    // 1. Create training data CSV
    let csvURL = try createTrainingCSV()
    
    // 2. Load as MLDataTable
    print("📊 Loading training data...")
    let data = try MLDataTable(contentsOf: csvURL)
    
    print("   Loaded \(data.rows.count) training examples")
    print("   Columns: \(data.columnNames.joined(separator: ", "))")
    
    // 3. Split into train/validation
    let (train, validation) = data.randomSplit(by: 0.8)
    
    print("   Train set: \(train.rows.count) examples")
    print("   Validation set: \(validation.rows.count) examples")
    
    // 4. Train classifier
    print("\n🧠 Training classifier...")
    
    let parameters = MLClassifier.ModelParameters(
        validation: validation,
        maxIterations: 50
    )
    
    let startTime = Date()
    
    let classifier = try MLClassifier(
        trainingData: train,
        targetColumn: "kind",
        parameters: parameters
    )
    
    let duration = Date().timeIntervalSince(startTime)
    
    print("   ✅ Training complete in \(String(format: "%.1f", duration))s")
    
    // 5. Evaluate
    print("\n📈 Evaluating model...")
    
    let trainEval = classifier.evaluation(on: train)
    let valEval = classifier.evaluation(on: validation)
    
    print("   Training accuracy: \(String(format: "%.1f%%", (1.0 - trainEval.classificationError) * 100))")
    print("   Validation accuracy: \(String(format: "%.1f%%", (1.0 - valEval.classificationError) * 100))")
    
    // 6. Save model
    let outputURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/ScriptParserBase.mlmodel")
    
    print("\n💾 Saving model...")
    
    let metadata = MLModelMetadata(
        author: "TableRead",
        shortDescription: "Base script element classifier",
        version: "1.0",
        license: "MIT",
        readme: """
        This model classifies script elements into categories:
        - dialog: Character speech
        - stage_direction: Action/narration
        - parenthetical: Actor direction
        - scene_heading: Scene/location header
        
        Features: text, xMin, xMax, capsRatio, isBold, isItalic, fontSize
        """
    )
    
    try classifier.write(to: outputURL, metadata: metadata)
    
    print("   ✅ Model saved to: \(outputURL.path)")
    print("\n🎉 Training complete! Add this model to your Xcode project's Resources folder.")
}

// MARK: - Main

do {
    try trainBaseModel()
} catch {
    print("❌ Error: \(error.localizedDescription)")
}

// MARK: - Usage Instructions

/*
 To use this script:
 
 1. Copy this code to a Swift Playground or save as train_model.swift
 
 2. For Playground:
    - Create a new macOS playground
    - Paste this code
    - Run the playground
 
 3. For command-line:
    - Save as train_model.swift
    - Run: swift train_model.swift
 
 4. Find the model:
    - Look on your Desktop for ScriptParserBase.mlmodel
    - Drag it into your Xcode project under Resources/
 
 5. In TableRead:
    - Update AdaptiveScriptParser to load this model
    - Test predictions with AdaptiveParserTests
 
 6. Expand training data:
    - Process real PDFs with your Python backend
    - Export layout features + manual labels
    - Add thousands of examples to improve accuracy
 
 For production quality:
 - Aim for 1000+ examples per class
 - Balance classes (equal dialog/stage_direction/etc.)
 - Include diverse script formats (plays, screenplays, etc.)
 - Test on held-out scripts before shipping
 */
