import SwiftUI
import AppKit
import UserNotifications

@main
struct TableReadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { state.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo)
                Button("Redo") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
            }
            CommandGroup(after: .appSettings) {
                Divider()
                if let update = state.availableUpdate {
                    Button("Update to \(update.version)…") {
                        NotificationCenter.default.post(name: .showUpdateSheet, object: nil)
                    }
                } else {
                    Button("Check for Updates") {
                        Task {
                            await state.checkForUpdates()
                            if state.availableUpdate != nil {
                                NotificationCenter.default.post(name: .showUpdateSheet, object: nil)
                            }
                        }
                    }
                }
            }

            CommandMenu("Script") {
                Button("Render Selected Scenes") {
                    state.renderSelectedScenes()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isGenerating || state.selectedScenes.isEmpty
                          || !state.installedEngines.contains(state.selectedEngine))

                Button("Preview First Scene") {
                    state.renderPreviewScene()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isGenerating || state.selectedScenes.isEmpty
                          || !state.installedEngines.contains(state.selectedEngine))

                Divider()

                Button(state.isPaused ? "Resume Render" : "Pause Render") {
                    if state.isPaused { state.resumeGeneration() }
                    else { state.pauseGeneration() }
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!state.isGenerating)

                Button("Cancel Render") {
                    state.cancelGeneration()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!state.isGenerating)

                Divider()

                Button("Skip Already-Rendered Scenes") {
                    Task { await state.selectMissingScenes() }
                }
                .disabled(state.selectedPDF == nil || state.isGenerating)
            }

            CommandGroup(replacing: .help) {
                Button("Table Read Help") {
                    UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Report a Bug…") {
                    Self.openBugReport()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            #if DEBUG || DIAGNOSTIC_MENU
            CommandMenu("Debug") {
                #if DEBUG
                Button("Simulate Update Available") {
                    state.availableUpdate = UpdateInfo(
                        version: "99.0.0",
                        downloadURL: URL(string: "https://github.com/averywhitted/script-to-audio-app/releases")!,
                        htmlURL: URL(string: "https://github.com/averywhitted/script-to-audio-app/releases")!,
                        releaseNotes: "• Dark mode support\n• Kokoro download progress bar\n• Parser improvements for stage plays\n• Bug fixes and performance improvements",
                        hasZipAsset: false
                    )
                }
                Button("Simulate Update (with zip asset)") {
                    state.availableUpdate = UpdateInfo(
                        version: "99.0.0",
                        downloadURL: URL(string: "https://github.com/averywhitted/script-to-audio-app/releases/download/v99.0.0/TableRead.zip")!,
                        htmlURL: URL(string: "https://github.com/averywhitted/script-to-audio-app/releases")!,
                        releaseNotes: "• Dark mode support\n• Kokoro download progress bar\n• Bug fixes",
                        hasZipAsset: true
                    )
                }
                Button("Clear Update State") {
                    state.availableUpdate = nil
                    state.updateDownloadState = .idle
                    state.didPromptForUpdate = false
                }
                Divider()
                Button("Reset Onboarding") {
                    UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                }
                Divider()
                Button("Diagnose Current Script") {
                    if let pdf = state.selectedPDF {
                        Self.runParserDiagnostic(pdf: pdf)
                    }
                }
                .disabled(state.selectedPDF == nil)
                Button("Diagnose PDF…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        Self.runParserDiagnostic(pdf: url)
                    }
                }
                Divider()
                #endif
                Button("Test Update Install…") {
                    let alert = NSAlert()
                    alert.messageText = "Test Update Install"
                    alert.informativeText = "Copies the running app to a temp directory and runs the full install flow — the app will quit and relaunch automatically.\n\nOnly meaningful from a release build (not inside Xcode). Proceed?"
                    alert.addButton(withTitle: "Run Test")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        Task { await AppUpdater.shared.testInstall() }
                    }
                }
                Button("Show Update Log") {
                    NSWorkspace.shared.open(UpdateLogger.logURL)
                }
                Button("Clear Update Log") {
                    UpdateLogger.clear()
                }
            }
            #endif
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

extension TableReadApp {
    static func openBugReport() {
        NotificationCenter.default.post(name: .showBugReport, object: nil)
    }

    #if DEBUG
    static func runParserDiagnostic(pdf: URL) {
        let fm = FileManager.default

        // Locate repo root via the same baked Info.plist key PythonBridge uses.
        guard let repoRoot = Bundle.main.infoDictionary?["TRRepoRoot"] as? String else {
            showDiagnosticError("TRRepoRoot not set in Info.plist")
            return
        }
        let rootURL = URL(fileURLWithPath: repoRoot)
        let script = rootURL.appendingPathComponent("scripts/diagnose_parse.py")
        guard fm.fileExists(atPath: script.path) else {
            showDiagnosticError("diagnose_parse.py not found at \(script.path)")
            return
        }

        // Pick Python interpreter — prefer .venv, fall back to python3 on PATH.
        let venv = rootURL.appendingPathComponent(".venv/bin/python3")
        let python = fm.fileExists(atPath: venv.path) ? venv.path : "python3"

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let outFile = desktop.appendingPathComponent("table_read_diagnosis.txt")

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [python, script.path, pdf.path]
            proc.currentDirectoryURL = rootURL

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                try output.write(to: outFile)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(outFile)
                }
            } catch {
                DispatchQueue.main.async {
                    showDiagnosticError(error.localizedDescription)
                }
            }
        }
    }

    private static func showDiagnosticError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Parser Diagnostic Failed"
        alert.informativeText = message
        alert.runModal()
    }
    #endif
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Register as delegate so notifications appear even when the app is in the foreground.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        // Make the window key *before* the activating click is processed so
        // that first click fires buttons directly instead of just focusing.
        NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }?
            .makeKeyAndOrderFront(nil)
    }

    // Show notification banners even while Table Read is the active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
