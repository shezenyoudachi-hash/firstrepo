import SwiftUI

struct SettingsView: View {
    @Environment(GuideStore.self) private var store
    @AppStorage(GuideStore.SettingsKey.useNHK) private var useNHK = false
    @AppStorage(GuideStore.SettingsKey.useXMLTV) private var useXMLTV = false
    @AppStorage(GuideStore.SettingsKey.useMirakurun) private var useMirakurun = false
    @AppStorage(GuideStore.SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(GuideStore.SettingsKey.area) private var area = Area.default.id
    @AppStorage(GuideStore.SettingsKey.mirakurunURL) private var mirakurunURL = ""
    @AppStorage(GuideStore.SettingsKey.mirakurunChannels) private var mirakurunChannels = MirakurunChannelSet.terrestrial
    @AppStorage(GuideStore.SettingsKey.xmltvURL) private var xmltvURL = ""
    @AppStorage(ReminderService.leadMinutesKey) private var leadMinutes = 5

    @State private var reloadTask: Task<Void, Never>?

    /// BS・CS の番組表を配信している XMLTV（https://github.com/Animenosekai/japanterebi-xmltv）
    static let japanterebiURL = "https://animenosekai.github.io/japanterebi-xmltv/guide.xml"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("NHK（総合・Eテレ・BS）", isOn: $useNHK)
                    Toggle("XMLTV（民放 BS・CS など）", isOn: $useXMLTV)
                    Toggle("Mirakurun（自宅チューナー）", isOn: $useMirakurun)
                } header: {
                    Text("番組表データ")
                } footer: {
                    Text("オンにした取得元の番組表を1つにまとめて表示します。どれもオフのときはサンプルデータを表示します。")
                }

                if useNHK { nhkSection }
                if useXMLTV { xmltvSection }
                if useMirakurun { mirakurunSection }

                Section {
                    NavigationLink {
                        ChannelSelectionView()
                    } label: {
                        LabeledContent("表示するチャンネル",
                                       value: "\(store.visibleChannels.count) / \(store.schedule.channels.count)")
                    }
                    Button("番組表を再読み込み") {
                        Task { await store.load() }
                    }
                }

                Section("通知") {
                    Stepper("放送 \(leadMinutes) 分前に通知", value: $leadMinutes, in: 1...60)
                }
            }
            .navigationTitle("設定")
            .onChange(of: useNHK) { reload() }
            .onChange(of: useXMLTV) { reload() }
            .onChange(of: useMirakurun) { reload() }
            .onChange(of: apiKey) { reload() }
            .onChange(of: area) { reload() }
            .onChange(of: mirakurunURL) { reload() }
            .onChange(of: mirakurunChannels) { reload() }
            .onChange(of: xmltvURL) { reload() }
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

    private var xmltvSection: some View {
        Section {
            TextField("https://example.com/epg.xml", text: $xmltvURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if xmltvURL != Self.japanterebiURL {
                Button("BS・CS の番組表（japanterebi-xmltv）を使う") {
                    xmltvURL = Self.japanterebiURL
                }
            }
        } header: {
            Text("XMLTV")
        } footer: {
            Text("japanterebi-xmltv は有志が公開している BS・CS の番組表です（地上波の民放は含まれません）。チャンネルが多いため、最初は民放 BS だけを表示します。インターネット上の URL は https のみ対応です。")
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
