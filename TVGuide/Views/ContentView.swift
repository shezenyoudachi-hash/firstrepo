import SwiftUI

struct ContentView: View {
    @Environment(GuideStore.self) private var store

    var body: some View {
        TabView {
            GuideView()
                .tabItem { Label("番組表", systemImage: "tablecells") }
            OnAirView()
                .tabItem { Label("放送中", systemImage: "play.tv") }
            SearchView()
                .tabItem { Label("検索", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .task { await store.load() }
        .alert("エラー", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environment(GuideStore(provider: SampleProgramProvider()))
}
