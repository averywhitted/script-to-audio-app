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
            CommandGroup(replacing: .help) {
                Button("Table Read Help") {
                    // Reset the flag so the onboarding sheet re-appears on next
                    // ContentView.onAppear — simplest way without an extra binding.
                    UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                    // Post a notification that ContentView listens to.
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

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
