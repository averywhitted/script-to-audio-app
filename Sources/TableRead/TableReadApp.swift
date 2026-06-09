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

            #if DEBUG
            CommandMenu("Debug") {
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
