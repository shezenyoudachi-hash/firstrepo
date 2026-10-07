import Foundation

/// 番組表データの取得元
protocol ProgramProvider: Sendable {
    /// 指定放送日のチャンネル一覧と番組一覧を返す
    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule
}

struct Schedule: Sendable {
    var channels: [Channel]
    var programs: [Program]

    func programs(on channel: Channel) -> [Program] {
        programs
            .filter { $0.channelID == channel.id }
            .sorted { $0.startDate < $1.startDate }
    }
}

enum ProgramProviderError: LocalizedError {
    case missingAPIKey
    case badResponse(statusCode: Int)
    case httpError(statusCode: Int, detail: String)
    case invalidData
    case invalidServerURL

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "API キーが設定されていません。設定画面から入力してください。"
        case .badResponse(let statusCode):
            "番組表の取得に失敗しました（HTTP \(statusCode)）"
        case .httpError(let statusCode, let detail):
            switch statusCode {
            case 401, 403:
                "API キーが正しくないか、まだ有効になっていません（HTTP \(statusCode)）\n\(detail)"
            default:
                "番組表の取得に失敗しました（HTTP \(statusCode)）\n\(detail)"
            }
        case .invalidData:
            "番組表データを読み込めませんでした。"
        case .invalidServerURL:
            "サーバーの URL が正しくありません。設定画面で確認してください。"
        }
    }
}
