import Foundation

/// 放送局（チャンネル）
struct Channel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    /// リモコンキー番号など、表示順に使う値
    let number: Int
    let logoURL: URL?
    /// 「表示するチャンネル」で未設定のときに表示するか
    var isVisibleByDefault: Bool

    /// チャンネル番号として表示する値（並び順用の大きな番号は表示しない）
    var displayNumber: String? { number < 1_000 ? "\(number)" : nil }

    init(id: String, name: String, number: Int, logoURL: URL? = nil, isVisibleByDefault: Bool = true) {
        self.id = id
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.isVisibleByDefault = isVisibleByDefault
    }
}
