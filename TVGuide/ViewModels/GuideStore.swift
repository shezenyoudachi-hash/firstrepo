import Foundation
import Observation

/// 番組表画面全体の状態
@MainActor
@Observable
final class GuideStore {
    enum SettingsKey {
        static let dataSource = "dataSource"
        static let apiKey = "nhkAPIKey"
        static let mirakurunURL = "mirakurunURL"
        static let mirakurunChannels = "mirakurunChannels"
        static let xmltvURL = "xmltvURL"
        static let area = "nhkArea"
        static let reminders = "reminderProgramIDs"
    }

    private(set) var day = BroadcastDay()
    private(set) var schedule = Schedule(channels: [], programs: [])
    private(set) var isLoading = false
    var errorMessage: String?
    private(set) var reminderIDs: Set<String>

    /// 番組表で表示できる日数（今日から何日先まで）
    let selectableDays = 7

    private let defaults: UserDefaults
    /// 最後に読み込みに成功した取得元（取得元を切り替えて失敗したとき、古い番組表を残さないため）
    @ObservationIgnored private var loadedSource: DataSource?
    private let providerOverride: (any ProgramProvider)?

    init(defaults: UserDefaults = .standard, provider: (any ProgramProvider)? = nil) {
        self.defaults = defaults
        self.providerOverride = provider
        self.reminderIDs = Set(defaults.stringArray(forKey: SettingsKey.reminders) ?? [])
        Self.migrateLegacySettings(defaults)
    }

    /// 旧バージョン（NHK の API キーのみ）の設定を引き継ぐ
    private static func migrateLegacySettings(_ defaults: UserDefaults) {
        guard defaults.string(forKey: SettingsKey.dataSource) == nil,
              !(defaults.string(forKey: SettingsKey.apiKey) ?? "").isEmpty else { return }
        defaults.set(DataSource.nhk.rawValue, forKey: SettingsKey.dataSource)
    }

    var isUsingSampleData: Bool { providerOverride == nil && dataSource == .sample }

    var dataSource: DataSource {
        DataSource(rawValue: string(SettingsKey.dataSource)) ?? .sample
    }

    private func string(_ key: String) -> String {
        (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeProvider() throws -> any ProgramProvider {
        if let providerOverride { return providerOverride }
        switch dataSource {
        case .sample:
            return SampleProgramProvider()
        case .nhk:
            let area = defaults.string(forKey: SettingsKey.area) ?? Area.default.id
            return NHKProgramProvider(apiKey: string(SettingsKey.apiKey), area: area)
        case .mirakurun:
            guard let url = Self.serverURL(string(SettingsKey.mirakurunURL)) else {
                throw ProgramProviderError.invalidServerURL
            }
            let channels = MirakurunChannelSet(rawValue: string(SettingsKey.mirakurunChannels)) ?? .terrestrial
            return MirakurunProgramProvider(baseURL: url, channelTypes: channels.channelTypes)
        case .xmltv:
            guard let url = Self.serverURL(string(SettingsKey.xmltvURL)) else {
                throw ProgramProviderError.invalidServerURL
            }
            return XMLTVProgramProvider(url: url)
        }
    }

    /// `192.168.1.10:40772` のようにスキームを省略した入力も受け付ける
    static func serverURL(_ input: String) -> URL? {
        guard !input.isEmpty else { return nil }
        let withScheme = input.contains("://") ? input : "http://\(input)"
        guard let url = URL(string: withScheme), url.host() != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var availableDays: [BroadcastDay] {
        let today = BroadcastDay()
        return (0..<selectableDays).map { today.adding(days: $0) }
    }

    func select(day: BroadcastDay) async {
        guard day != self.day else { return }
        self.day = day
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let source = dataSource
            schedule = try await makeProvider().fetchSchedule(for: day)
            loadedSource = source
            errorMessage = nil
        } catch is CancellationError {
            // 画面遷移などでキャンセルされた場合は何もしない
        } catch {
            if loadedSource != dataSource {
                schedule = Schedule(channels: [], programs: [])
            }
            errorMessage = error.localizedDescription
        }
    }

    func programs(on channel: Channel) -> [Program] {
        schedule.programs(on: channel)
    }

    func channel(for program: Program) -> Channel? {
        schedule.channels.first { $0.id == program.channelID }
    }

    /// 現在放送中の番組（チャンネル順）
    func onAirPrograms(at date: Date = .now) -> [OnAirItem] {
        schedule.channels.compactMap { channel in
            programs(on: channel).first { $0.isOnAir(at: date) }.map { OnAirItem(channel: channel, program: $0) }
        }
    }

    func search(_ text: String) -> [Program] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return schedule.programs
            .filter { program in
                [program.title, program.subtitle, program.description, program.cast]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - リマインダー

    func hasReminder(_ program: Program) -> Bool {
        reminderIDs.contains(program.id)
    }

    func toggleReminder(_ program: Program) async {
        if hasReminder(program) {
            ReminderService.shared.cancel(program)
            reminderIDs.remove(program.id)
        } else {
            do {
                try await ReminderService.shared.schedule(program, channelName: channel(for: program)?.name ?? "")
                reminderIDs.insert(program.id)
            } catch {
                errorMessage = "通知の登録に失敗しました：\(error.localizedDescription)"
            }
        }
        defaults.set(Array(reminderIDs), forKey: SettingsKey.reminders)
    }
}

struct OnAirItem: Identifiable {
    let channel: Channel
    let program: Program
    var id: String { program.id }
}

/// 番組表の取得元
enum DataSource: String, CaseIterable, Identifiable {
    case sample
    case nhk
    case mirakurun
    case xmltv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sample: "サンプルデータ"
        case .nhk: "NHK 番組表 API"
        case .mirakurun: "Mirakurun（自宅チューナー）"
        case .xmltv: "XMLTV（URL 指定）"
        }
    }
}

/// NHK API の地域コード
struct Area: Identifiable, Hashable {
    let id: String
    let name: String

    static let `default` = Area(id: "130", name: "東京")

    static let all: [Area] = [
        Area(id: "010", name: "札幌"), Area(id: "040", name: "仙台"),
        Area(id: "130", name: "東京"), Area(id: "140", name: "横浜"),
        Area(id: "150", name: "新潟"), Area(id: "170", name: "金沢"),
        Area(id: "230", name: "名古屋"), Area(id: "270", name: "大阪"),
        Area(id: "280", name: "神戸"), Area(id: "330", name: "岡山"),
        Area(id: "340", name: "広島"), Area(id: "380", name: "松山"),
        Area(id: "400", name: "福岡"), Area(id: "430", name: "熊本"),
        Area(id: "470", name: "那覇"),
    ]
}
