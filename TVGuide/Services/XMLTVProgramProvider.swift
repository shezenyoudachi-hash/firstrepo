import Foundation

/// [XMLTV](https://wiki.xmltv.org/index.php/XMLTVFormat) 形式の番組表を URL から取得する。
/// EPGStation などの録画サーバーや、外部の EPG 配信サービスが出力する XMLTV を読み込める。
struct XMLTVProgramProvider: ProgramProvider {
    var url: URL
    var session: URLSession = .shared

    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProgramProviderError.badResponse(statusCode: http.statusCode)
        }
        let schedule = try Self.parse(data)
        return Schedule(channels: schedule.channels, programs: schedule.programs.filter(day.overlaps))
    }

    static func parse(_ data: Data) throws -> Schedule {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? ProgramProviderError.invalidData
        }
        let channelIDs = Set(delegate.channels.map(\.id))
        return Schedule(
            channels: delegate.channels,
            programs: delegate.programs.filter { channelIDs.contains($0.channelID) }
        )
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

        private func finishChannel() {
            guard let channelID else { return }
            // display-name に数字だけのもの（リモコン番号）があれば番号として使う
            let number = displayNames.lazy.compactMap { Int($0) }.first ?? (channels.count + 1) * 100
            let name = displayNames.first { Int($0) == nil } ?? displayNames.first ?? channelID
            channels.append(Channel(id: channelID, name: name, number: number, logoURL: iconURL))
            self.channelID = nil
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
