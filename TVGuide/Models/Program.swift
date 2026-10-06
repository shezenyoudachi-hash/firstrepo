import Foundation

/// テレビ番組
struct Program: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let channelID: String
    let title: String
    let subtitle: String
    let description: String
    let cast: String
    let startDate: Date
    let endDate: Date
    let genres: [Genre]

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var primaryGenre: Genre { genres.first ?? .other }

    func isOnAir(at date: Date = .now) -> Bool {
        startDate <= date && date < endDate
    }

    /// 放送中の進捗（0...1）。放送中でなければ nil
    func progress(at date: Date = .now) -> Double? {
        guard isOnAir(at: date), duration > 0 else { return nil }
        return date.timeIntervalSince(startDate) / duration
    }
}
