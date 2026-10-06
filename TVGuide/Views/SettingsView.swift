import SwiftUI

struct SettingsView: View {
    @Environment(GuideStore.self) private var store
    @AppStorage(GuideStore.SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(GuideStore.SettingsKey.area) private var area = Area.default.id
    @AppStorage(ReminderService.leadMinutesKey) private var leadMinutes = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API キー", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("地域", selection: $area) {
                        ForEach(Area.all) { area in
                            Text(area.name).tag(area.id)
                        }
                    }
                    Button("番組表を再読み込み") {
                        Task { await store.load() }
                    }
                } header: {
                    Text("NHK 番組表 API")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API キーが未設定の場合はサンプルデータを表示します。")
                        Link("API キーを取得（NHK API ポータル）",
                             destination: URL(string: "https://api-portal.nhk.or.jp/")!)
                    }
                }

                Section("通知") {
                    Stepper("放送 \(leadMinutes) 分前に通知", value: $leadMinutes, in: 1...60)
                }
            }
            .navigationTitle("設定")
            .onChange(of: apiKey) { reload() }
            .onChange(of: area) { reload() }
        }
    }

    @State private var reloadTask: Task<Void, Never>?

    /// 入力中に毎回リクエストしないよう少し待ってから再読み込みする
    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await store.load()
        }
    }
}
