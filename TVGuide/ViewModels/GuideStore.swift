import Foundation
import Observation

/// 番組表画面全体の状態
@MainActor
@Observable
final class GuideStore {
    enum SettingsKey {
        /// 旧バージョンの取得元（1つだけ選ぶ方式）。起動時に下の use〜 に移行する
        static let dataSource = "dataSource"
        static let useNHK = "useNHK"
        static let useMirakurun = "useMirakurun"
        static let useXMLTV = "useXMLTV"
        static let apiKey = "nhkAPIKey"
        static let mirakurunURL = "mirakurunURL"
        static let mirakurunChannels = "mirakurunChannels"
        static let xmltvURL = "xmltvURL"
        static let area = "nhkArea"
        static let reminders = "reminderProgramIDs"
        static let channelVisibility = "channelVisibility"
    }

    private(set) var day = BroadcastDay()
    /// 取得したすべてのチャンネルと番組（非表示のチャンネルも含む）
    private(set) var schedule = Schedule(channels: [], programs: [])
    private(set) var isLoading = false
    var errorMessage: String?
    private(set) var reminderIDs: Set<String>
    /// チャンネルごとの表示・非表示（ユーザーが変更したものだけ）
    private(set) var channelVisibility: [String: Bool]

    /// 番組表で表示できる日数（今日から何日先まで）
    let selectableDays = 7

    private let defaults: UserDefaults
    /// 最後に読み込みに成功した取得元（取得元を切り替えて失敗したとき、古い番組表を残さないため）
    @ObservationIgnored private var loadedSources: [DataSource]?
    private let providerOverride: (any ProgramProvider)?

    init(defaults: UserDefaults = .standard, provider: (any ProgramProvider)? = nil) {
        self.defaults = defaults
        self.providerOverride = provider
        self.reminderIDs = Set(defaults.stringArray(forKey: SettingsKey.reminders) ?? [])
        self.channelVisibility = defaults.dictionary(forKey: SettingsKey.channelVisibility) as? [String: Bool] ?? [:]
        Self.migrateLegacySettings(defaults)
    }

    /// 旧バージョンの設定（取得元を1つだけ選ぶ方式、NHK の API キーのみ）を引き継ぐ
    private static func migrateLegacySettings(_ defaults: UserDefaults) {
        let keys = [SettingsKey.useNHK, SettingsKey.useMirakurun, SettingsKey.useXMLTV]
        guard keys.allSatisfy({ defaults.object(forKey: $0) == nil }) else { return }

        switch defaults.string(forKey: SettingsKey.dataSource).flatMap(DataSource.init(rawValue:)) {
        case .nhk: defaults.set(true, forKey: SettingsKey.useNHK)
        case .mirakurun: defaults.set(true, forKey: SettingsKey.useMirakurun)
        case .xmltv: defaults.set(true, forKey: SettingsKey.useXMLTV)
        case .sample: break
        case nil:
            if !(defaults.string(forKey: SettingsKey.apiKey) ?? "").isEmpty {
                defaults.set(true, forKey: SettingsKey.useNHK)
            }
        }
    }

    /// オンになっている取得元。どれもオフならサンプルデータを表示する
    var enabledSources: [DataSource] {
        [(DataSource.nhk, SettingsKey.useNHK), (.xmltv, SettingsKey.useXMLTV), (.mirakurun, SettingsKey.useMirakurun)]
            .filter { defaults.bool(forKey: $0.1) }
            .map(\.0)
    }

    var isUsingSampleData: Bool { providerOverride == nil && enabledSources.isEmpty }

    private func string(_ key: String) -> String {
        (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeProvider(for source: DataSource) throws -> any ProgramProvider {
        switch source {
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

        let sources = providerOverride == nil ? enabledSources : []
        var providers: [(source: DataSource, provider: any ProgramProvider)] = []
        var failures: [(source: DataSource, error: Error)] = []
        if let providerOverride {
            providers = [(.sample, providerOverride)]
        } else if sources.isEmpty {
            providers = [(.sample, SampleProgramProvider())]
        } else {
            for source in sources {
                do {
                    providers.append((source, try makeProvider(for: source)))
                } catch {
                    failures.append((source, error))
                }
            }
        }

        // 取得元ごとに並行して読み込み、取れたものだけでも表示する
        let day = self.day
        var schedules: [Schedule] = []
        await withTaskGroup(of: (DataSource, Result<Schedule, Error>).self) { group in
            for (source, provider) in providers {
                group.addTask {
                    do {
                        return (source, .success(try await provider.fetchSchedule(for: day)))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let schedule): schedules.append(schedule)
                case .failure(let error): failures.append((source, error))
                }
            }
        }

        let isCancelled = failures.contains { failure in
            failure.error is CancellationError || (failure.error as? URLError)?.code == .cancelled
        }
        if Task.isCancelled || isCancelled {
            // 画面遷移などでキャンセルされた場合は何もしない
            return
        }
        guard day == self.day else { return }

        if schedules.isEmpty {
            if loadedSources != sources {
                schedule = Schedule(channels: [], programs: [])
            }
        } else {
            schedule = Self.merge(schedules)
            loadedSources = sources
        }

        if failures.isEmpty {
            errorMessage = nil
        } else {
            let details = failures
                .sorted { $0.source.rawValue < $1.source.rawValue }
                .map { "【\($0.source.displayName)】\($0.error.localizedDescription)" }
                .joined(separator: "\n")
            errorMessage = schedules.isEmpty ? details : "一部の番組表を取得できませんでした\n\(details)"
        }
    }

    /// 複数の取得元の番組表を1つにまとめる（同じ id のチャンネルは最初のものを使う）
    static func merge(_ schedules: [Schedule]) -> Schedule {
        var channels: [Channel] = []
        var channelIDs = Set<String>()
        var programs: [Program] = []
        var programIDs = Set<String>()
        for schedule in schedules {
            for channel in schedule.channels where channelIDs.insert(channel.id).inserted {
                channels.append(channel)
            }
            for program in schedule.programs where programIDs.insert(program.id).inserted {
                programs.append(program)
            }
        }
        channels.sort { ($0.number, $0.name) < ($1.number, $1.name) }
        return Schedule(channels: channels, programs: programs)
    }

    // MARK: - 表示するチャンネル

    /// 番組表に表示するチャンネル（チャンネル番号順）
    var visibleChannels: [Channel] {
        schedule.channels.filter(isVisible)
    }

    func isVisible(_ channel: Channel) -> Bool {
        channelVisibility[channel.id] ?? channel.isVisibleByDefault
    }

    func setVisible(_ channel: Channel, _ isVisible: Bool) {
        channelVisibility[channel.id] = isVisible
        defaults.set(channelVisibility, forKey: SettingsKey.channelVisibility)
    }

    func setAllVisible(_ isVisible: Bool, channels: [Channel]) {
        for channel in channels { channelVisibility[channel.id] = isVisible }
        defaults.set(channelVisibility, forKey: SettingsKey.channelVisibility)
    }

    func programs(on channel: Channel) -> [Program] {
        schedule.programs(on: channel)
    }

    func channel(for program: Program) -> Channel? {
        schedule.channels.first { $0.id == program.channelID }
    }

    /// 現在放送中の番組（表示中のチャンネルのみ、チャンネル順）
    func onAirPrograms(at date: Date = .now) -> [OnAirItem] {
        visibleChannels.compactMap { channel in
            programs(on: channel).first { $0.isOnAir(at: date) }.map { OnAirItem(channel: channel, program: $0) }
        }
    }

    func search(_ text: String) -> [Program] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let channelIDs = Set(visibleChannels.map(\.id))
        return schedule.programs
            .filter { program in
                channelIDs.contains(program.channelID) && [program.title, program.subtitle, program.description, program.cast]
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
        case .nhk: "NHK"
        case .mirakurun: "Mirakurun"
        case .xmltv: "XMLTV"
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
