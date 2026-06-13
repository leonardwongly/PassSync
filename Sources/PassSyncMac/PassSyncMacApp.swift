import SwiftUI

@main
struct PassSyncMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Run Preflight") {
                    Task { await model.runPreflight() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
