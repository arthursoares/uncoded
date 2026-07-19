import SwiftUI
import SwiftData

@main
struct UncodedApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [UserLens.self, CodeMapping.self])
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Uncoded") { openWindow(id: "about") }
            }
        }

        Window("About Uncoded", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
