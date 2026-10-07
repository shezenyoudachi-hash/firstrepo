import Foundation

/// 放送波の種類（テレビへの録画予約で、どのチャンネルかを指定するのに使う）
enum BroadcastKind: String, Codable, Sendable, CaseIterable {
    case terrestrial
    case bs
    case cs
    case bs4k

    /// BRAVIA のチャンネル一覧（`avContent.getContentList`）の source
    var braviaSource: String {
        switch self {
        case .terrestrial: "tv:isdbt"
        case .bs: "tv:isdbbs"
        case .cs: "tv:isdbcs"
        case .bs4k: "tv:isdbs3bs"
        }
    }

    init?(xmltv value: String) {
        switch value.lowercased() {
        case "terrestrial", "gr", "isdbt": self = .terrestrial
        case "bs", "isdbbs": self = .bs
        case "cs", "isdbcs": self = .cs
        case "bs4k", "isdbs3bs": self = .bs4k
        default: return nil
        }
    }
}

/// 番組を放送波の上で特定する番号（ARIB のサービス ID とイベント ID）。
/// 取得元が提供している場合だけ入り、テレビへの録画予約に使う。
struct BroadcastEvent: Hashable, Codable, Sendable {
    var kind: BroadcastKind
    var serviceID: Int
    var eventID: Int
}
