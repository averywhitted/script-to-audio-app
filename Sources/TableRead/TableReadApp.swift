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
