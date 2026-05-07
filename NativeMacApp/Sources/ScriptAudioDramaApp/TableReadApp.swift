import SwiftUI
import AppKit

@main
struct TableReadApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    // When launched from the terminal the window needs an
                    // explicit activation to receive keyboard input.
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
    }
}
