import Foundation
import UserNotifications

/// 番組開始前のローカル通知（リマインダー）を管理する
@MainActor
final class ReminderService {
    static let shared = ReminderService()

    nonisolated static let leadMinutesKey = "reminderLeadMinutes"

    /// 開始何分前に通知するか（設定画面で変更可能）
    var leadMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: Self.leadMinutesKey)
        return value > 0 ? value : 5
    }

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func schedule(_ program: Program, channelName: String) async throws {
        guard await requestAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = "まもなく放送：\(program.title)"
        content.body = "\(channelName)　\(program.startDate.formatted(date: .omitted, time: .shortened))〜"
        content.sound = .default

        let fireDate = program.startDate.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        let interval = max(fireDate.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(identifier: program.id, content: content, trigger: trigger))
    }

    func cancel(_ program: Program) {
        center.removePendingNotificationRequests(withIdentifiers: [program.id])
    }
}
