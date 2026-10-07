import Foundation

/// NHK 番組表 API v3（https://api-portal.nhk.or.jp/）から番組を取得する
///
/// `GET https://program-api.nhk.jp/v3/papiPgDateTv?service={service}&area={area}&date={yyyy-MM-dd}&key={apikey}`
///
/// レスポンスは `{ "g1": { "publication": [ { "name", "description", "startDate", "endDate", ... } ] } }` の形。
/// v2（2026年2月で提供終了）とは別物なので、ジャンルや出演者などのフィールドは見つかったものだけ使う。
/// 放送日の 5:00〜翌 5:00 をカバーするため、サービスごとに当日と翌日の 2 日分を取得して結合する。
struct NHKProgramProvider: ProgramProvider {
    var apiKey: String
    /// 地域コード（例: 130 = 東京）
    var area: String
    /// 取得するサービス（チャンネル）
    var services: [String] = NHKProgramProvider.defaultServices
    var session: URLSession = .shared

    static let defaultServices = ["g1", "e1", "s1", "s5"]

    static let serviceNames: [String: String] = [
        "g1": "NHK総合", "g2": "NHK総合2",
        "e1": "NHK Eテレ", "e2": "NHK Eテレ2", "e3": "NHK Eテレ3",
        "s1": "NHK BS", "s2": "NHK BS2",
        "s5": "NHK BSプレミアム4K", "s6": "NHK BS8K",
    ]

    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule {
        guard !apiKey.isEmpty else { throw ProgramProviderError.missingAPIKey }

        let nextDay = BroadcastDay.calendar.date(byAdding: .day, value: 1, to: day.calendarDate)!
        let requests = services.flatMap { service in [(service, day.calendarDate), (service, nextDay)] }

        // 一部のサービスだけ失敗した場合（地域で放送がない等）は、取れた分だけ表示する
        var schedules: [Schedule] = []
        var firstError: Error?
        await withTaskGroup(of: Result<Schedule, Error>.self) { group in
            for (service, date) in requests {
                group.addTask {
                    do {
                        return .success(try await self.fetch(service: service, date: date))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let schedule): schedules.append(schedule)
                case .failure(let error): firstError = firstError ?? error
                }
            }
        }
        if schedules.isEmpty, let firstError { throw firstError }

        let merged = schedules.reduce(Schedule(channels: [], programs: [])) { $0.merging($1) }
        return Schedule(channels: merged.channels, programs: merged.programs.filter(day.overlaps))
    }

    private func fetch(service: String, date: Date) async throws -> Schedule {
        var components = URLComponents(string: "https://program-api.nhk.jp/v3/papiPgDateTv")!
        components.queryItems = [
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "area", value: area),
            URLQueryItem(name: "date", value: Self.dateString(date)),
            URLQueryItem(name: "key", value: apiKey),
        ]

        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw ProgramProviderError.httpError(statusCode: http.statusCode, detail: "\(service): \(body)")
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
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProgramProviderError.invalidData
        }

        var channels: [Channel] = []
        var programs: [Program] = []
        for (serviceID, value) in root {
            guard let publications = (value as? [String: Any])?["publication"] as? [[String: Any]] else { continue }

            let fallbackName = publications.lazy.compactMap { ($0["publishedOn"] as? [String: Any])?["name"] as? String }.first
            channels.append(Channel(
                id: serviceID,
                name: serviceNames[serviceID] ?? fallbackName ?? serviceID.uppercased(),
                number: defaultServicesOrder(serviceID)
            ))

            for item in publications {
                guard let title = item["name"] as? String, !title.isEmpty,
                      let start = (item["startDate"] as? String).flatMap(parseDate),
                      let end = (item["endDate"] as? String).flatMap(parseDate),
                      end > start else { continue }
                let id = (item["id"] as? String)
                    ?? (item["broadcastEventId"] as? String)
                    ?? "\(serviceID)-\(Int(start.timeIntervalSince1970))"
                let misc = item["misc"] as? [String: Any] ?? [:]
                let about = item["about"] as? [String: Any] ?? [:]
                programs.append(Program(
                    id: "nhk-\(serviceID)-\(id)",
                    channelID: serviceID,
                    title: title,
                    subtitle: item["subtitle"] as? String ?? "",
                    description: descriptionText(item, misc: misc),
                    cast: actListText(misc["actList"]) ?? castText(item),
                    startDate: start,
                    endDate: end,
                    genres: primaryGenres(item) ?? genres(in: item),
                    imageURL: imageURL(about),
                    broadcastEvent: broadcastEvent(item, serviceID: serviceID)
                ))
            }
        }
        if channels.isEmpty { throw ProgramProviderError.invalidData }
        return Schedule(channels: channels.sorted { ($0.number, $0.id) < ($1.number, $1.id) }, programs: programs)
    }

    /// `identifierGroup.genre`（例: [{"id": "0000", "name1": "ニュース/報道", ...}]）
    private static func primaryGenres(_ item: [String: Any]) -> [Genre]? {
        guard let list = (item["identifierGroup"] as? [String: Any])?["genre"] else { return nil }
        let genres = genreValues(list)
        return genres.isEmpty ? nil : genres
    }

    /// `identifierGroup` の `sid`（16進のサービス ID、例: "0400"）と `eventId`（10進）
    private static func broadcastEvent(_ item: [String: Any], serviceID: String) -> BroadcastEvent? {
        guard let group = item["identifierGroup"] as? [String: Any],
              let sid = (group["sid"] as? String).flatMap({ Int($0, radix: 16) }),
              let eventID = (group["eventId"] as? String).flatMap({ Int($0) }) else { return nil }
        let kind: BroadcastKind
        switch serviceID.prefix(1) {
        case "g", "e": kind = .terrestrial
        case "s": kind = ["s5", "s6"].contains(serviceID) ? .bs4k : .bs
        default: return nil
        }
        return BroadcastEvent(kind: kind, serviceID: sid, eventID: eventID)
    }

    /// 番組内容 + 補足（`misc.freeLine`）
    private static func descriptionText(_ item: [String: Any], misc: [String: Any]) -> String {
        let description = (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let freeLine = (misc["freeLine"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [description, freeLine].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// `misc.actList`（[{"role": "キャスター", "name": "…"}]）を役割ごとにまとめる
    /// 例: 「キャスター：竜田理史、佐藤茉那\n気象キャスター：檜山靖洋」
    private static func actListText(_ actList: Any?) -> String? {
        guard let acts = actList as? [[String: Any]], !acts.isEmpty else { return nil }
        var roles: [String] = []
        var namesByRole: [String: [String]] = [:]
        for act in acts {
            guard let name = act["name"] as? String, !name.isEmpty else { continue }
            let role = act["role"] as? String ?? ""
            if namesByRole[role] == nil { roles.append(role) }
            namesByRole[role, default: []].append(name)
        }
        let lines = roles.map { role in
            let names = namesByRole[role]!.joined(separator: "、")
            return role.isEmpty ? names : "\(role)：\(names)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// エピソードの画像（`about.eyecatch.medium.url`）、なければシリーズの画像
    private static func imageURL(_ about: [String: Any]) -> URL? {
        let sources = [about, about["partOfSeries"] as? [String: Any] ?? [:]]
        for source in sources {
            guard let eyecatch = source["eyecatch"] as? [String: Any] else { continue }
            for size in ["medium", "main", "small"] {
                if let url = ((eyecatch[size] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                    return url
                }
            }
        }
        return nil
    }

    /// リモコン番号・BS チャンネル番号（4K・8K は 2K の後ろに並べる）
    private static func defaultServicesOrder(_ serviceID: String) -> Int {
        let numbers = ["g1": 1, "g2": 1, "e1": 2, "e2": 2, "e3": 2, "s1": 101, "s2": 102, "s5": 1101, "s6": 1102]
        return numbers[serviceID] ?? 999
    }

    /// `2026-10-07T05:00:00+09:00`（小数秒・タイムゾーンなしにも対応。なしは日本時間とみなす）
    static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = BroadcastDay.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }

    /// `genre` キーを入れ子の中まで探し、ジャンルコード（"0100" など）かジャンル名から判定する
    private static func genres(in object: Any, depth: Int = 0) -> [Genre] {
        guard depth < 4 else { return [] }
        var result: [Genre] = []
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if key.lowercased().contains("genre") {
                    result += genreValues(value)
                } else if value is [String: Any] || value is [Any] {
                    result += genres(in: value, depth: depth + 1)
                }
            }
        } else if let array = object as? [Any] {
            for value in array { result += genres(in: value, depth: depth + 1) }
        }
        var seen = Set<Genre>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func genreValues(_ value: Any) -> [Genre] {
        switch value {
        case let string as String:
            if string.count == 4 && string.allSatisfy(\.isHexDigit) {
                return [Genre(code: string)]
            }
            return Genre(categoryName: string).map { [$0] } ?? []
        case let array as [Any]:
            return array.flatMap(genreValues)
        case let dict as [String: Any]:
            if let id = dict["id"] as? String { return genreValues(id) }
            return ["name1", "name", "lv1"].compactMap { dict[$0] as? String }.prefix(1).flatMap(genreValues)
        default:
            return []
        }
    }

    /// 出演者（`actor` / `act` / `performer`。文字列・配列・{name} のどれでもよい）
    private static func castText(_ item: [String: Any]) -> String {
        for key in ["actor", "act", "performer"] {
            switch item[key] {
            case let string as String where !string.isEmpty:
                return string
            case let array as [Any]:
                let names = array.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
                if !names.isEmpty { return names.joined(separator: "、") }
            default:
                continue
            }
        }
        return ""
    }
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
