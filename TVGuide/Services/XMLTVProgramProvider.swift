import Foundation

/// [XMLTV](https://wiki.xmltv.org/index.php/XMLTVFormat) 形式の番組表を URL から取得する。
/// EPGStation などの録画サーバーや、外部の EPG 配信サービスが出力する XMLTV を読み込める。
struct XMLTVProgramProvider: ProgramProvider {
    var url: URL
    var session: URLSession = .shared

    /// 1週間分がまとめて入った大きなファイル（数 MB）のことが多いため、
    /// 一度読み込んだ内容をしばらく使い回し、日付を切り替えるたびにダウンロードしない
    static let cache = Cache(lifetime: 30 * 60)

    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule {
        let schedule: Schedule
        if let cached = await Self.cache.schedule(for: url) {
            schedule = cached
        } else {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ProgramProviderError.badResponse(statusCode: http.statusCode)
            }
            schedule = try Self.parse(data)
            await Self.cache.store(schedule, for: url)
        }
        return Schedule(channels: schedule.channels, programs: schedule.programs.filter(day.overlaps))
    }

    /// チャンネル数がこれより多い XMLTV では、主要な BS 局だけを最初から表示する
    static let manyChannelsThreshold = 30

    static func parse(_ data: Data) throws -> Schedule {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? ProgramProviderError.invalidData
        }

        let hasManyChannels = delegate.channels.count > manyChannelsThreshold
        let channels = delegate.channels.map { channel in
            var channel = channel
            channel.isVisibleByDefault = hasManyChannels ? BSChannel.isMain(channel.number) : true
            return channel
        }

        // 同じ番組が重複して入っていることがあるため id で除く
        let channelIDs = Set(channels.map(\.id))
        var seen = Set<String>()
        let programs = delegate.programs.filter { channelIDs.contains($0.channelID) && seen.insert($0.id).inserted }
        return Schedule(channels: channels, programs: programs)
    }

    actor Cache {
        let lifetime: TimeInterval
        private var entries: [URL: (date: Date, schedule: Schedule)] = [:]

        init(lifetime: TimeInterval) { self.lifetime = lifetime }

        func schedule(for url: URL) -> Schedule? {
            guard let entry = entries[url], Date.now.timeIntervalSince(entry.date) < lifetime else { return nil }
            return entry.schedule
        }

        func store(_ schedule: Schedule, for url: URL) {
            entries[url] = (.now, schedule)
        }

        func removeAll() { entries.removeAll() }
    }

    /// XMLTV の日時（例: `20261006050000 +0900`）
    static func parseDate(_ string: String) -> Date? {
        let parts = string.split(separator: " ", maxSplits: 1)
        guard let stamp = parts.first, stamp.count >= 12 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = stamp.count >= 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
        if parts.count == 2 {
            formatter.dateFormat += " Z"
            return formatter.date(from: "\(stamp.prefix(14)) \(parts[1])")
        }
        // タイムゾーン指定がなければ日本時間とみなす
        formatter.timeZone = BroadcastDay.calendar.timeZone
        return formatter.date(from: String(stamp.prefix(14)))
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var channels: [Channel] = []
        var programs: [Program] = []

        private var text = ""
        // <channel>
        private var channelID: String?
        private var displayNames: [String] = []
        private var iconURL: URL?
        // <programme>
        private var programme: [String: String]?
        private var categories: [String] = []
        private var cast: [String] = []
        private var inCredits = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "channel":
                channelID = attributes["id"]
                displayNames = []
                iconURL = nil
            case "programme":
                programme = attributes
                categories = []
                cast = []
            case "icon" where channelID != nil && programme == nil:
                iconURL = attributes["src"].flatMap(URL.init(string:))
            case "credits":
                inCredits = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""

            if programme != nil {
                switch elementName {
                case "title", "sub-title", "desc":
                    if programme?[elementName] == nil { programme?[elementName] = value }
                case "category":
                    categories.append(value)
                case "credits":
                    inCredits = false
                case "programme":
                    finishProgramme()
                default:
                    if inCredits && !value.isEmpty { cast.append(value) }
                }
            } else if channelID != nil {
                switch elementName {
                case "display-name":
                    displayNames.append(value)
                case "channel":
                    finishChannel()
                default:
                    break
                }
            }
        }

        private var channelIDs = Set<String>()

        private func finishChannel() {
            guard let channelID else { return }
            self.channelID = nil
            // 同じチャンネルが複数回定義されていることがあるため、最初のものだけ使う
            guard channelIDs.insert(channelID).inserted else { return }

            let name = displayNames.first { Int($0) == nil } ?? displayNames.first ?? channelID
            // display-name に数字だけのもの（リモコン番号）があればそれを、BS の主要局は BS の番号を使う。
            // どちらもなければファイルの順に、番号のあるチャンネルの後ろへ並べる
            let number = displayNames.lazy.compactMap { Int($0) }.first
                ?? BSChannel.number(forName: name)
                ?? 10_000 + channels.count
            channels.append(Channel(id: channelID, name: name, number: number, logoURL: iconURL))
        }

        private func finishProgramme() {
            defer { programme = nil }
            guard let attributes = programme,
                  let channel = attributes["channel"],
                  let start = attributes["start"].flatMap(XMLTVProgramProvider.parseDate),
                  let stop = attributes["stop"].flatMap(XMLTVProgramProvider.parseDate),
                  let title = attributes["title"], !title.isEmpty,
                  stop > start else { return }
            programs.append(Program(
                id: "xmltv-\(channel)-\(Int(start.timeIntervalSince1970))",
                channelID: channel,
                title: title,
                subtitle: attributes["sub-title"] ?? "",
                description: attributes["desc"] ?? "",
                cast: cast.joined(separator: "、"),
                startDate: start,
                endDate: stop,
                genres: categories.compactMap(Genre.init(categoryName:))
            ))
        }
    }
}

/// BS 局のチャンネル番号（XMLTV にはチャンネル番号が入っていないことが多いため、名前から推定する）
enum BSChannel {
    private static let numbers: [(keyword: String, number: Int)] = [
        ("NHKBS", 101), ("BS日テレ", 141), ("BS朝日", 151), ("BS-TBS", 161), ("BSTBS", 161),
        ("BSテレ東", 171), ("BSフジ", 181), ("BS11", 211), ("BS12", 222), ("BS10", 200), ("BSよしもと", 265),
    ]

    /// 最初から表示する民放 BS
    private static let main: Set<Int> = [141, 151, 161, 171, 181, 211, 222]

    static func number(forName name: String) -> Int? {
        let normalized = normalize(name)
        guard let number = numbers.first(where: { normalized.contains(normalize($0.keyword)) })?.number else {
            return nil
        }
        // 4K 放送は 2K の局と区別して後ろに並べる
        return normalized.contains("4K") ? number + 1_000 : number
    }

    /// 全角英数・記号を半角にし、空白を除いて大文字にそろえる（カタカナも半角になるため、比べる側も同じ変換をする）
    private static func normalize(_ string: String) -> String {
        (string.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? string)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .uppercased()
    }

    static func isMain(_ number: Int) -> Bool { main.contains(number) }
}
