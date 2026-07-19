import SwiftUI
import SwiftData

@main
struct UncodedApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [UserLens.self, CodeMapping.self])
    }
}
