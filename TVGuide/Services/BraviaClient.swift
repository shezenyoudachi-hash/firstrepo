import Foundation
import Security

/// ソニーのテレビ BRAVIA に録画予約をする（同じ LAN 内のテレビの JSON-RPC、通称 Scalar API）。
///
/// - `POST http://<テレビ>/sony/<service>` に `{"method", "id", "params", "version"}` を送る
/// - 登録: `accessControl.actRegister`。初回はテレビに PIN が表示され（HTTP 401）、その PIN を Basic 認証で
///   送り直すと `auth` クッキーがもらえる。以後のリクエストはこのクッキーを付ける
/// - 予約: `recording.addSchedule` 1.1（番組のイベント ID で予約する）
///
/// 手順と各項目の書き方は、実機で確かめられた [bdzbridge](https://github.com/hiroaki0923/bdzbridge)（MIT）の
/// 記録に従っている。ソニー非公式の使い方で、機種やソフトウェアのバージョンによっては使えないことがある。
actor BraviaClient {
    let host: String
    private let store: any BraviaCredentialStore
    private let session: URLSession
    /// チャンネル（放送波の種類とサービス ID）→ 予約に使う uri。テレビから一度読んだら使い回す
    private var stationURIs: [String: String]?
    private var requestID = 0

    static let nickname = "番組表アプリ"
    /// `avContent.getContentList` 1 回で読むチャンネル数
    static let stationsPerPage = 50

    init(host: String, store: any BraviaCredentialStore, session: URLSession = BraviaClient.makeSession()) {
        self.host = host
        self.store = store
        self.session = session
    }

    /// クッキーは自分で管理する（URLSession に保存させない）
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    // MARK: - 登録

    /// テレビの電源の状態（"active" / "standby"）。登録なしで使え、テレビに届くかの確認に使う
    func powerStatus() async throws -> String {
        let result = try await call("system", "getPowerStatus", version: "1.0")
        guard let status = (result as? [[String: Any]])?.first?["status"] as? String else {
            throw BraviaError.unreadable("getPowerStatus")
        }
        return status
    }

    /// 登録を始める。テレビに PIN が表示されたら false、PIN なしで登録できた（登録済みだった）ら true
    func startRegistration() async throws -> Bool {
        try await actRegister(pin: nil)
    }

    /// テレビに表示された PIN で登録する
    func register(pin: String) async throws {
        guard try await actRegister(pin: pin) else { throw BraviaError.wrongPIN }
    }

    private func actRegister(pin: String?) async throws -> Bool {
        let credentials = store.load() ?? BraviaCredentials(clientID: "TVGuide:\(UUID().uuidString)")
        if store.load() == nil { store.save(credentials) }

        var headers = ["Content-Type": "application/json"]
        if let pin {
            headers["Authorization"] = "Basic " + Data(":\(pin)".utf8).base64EncodedString()
        }
        let params: [Any] = [
            ["clientid": credentials.clientID, "nickname": Self.nickname, "level": "private"],
            [["value": "no", "function": "WOL"]],
        ]
        let (data, response) = try await send("accessControl", "actRegister", version: "1.0",
                                              params: params, headers: headers)
        if response.statusCode == 401 { return false }
        do {
            _ = try Self.result(data: data, response: response, method: "actRegister")
        } catch BraviaError.rpc(let code, _) where code == 40005 && pin != nil {
            throw BraviaError.wrongPIN
        }
        guard let cookie = response.value(forHTTPHeaderField: "Set-Cookie").flatMap(Self.authCookie) else {
            throw BraviaError.unreadable("actRegister")
        }
        var updated = credentials
        updated.cookie = cookie
        store.save(updated)
        return true
    }

    /// `Set-Cookie` から `auth` の値を取り出す
    static func authCookie(_ header: String) -> String? {
        for part in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("auth="), part.count > 5 { return String(part.dropFirst(5)) }
        }
        return nil
    }

    // MARK: - 録画予約

    /// 番組を録画予約するときに送る内容
    func reservation(for program: Program) async throws -> BraviaReservation {
        guard let event = program.broadcastEvent else { throw BraviaError.noBroadcastEvent }
        guard let uri = try await stationURI(kind: event.kind, serviceID: event.serviceID) else {
            throw BraviaError.stationNotFound
        }
        return BraviaReservation(program: program, event: event, uri: uri)
    }

    /// 予約すると録画できなくなる予約（`recording.getConflictScheduleList` 1.0。何も変更しない）
    func conflicts(for reservation: BraviaReservation) async throws -> [BraviaSchedule] {
        let result = try await authenticated("recording", "getConflictScheduleList", version: "1.0",
                                             params: [reservation.conflictQuery])
        guard let rows = (result as? [Any])?.first as? [Any] else {
            throw BraviaError.unreadable("getConflictScheduleList")
        }
        return rows.compactMap { ($0 as? [String: Any]).flatMap(BraviaSchedule.init) }
    }

    /// 録画予約する（`recording.addSchedule` 1.1）
    func add(_ reservation: BraviaReservation) async throws {
        _ = try await authenticated("recording", "addSchedule", version: "1.1", params: [reservation.creation])
    }

    /// テレビの予約一覧（`recording.getScheduleList` 1.1）
    func schedules() async throws -> [BraviaSchedule] {
        let result = try await authenticated("recording", "getScheduleList", version: "1.1",
                                             params: [["stIdx": 0, "cnt": 130]])
        guard let rows = (result as? [Any])?.first as? [Any] else {
            throw BraviaError.unreadable("getScheduleList")
        }
        return rows.compactMap { ($0 as? [String: Any]).flatMap(BraviaSchedule.init) }
    }

    /// 予約を削除する（`recording.deleteSchedule` 1.1。毎回録画の予約はまとめて消える）
    func delete(_ schedule: BraviaSchedule) async throws {
        _ = try await authenticated("recording", "deleteSchedule", version: "1.1", params: [[schedule.deletion]])
    }

    /// チャンネルの uri。テレビの一覧で返ったものをそのまま使う（組み立て直さない）
    func stationURI(kind: BroadcastKind, serviceID: Int) async throws -> String? {
        if stationURIs == nil || stationURIs?.keys.contains(where: { $0.hasPrefix("\(kind.rawValue):") }) == false {
            var uris = stationURIs ?? [:]
            for (key, uri) in try await readStations(kind: kind) { uris[key] = uri }
            stationURIs = uris
        }
        return stationURIs?[Self.stationKey(kind: kind, serviceID: serviceID)]
    }

    static func stationKey(kind: BroadcastKind, serviceID: Int) -> String { "\(kind.rawValue):\(serviceID)" }

    private func readStations(kind: BroadcastKind) async throws -> [String: String] {
        var uris: [String: String] = [:]
        var index = 0
        while true {
            let asked: [String: Any] = ["source": kind.braviaSource, "stIdx": index, "cnt": Self.stationsPerPage]
            let result = try await authenticated("avContent", "getContentList", version: "1.0", params: [asked])
            guard let rows = (result as? [Any])?.first as? [Any] else {
                throw BraviaError.unreadable("getContentList")
            }
            for case let row as [String: Any] in rows {
                guard let uri = row["uri"] as? String, let triplet = row["tripletStr"] as? String,
                      let serviceID = Self.serviceID(ofTriplet: triplet) else { continue }
                uris[Self.stationKey(kind: kind, serviceID: serviceID)] = uri
            }
            // 最後のページを過ぎると空のページが返る
            if rows.count < Self.stationsPerPage || index > 1_000 { break }
            index += rows.count
        }
        return uris
    }

    /// `tripletStr`（"ネットワーク ID.TS ID.サービス ID"）のサービス ID
    static func serviceID(ofTriplet triplet: String) -> Int? {
        triplet.split(separator: ".").last.flatMap { Int($0) }
    }

    // MARK: - 通信

    /// クッキーが必要なリクエスト。クッキーが期限切れ（403）なら、PIN なしで取り直して 1 回だけ送り直す
    private func authenticated(_ service: String, _ method: String, version: String, params: [Any]) async throws -> Any {
        for attempt in 0..<2 {
            guard let cookie = store.load()?.cookie else { throw BraviaError.notRegistered }
            let (data, response) = try await send(service, method, version: version, params: params,
                                                  headers: ["Content-Type": "application/json", "Cookie": "auth=\(cookie)"])
            if response.statusCode == 403 {
                if attempt == 0, (try? await actRegister(pin: nil)) == true { continue }
                throw BraviaError.cookieExpired
            }
            return try Self.result(data: data, response: response, method: method)
        }
        throw BraviaError.cookieExpired
    }

    private func call(_ service: String, _ method: String, version: String, params: [Any] = []) async throws -> Any {
        let (data, response) = try await send(service, method, version: version, params: params,
                                              headers: ["Content-Type": "application/json"])
        return try Self.result(data: data, response: response, method: method)
    }

    private func send(_ service: String, _ method: String, version: String, params: [Any],
                      headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let url = Self.url(host: host, service: service) else { throw BraviaError.invalidAddress }
        requestID += 1
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["method": method, "id": requestID, "params": params, "version": version] as [String: Any],
            options: [.sortedKeys]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BraviaError.unreadable(method) }
        return (data, http)
    }

    static func url(host: String, service: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: base), url.host() != nil else { return nil }
        return url.appending(path: "sony/\(service)")
    }

    /// JSON-RPC の結果。テレビはエラーも HTTP 200 の `{"error": [コード, "メッセージ"]}` で返す
    static func result(data: Data, response: HTTPURLResponse, method: String) throws -> Any {
        guard response.statusCode == 200 else { throw BraviaError.http(response.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BraviaError.unreadable(method)
        }
        if let error = object["error"] as? [Any], let code = error.first as? Int {
            throw BraviaError.rpc(code: code, message: error.dropFirst().first as? String ?? "")
        }
        guard let result = object["result"] else { throw BraviaError.unreadable(method) }
        return result
    }
}

// MARK: - 送る内容・受け取る内容

/// 録画予約として送る内容（テレビ側の書き方: 開始は `+0900`、長さは秒の数、イベント ID は10進の文字列）
struct BraviaReservation: Sendable, Equatable {
    var uri: String
    var title: String
    var startDateTime: String
    var durationSec: Int
    var eventID: String

    init(program: Program, event: BroadcastEvent, uri: String) {
        self.uri = uri
        title = program.title
        startDateTime = Self.dateString(program.startDate)
        durationSec = Int(program.duration.rounded())
        eventID = String(event.eventID)
    }

    /// `recording.getConflictScheduleList` 1.0 に送る 5 項目
    var conflictQuery: [String: Any] {
        ["uri": uri, "title": title, "startDateTime": startDateTime, "durationSec": durationSec, "repeatType": "1"]
    }

    /// `recording.addSchedule` 1.1 に送る 7 項目（1 回だけの録画）
    var creation: [String: Any] {
        conflictQuery.merging(["type": "recording", "eventId": eventID]) { $1 }
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = BroadcastDay.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}

/// テレビの予約一覧の 1 行
struct BraviaSchedule: Identifiable, Hashable, Sendable {
    var id: String
    var type: String
    var uri: String
    var startDateTime: String
    var durationSec: Int
    var title: String
    var channelName: String
    var overlapStatus: String?
    var recordingStatus: String?
    var eventID: String?

    init?(_ fields: [String: Any]) {
        guard let id = fields["id"] as? String, let type = fields["type"] as? String,
              let uri = fields["uri"] as? String, let start = fields["startDateTime"] as? String,
              let duration = fields["durationSec"] as? Int else { return nil }
        self.id = id
        self.type = type
        self.uri = uri
        startDateTime = start
        durationSec = duration
        title = fields["title"] as? String ?? ""
        channelName = fields["channelName"] as? String ?? ""
        overlapStatus = fields["overlapStatus"] as? String
        recordingStatus = fields["recordingStatus"] as? String
        eventID = fields["eventId"] as? String
    }

    var startDate: Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: startDateTime) { return date }
        // "+0900"（コロンなし）
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: startDateTime)
    }

    var isRecording: Bool { type == "recording" }
    /// ほかの予約と時間が重なって、録画できない・一部しか録画できない
    var isOverlapped: Bool { overlapStatus.map { $0 != "notOverlapped" } == true }

    /// 削除するときに送る内容（一覧で読んだとおりに返す）
    var deletion: [String: Any] {
        ["id": id, "startDateTime": startDateTime, "title": title, "durationSec": durationSec, "type": type, "uri": uri]
    }

    /// この予約が番組と同じものか（イベント ID と開始時刻で見る）
    func matches(_ program: Program) -> Bool {
        guard let event = program.broadcastEvent, eventID == String(event.eventID), let startDate else { return false }
        return abs(startDate.timeIntervalSince(program.startDate)) < 60
    }
}

enum BraviaError: LocalizedError, Equatable {
    case invalidAddress
    case notRegistered
    case wrongPIN
    case cookieExpired
    case http(Int)
    case rpc(code: Int, message: String)
    case unreadable(String)
    case stationNotFound
    case noBroadcastEvent

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "テレビの IP アドレスが正しくありません。設定画面で確認してください。"
        case .notRegistered:
            "テレビに登録されていません。設定画面の「テレビに登録する」から登録してください。"
        case .wrongPIN:
            "PIN が違います。テレビに表示された 4 桁の数字を入力してください。"
        case .cookieExpired:
            "テレビへの登録が切れました。設定画面から登録し直してください。"
        case .http(404):
            "このテレビは録画予約の操作に対応していないようです（HTTP 404）。"
        case .http(let status):
            "テレビとの通信に失敗しました（HTTP \(status)）。"
        case .rpc(41222, _):
            "この番組はすでに予約されています。"
        case .rpc(7, _):
            "このチャンネルでは予約できません（受信できない局・未契約の局など）。"
        case .rpc(41200, _):
            "その予約はテレビにありません（すでに削除されています）。"
        case .rpc(12, _), .rpc(14, _), .rpc(15, _):
            "このテレビは録画予約の操作に対応していないようです。"
        case .rpc(let code, let message):
            "テレビがエラーを返しました（コード \(code)\(message.isEmpty ? "" : "：\(message)")）。"
        case .unreadable(let method):
            "テレビの応答を読み取れませんでした（\(method)）。"
        case .stationNotFound:
            "テレビのチャンネル一覧にこの局が見つかりません。テレビで受信できる局か確認してください。"
        case .noBroadcastEvent:
            "この番組は、番組表の取得元が予約に必要な情報を提供していないため予約できません。"
        }
    }
}

// MARK: - 登録情報の保存

struct BraviaCredentials: Codable, Equatable, Sendable {
    var clientID: String
    /// `auth` クッキーの値。パスワードと同じ扱いで、キーチェーンに保存する
    var cookie: String?
}

protocol BraviaCredentialStore: Sendable {
    func load() -> BraviaCredentials?
    func save(_ credentials: BraviaCredentials)
    func remove()
}

/// キーチェーンに保存する
struct KeychainCredentialStore: BraviaCredentialStore {
    var service = "TVGuide.bravia"
    var account = "default"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> BraviaCredentials? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(BraviaCredentials.self, from: data)
    }

    func save(_ credentials: BraviaCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}

/// メモリに保存する（テスト用）
final class MemoryCredentialStore: BraviaCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: BraviaCredentials?

    init(_ credentials: BraviaCredentials? = nil) { self.credentials = credentials }

    func load() -> BraviaCredentials? { lock.withLock { credentials } }
    func save(_ credentials: BraviaCredentials) { lock.withLock { self.credentials = credentials } }
    func remove() { lock.withLock { credentials = nil } }
}
