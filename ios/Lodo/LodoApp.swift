import SwiftUI
import SwiftData

@main
struct LodoApp: App {
    let container: ModelContainer

    init() {
        container = AppDatabase.container
        NotificationManager.shared.configure(container: container)
        #if DEBUG
        DemoSeed.populateIfRequested(container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
