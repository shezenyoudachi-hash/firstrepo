import Foundation

/// NHK 番組表 API（https://api-portal.nhk.or.jp/）から番組を取得する
///
/// 番組リスト API: `GET /v2/pg/list/{area}/{service}/{date}.json?key={apikey}`
/// 放送日の 5:00〜翌 5:00 をカバーするため、当日と翌日の 2 日分を取得して結合する。
struct NHKProgramProvider: ProgramProvider {
    var apiKey: String
    /// 地域コード（例: 130 = 東京）
    var area: String
    /// サービス（tv = テレビ全サービス）
    var service: String = "tv"
    var session: URLSession = .shared

    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule {
        guard !apiKey.isEmpty else { throw ProgramProviderError.missingAPIKey }

        let nextDay = BroadcastDay.calendar.date(byAdding: .day, value: 1, to: day.calendarDate)!
        async let today = fetch(date: day.calendarDate)
        async let tomorrow = fetch(date: nextDay)
        let (first, second) = try await (today, tomorrow)
        let merged = first.merging(second)

        let programs = merged.programs.filter(day.overlaps)
        return Schedule(channels: merged.channels, programs: programs)
    }

    private func fetch(date: Date) async throws -> Schedule {
        let url = URL(string: "https://api.nhk.or.jp/v2/pg/list/\(area)/\(service)/\(Self.dateString(date)).json")!
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProgramProviderError.badResponse(statusCode: http.statusCode)
        }
        return try Self.decode(data)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = BroadcastDay.calendar
        formatter.timeZone = BroadcastDay.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// API レスポンスを Schedule に変換する
    static func decode(_ data: Data) throws -> Schedule {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: data)

        var channels: [String: Channel] = [:]
        var programs: [Program] = []
        // キーの並び（g1, e1, s1 ...）は JSON 上の順序が保証されないため、既知の順に並べる
        for (serviceID, items) in response.list {
            for item in items {
                if channels[serviceID] == nil {
                    channels[serviceID] = Channel(
                        id: serviceID,
                        name: item.service.name,
                        number: serviceOrder.firstIndex(of: serviceID) ?? serviceOrder.count,
                        logoURL: item.service.logo_s.flatMap { URL(string: $0.url) }
                    )
                }
                programs.append(Program(
                    id: item.id,
                    channelID: serviceID,
                    title: item.title,
                    subtitle: item.subtitle ?? "",
                    description: item.content ?? "",
                    cast: item.act ?? "",
                    startDate: item.start_time,
                    endDate: item.end_time,
                    genres: (item.genres ?? []).map(Genre.init(code:))
                ))
            }
        }
        let sortedChannels = channels.values.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        return Schedule(channels: sortedChannels, programs: programs)
    }

    private static let serviceOrder = ["g1", "g2", "e1", "e2", "e3", "s1", "s2", "s3", "s4", "s5", "s6"]

    // MARK: - レスポンス定義

    // swiftlint:disable identifier_name
    struct Response: Decodable {
        let list: [String: [Item]]
    }

    struct Item: Decodable {
        let id: String
        let start_time: Date
        let end_time: Date
        let service: Service
        let title: String
        let subtitle: String?
        let content: String?
        let act: String?
        let genres: [String]?
    }

    struct Service: Decodable {
        let id: String
        let name: String
        let logo_s: Logo?
    }

    struct Logo: Decodable {
        let url: String
    }
    // swiftlint:enable identifier_name
}

private extension Schedule {
    func merging(_ other: Schedule) -> Schedule {
        var channels = self.channels
        for channel in other.channels where !channels.contains(where: { $0.id == channel.id }) {
            channels.append(channel)
        }
        var seen = Set(programs.map(\.id))
        var programs = self.programs
        for program in other.programs where seen.insert(program.id).inserted {
            programs.append(program)
        }
        return Schedule(channels: channels.sorted { $0.number < $1.number }, programs: programs)
    }
}
