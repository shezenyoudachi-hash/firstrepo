import SwiftUI

@main
struct TVGuideApp: App {
    @State private var store = GuideStore()
    @State private var bravia = BraviaStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(bravia)
        }
    }
}
