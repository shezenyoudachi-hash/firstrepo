import SwiftUI

struct SettingsView: View {
    @Environment(GuideStore.self) private var store
    @AppStorage(GuideStore.SettingsKey.dataSource) private var dataSource = DataSource.sample
    @AppStorage(GuideStore.SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(GuideStore.SettingsKey.area) private var area = Area.default.id
    @AppStorage(GuideStore.SettingsKey.mirakurunURL) private var mirakurunURL = ""
    @AppStorage(GuideStore.SettingsKey.mirakurunChannels) private var mirakurunChannels = MirakurunChannelSet.terrestrial
    @AppStorage(GuideStore.SettingsKey.xmltvURL) private var xmltvURL = ""
    @AppStorage(ReminderService.leadMinutesKey) private var leadMinutes = 5

    @State private var reloadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("取得元", selection: $dataSource) {
                        ForEach(DataSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                } header: {
                    Text("番組表データ")
                } footer: {
                    Text(dataSourceDescription)
                }

                switch dataSource {
                case .sample:
                    EmptyView()
                case .nhk:
                    nhkSection
                case .mirakurun:
                    mirakurunSection
                case .xmltv:
                    xmltvSection
                }

                Section {
                    Button("番組表を再読み込み") {
                        Task { await store.load() }
                    }
                }

                Section("通知") {
                    Stepper("放送 \(leadMinutes) 分前に通知", value: $leadMinutes, in: 1...60)
                }
            }
            .navigationTitle("設定")
            .onChange(of: dataSource) { reload() }
            .onChange(of: apiKey) { reload() }
            .onChange(of: area) { reload() }
            .onChange(of: mirakurunURL) { reload() }
            .onChange(of: mirakurunChannels) { reload() }
            .onChange(of: xmltvURL) { reload() }
        }
    }

    private var dataSourceDescription: String {
        switch dataSource {
        case .sample:
            "地上波 7 局分のダミー番組を表示します。"
        case .nhk:
            "NHK の各チャンネルの番組表を取得します（民放は含まれません）。"
        case .mirakurun:
            "自宅のチューナーサーバーが受信した EPG から、民放を含む実際の番組表を表示します。"
        case .xmltv:
            "XMLTV 形式の番組表 URL を読み込みます。EPGStation などの録画サーバーや EPG 配信サービスで利用できます。"
        }
    }

    private var nhkSection: some View {
        Section {
            SecureField("API キー", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("地域", selection: $area) {
                ForEach(Area.all) { area in
                    Text(area.name).tag(area.id)
                }
            }
        } header: {
            Text("NHK 番組表 API")
        } footer: {
            Link("API キーを取得（NHK API ポータル）",
                 destination: URL(string: "https://api-portal.nhk.or.jp/")!)
        }
    }

    private var mirakurunSection: some View {
        Section {
            TextField("例: 192.168.1.10:40772", text: $mirakurunURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("表示する放送", selection: $mirakurunChannels) {
                ForEach(MirakurunChannelSet.allCases) { set in
                    Text(set.displayName).tag(set)
                }
            }
        } header: {
            Text("Mirakurun サーバー")
        } footer: {
            Text("同じ Wi-Fi などから接続できるサーバーのアドレスとポート（標準は 40772）を入力してください。初回はローカルネットワークへのアクセス許可を求められます。")
        }
    }

    private var xmltvSection: some View {
        Section {
            TextField("https://example.com/epg.xml", text: $xmltvURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("XMLTV")
        } footer: {
            Text("インターネット上の URL は https のみ対応です。http はローカルネットワーク内のサーバーに限られます。")
        }
    }

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
