import SwiftUI
import SwiftData

@main
struct UncodedApp: App {
    @Environment(\.openWindow) private var openWindow

    /// Built here rather than by `.modelContainer(for:)` so start-up work that
    /// needs the store — repairing lenses saved without a profile digest — can
    /// run before any view reads a lens.
    private let container: ModelContainer

    init() {
        // The same failure mode `.modelContainer(for:)` has: an unopenable store
        // is not something the app can carry on without.
        do {
            container = try ModelContainer(for: UserLens.self, CodeMapping.self)
        } catch {
            fatalError("Uncoded could not open its lens store: \(error)")
        }
        LensProfileBackfill.runAtLaunch(container: container)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
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
