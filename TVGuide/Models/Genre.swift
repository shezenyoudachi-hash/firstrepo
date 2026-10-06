import SwiftUI

/// ARIB 規格の番組ジャンル（大分類）
enum Genre: Int, CaseIterable, Codable, Sendable {
    case news = 0
    case sports
    case information
    case drama
    case music
    case variety
    case movie
    case anime
    case documentary
    case theater
    case hobby
    case welfare
    case other = 15

    var displayName: String {
        switch self {
        case .news: "ニュース／報道"
        case .sports: "スポーツ"
        case .information: "情報／ワイドショー"
        case .drama: "ドラマ"
        case .music: "音楽"
        case .variety: "バラエティ"
        case .movie: "映画"
        case .anime: "アニメ／特撮"
        case .documentary: "ドキュメンタリー／教養"
        case .theater: "劇場／公演"
        case .hobby: "趣味／教育"
        case .welfare: "福祉"
        case .other: "その他"
        }
    }

    /// 番組表のセル背景色
    var color: Color {
        switch self {
        case .news: Color(red: 0.85, green: 0.91, blue: 1.00)
        case .sports: Color(red: 0.86, green: 0.97, blue: 0.86)
        case .information: Color(red: 1.00, green: 0.96, blue: 0.84)
        case .drama: Color(red: 1.00, green: 0.88, blue: 0.90)
        case .music: Color(red: 0.95, green: 0.88, blue: 1.00)
        case .variety: Color(red: 1.00, green: 0.92, blue: 0.82)
        case .movie: Color(red: 0.90, green: 0.86, blue: 0.80)
        case .anime: Color(red: 0.88, green: 0.97, blue: 0.98)
        case .documentary: Color(red: 0.90, green: 0.94, blue: 0.86)
        case .theater: Color(red: 0.97, green: 0.90, blue: 0.97)
        case .hobby: Color(red: 0.93, green: 0.93, blue: 0.88)
        case .welfare: Color(red: 0.92, green: 0.92, blue: 0.97)
        case .other: Color(white: 0.93)
        }
    }

    /// NHK API などの 4 桁ジャンルコード（上 2 桁が大分類）を解釈する
    init(code: String) {
        let major = code.prefix(2)
        let value = Int(major, radix: 16).flatMap { $0 <= 11 ? $0 : nil } ?? Int(major)
        self = value.flatMap(Genre.init(rawValue:)) ?? .other
    }
}
