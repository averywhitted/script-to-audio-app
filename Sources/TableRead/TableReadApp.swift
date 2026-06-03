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
                    UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Report a Bug…") {
                    Self.openBugReport()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

extension TableReadApp {
    static func openBugReport() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build      = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os         = ProcessInfo.processInfo.operatingSystemVersionString

        let subject = "Table Read Bug Report — v\(appVersion)"
        let body = """
        App version: \(appVersion) (build \(build))
        macOS: \(os)

        What happened:


        Steps to reproduce:
        1.
        2.

        Expected behavior:

        """

        var comps = URLComponents(string: "mailto:avery@averywhitted.com")!
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body",    value: body),
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
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
