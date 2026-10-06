import Foundation
import Observation

/// 番組表画面全体の状態
@MainActor
@Observable
final class GuideStore {
    enum SettingsKey {
        static let apiKey = "nhkAPIKey"
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
    private let providerOverride: (any ProgramProvider)?

    init(defaults: UserDefaults = .standard, provider: (any ProgramProvider)? = nil) {
        self.defaults = defaults
        self.providerOverride = provider
        self.reminderIDs = Set(defaults.stringArray(forKey: SettingsKey.reminders) ?? [])
    }

    var isUsingSampleData: Bool { providerOverride == nil && apiKey.isEmpty }

    private var apiKey: String { defaults.string(forKey: SettingsKey.apiKey) ?? "" }

    private var provider: any ProgramProvider {
        if let providerOverride { return providerOverride }
        if apiKey.isEmpty { return SampleProgramProvider() }
        return NHKProgramProvider(apiKey: apiKey, area: defaults.string(forKey: SettingsKey.area) ?? Area.default.id)
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
            schedule = try await provider.fetchSchedule(for: day)
            errorMessage = nil
        } catch is CancellationError {
            // 画面遷移などでキャンセルされた場合は何もしない
        } catch {
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
