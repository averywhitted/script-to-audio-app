import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

@main
struct TableReadApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var state = AppState()

    var body: some Scene {
        #if os(macOS)
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
        #else
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }?
            .makeKeyAndOrderFront(nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
#endif
