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

    /// すぐに使える XMLTV
    static let xmltvPresets: [(name: String, url: String)] = [
        // 有志が公開している BS・CS の番組表（https://github.com/Animenosekai/japanterebi-xmltv）
        ("民放 BS・CS（japanterebi-xmltv）", "https://animenosekai.github.io/japanterebi-xmltv/guide.xml"),
        // このリポジトリの GitHub Actions（.github/workflows/epg.yml）が作る地上波民放の番組表
        ("地上波民放：福岡", "\(epgDataBaseURL)/guide-fukuoka.xml"),
        ("地上波民放：熊本", "\(epgDataBaseURL)/guide-kumamoto.xml"),
        ("地上波民放：大分", "\(epgDataBaseURL)/guide-oita.xml"),
    ]
    static let epgDataBaseURL = "https://raw.githubusercontent.com/shezenyoudachi-hash/firstrepo/epg-data"

    private var xmltvURLs: [String] {
        xmltvURL.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

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
            TextField("https://example.com/epg.xml", text: $xmltvURL, axis: .vertical)
                .lineLimit(1...6)
                .font(.footnote.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(Self.xmltvPresets, id: \.url) { preset in
                let isAdded = xmltvURLs.contains(preset.url)
                Button {
                    toggleXMLTV(preset.url)
                } label: {
                    Label(preset.name, systemImage: isAdded ? "checkmark.circle.fill" : "plus.circle")
                }
            }
        } header: {
            Text("XMLTV")
        } footer: {
            Text("URL は1行に1つずつ、複数指定できます。下のボタンで追加・削除できます。\n・民放 BS・CS：有志が公開している番組表です。チャンネルが多いため、最初は民放 BS だけを表示します。\n・地上波民放（福岡・熊本・大分）：J:COM の番組表をもとに GitHub Actions で6時間ごとに作っています。NHK は「NHK」をオンにして地域を合わせてください。\nインターネット上の URL は https のみ対応です。")
        }
    }

    /// プリセットの URL を XMLTV の欄に追加する（すでにあれば取り除く）
    private func toggleXMLTV(_ url: String) {
        var urls = xmltvURLs
        if let index = urls.firstIndex(of: url) {
            urls.remove(at: index)
        } else {
            urls.append(url)
        }
        xmltvURL = urls.joined(separator: "\n")
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
