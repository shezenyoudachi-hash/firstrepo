import SwiftUI

@main
struct TVGuideApp: App {
    @State private var store = GuideStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
