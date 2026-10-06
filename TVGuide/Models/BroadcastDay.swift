import Foundation

/// 番組表の「1日」。テレビ番組表の慣習に合わせ、朝 5:00 から翌朝 5:00（29:00）までを1日とする。
struct BroadcastDay: Hashable, Sendable {
    static let startHour = 5
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }()

    /// この放送日の開始時刻（その日の 5:00）
    let start: Date

    var end: Date { Self.calendar.date(byAdding: .day, value: 1, to: start)! }

    /// 暦上の日付（API に渡す日付）
    var calendarDate: Date { Self.calendar.startOfDay(for: start) }

    /// 指定時刻を含む放送日（深夜 0:00〜4:59 は前日扱い）
    init(containing date: Date = .now) {
        let cal = Self.calendar
        let shifted = cal.date(byAdding: .hour, value: -Self.startHour, to: date)!
        let day = cal.startOfDay(for: shifted)
        self.start = cal.date(byAdding: .hour, value: Self.startHour, to: day)!
    }

    func adding(days: Int) -> BroadcastDay {
        BroadcastDay(containing: Self.calendar.date(byAdding: .day, value: days, to: start)!)
    }

    /// 開始からの経過分
    func minutes(from date: Date) -> Double {
        date.timeIntervalSince(start) / 60
    }

    func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }

    /// 番組が少しでもこの放送日にかかっているか
    func overlaps(_ program: Program) -> Bool {
        program.startDate < end && program.endDate > start
    }

    /// 表示用ラベル（例: 10/6(月)）
    var label: String {
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.locale = Self.calendar.locale
        formatter.dateFormat = "M/d(E)"
        return formatter.string(from: start)
    }

    /// 開始時刻から n 時間後の「番組表上の時」（5〜28）
    func displayHour(offset: Int) -> Int { Self.startHour + offset }
}
