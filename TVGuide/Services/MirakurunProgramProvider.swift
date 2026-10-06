import Foundation

/// 自宅のチューナーサーバー [Mirakurun](https://github.com/Chinachu/Mirakurun) から EPG を取得する。
/// 実際に受信している地上波（民放・NHK）や BS/CS の番組表をそのまま表示できる。
///
/// - `GET /api/services` : チャンネル（サービス）一覧
/// - `GET /api/programs` : 受信済み EPG の番組一覧
struct MirakurunProgramProvider: ProgramProvider {
    var baseURL: URL
    var channelTypes: Set<String> = ["GR"]
    var session: URLSession = .shared

    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule {
        async let servicesData = get("api/services")
        async let programsData = get("api/programs")
        let (services, programs) = try await (servicesData, programsData)
        let schedule = try Self.decode(services: services, programs: programs,
                                       baseURL: baseURL, channelTypes: channelTypes)
        return Schedule(channels: schedule.channels, programs: schedule.programs.filter(day.overlaps))
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(from: baseURL.appending(path: path))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProgramProviderError.badResponse(statusCode: http.statusCode)
        }
        return data
    }

    static func decode(services: Data, programs: Data, baseURL: URL, channelTypes: Set<String>) throws -> Schedule {
        let decoder = JSONDecoder()
        let serviceItems = try decoder.decode([Service].self, from: services)
            .filter { $0.type == 1 && channelTypes.contains($0.channel?.type ?? "") } // type 1 = デジタル TV

        // 同じサービスが複数の物理チャンネルに現れることがあるため id で重複を除く
        var seen = Set<Int>()
        let uniqueServices = serviceItems.filter { seen.insert($0.id).inserted }

        let channels = uniqueServices
            .sorted { ($0.typeOrder, $0.displayNumber, $0.serviceId) < ($1.typeOrder, $1.displayNumber, $1.serviceId) }
            .map { service in
                Channel(
                    id: service.channelID,
                    name: service.name,
                    number: service.displayNumber,
                    logoURL: service.hasLogoData == true
                        ? baseURL.appending(path: "api/services/\(service.id)/logo")
                        : nil
                )
            }

        let channelIDs = Set(channels.map(\.id))
        let items = try decoder.decode([ProgramItem].self, from: programs)
        let result: [Program] = items.compactMap { item in
            let channelID = Service.channelID(networkId: item.networkId, serviceId: item.serviceId)
            guard channelIDs.contains(channelID), let name = item.name, !name.isEmpty else { return nil }
            let start = Date(timeIntervalSince1970: TimeInterval(item.startAt) / 1000)
            var extended = item.extended ?? [:]
            let cast = extended.removeValue(forKey: "出演者") ?? ""
            let extra = extended
                .sorted { $0.key < $1.key }
                .map { "【\($0.key)】\n\($0.value)" }
            return Program(
                id: "mirakurun-\(item.id)",
                channelID: channelID,
                title: name,
                subtitle: "",
                description: ([item.description ?? ""] + extra).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                cast: cast,
                startDate: start,
                endDate: start.addingTimeInterval(TimeInterval(item.duration) / 1000),
                genres: (item.genres ?? []).compactMap { $0.lv1.flatMap(Genre.init(rawValue:)) }
            )
        }
        return Schedule(channels: channels, programs: result)
    }

    // MARK: - レスポンス定義

    struct Service: Decodable {
        let id: Int
        let serviceId: Int
        let networkId: Int
        let name: String
        let type: Int
        let remoteControlKeyId: Int?
        let hasLogoData: Bool?
        let channel: PhysicalChannel?

        struct PhysicalChannel: Decodable {
            let type: String
            let channel: String
        }

        static func channelID(networkId: Int, serviceId: Int) -> String {
            "mirakurun-\(networkId)-\(serviceId)"
        }

        var channelID: String { Self.channelID(networkId: networkId, serviceId: serviceId) }

        /// 地上波はリモコン番号、BS/CS はサービス ID（例: BS 141）
        var displayNumber: Int {
            channel?.type == "GR" ? (remoteControlKeyId ?? serviceId) : serviceId
        }

        var typeOrder: Int {
            ["GR", "BS", "CS", "SKY"].firstIndex(of: channel?.type ?? "") ?? 9
        }
    }

    struct ProgramItem: Decodable {
        let id: Int
        let serviceId: Int
        let networkId: Int
        let startAt: Int64
        let duration: Int64
        let name: String?
        let description: String?
        let genres: [GenreItem]?
        let extended: [String: String]?
    }

    struct GenreItem: Decodable {
        let lv1: Int?
    }
}

/// Mirakurun で表示する放送波
enum MirakurunChannelSet: String, CaseIterable, Identifiable {
    case terrestrial
    case terrestrialAndBS
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terrestrial: "地上波のみ"
        case .terrestrialAndBS: "地上波＋BS"
        case .all: "すべて（CS含む）"
        }
    }

    var channelTypes: Set<String> {
        switch self {
        case .terrestrial: ["GR"]
        case .terrestrialAndBS: ["GR", "BS"]
        case .all: ["GR", "BS", "CS", "SKY"]
        }
    }
}
