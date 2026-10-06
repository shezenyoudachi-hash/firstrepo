import Foundation

/// 放送局（チャンネル）
struct Channel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    /// リモコンキー番号など、表示順に使う値
    let number: Int
    let logoURL: URL?

    init(id: String, name: String, number: Int, logoURL: URL? = nil) {
        self.id = id
        self.name = name
        self.number = number
        self.logoURL = logoURL
    }
}
