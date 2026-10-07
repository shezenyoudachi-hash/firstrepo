import XCTest
@testable import TVGuide

/// テレビの代わりに応答する URLProtocol
final class StubTV: URLProtocol {
    struct Request {
        let path: String
        let headers: [String: String]
        let json: [String: Any]
        var method: String { json["method"] as? String ?? "" }
        var params: [Any] { json["params"] as? [Any] ?? [] }
    }

    nonisolated(unsafe) static var handler: ((Request) -> (Int, [String: String], Any))?
    nonisolated(unsafe) static var requests: [Request] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTV.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let recorded = Request(path: request.url?.path ?? "", headers: request.allHTTPHeaderFields ?? [:], json: json)
        Self.requests.append(recorded)

        let (status, headers, object) = Self.handler?(recorded) ?? (500, [:], [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// JSON-RPC の応答
private func rpcResult(_ result: [Any], status: Int = 200, headers: [String: String] = [:]) -> (Int, [String: String], Any) {
    (status, headers, ["result": result, "id": 1] as [String: Any])
}

private func rpcError(_ code: Int, _ message: String = "") -> (Int, [String: String], Any) {
    (200, [:], ["error": [code, message] as [Any], "id": 1] as [String: Any])
}

private func httpStatus(_ status: Int) -> (Int, [String: String], Any) {
    (status, [:], [String: Any]())
}

final class BraviaClientTests: XCTestCase {
    override func setUp() {
        StubTV.requests = []
        StubTV.handler = nil
    }

    private func program(start: String = "2026-10-08T21:00:00+09:00", event: BroadcastEvent? = BroadcastEvent(kind: .terrestrial, serviceID: 56336, eventID: 3528)) -> Program {
        let startDate = ISO8601DateFormatter().date(from: start)!
        return Program(id: "p", channelID: "KBC.jp", title: "テレビ千鳥", subtitle: "", description: "", cast: "",
                       startDate: startDate, endDate: startDate.addingTimeInterval(30 * 60), genres: [],
                       broadcastEvent: event)
    }

    func testRegistrationWithPIN() async throws {
        let store = MemoryCredentialStore()
        StubTV.handler = { request in
            XCTAssertEqual(request.path, "/sony/accessControl")
            XCTAssertEqual(request.method, "actRegister")
            if request.headers["Authorization"] == "Basic " + Data(":1234".utf8).base64EncodedString() {
                return rpcResult([], headers: ["Set-Cookie": "auth=COOKIE123; Path=/sony/; Max-Age=1209600"])
            }
            return httpStatus(401)
        }
        let client = BraviaClient(host: "192.168.1.20", store: store, session: StubTV.session())

        let registeredWithoutPIN = try await client.startRegistration()
        XCTAssertFalse(registeredWithoutPIN)
        try await client.register(pin: "1234")
        XCTAssertEqual(store.load()?.cookie, "COOKIE123")

        // 2 回とも同じクライアント ID で登録する
        let ids = StubTV.requests.compactMap { (($0.params.first as? [String: Any])?["clientid"] as? String) }
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertEqual((StubTV.requests[0].params.first as? [String: Any])?["level"] as? String, "private")
    }

    func testWrongPIN() async {
        StubTV.handler = { _ in httpStatus(401) }
        let client = BraviaClient(host: "192.168.1.20", store: MemoryCredentialStore(), session: StubTV.session())
        do {
            try await client.register(pin: "0000")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? BraviaError, .wrongPIN)
        }
    }

    func testReserveSendsEventIDAndStationURI() async throws {
        let store = MemoryCredentialStore(BraviaCredentials(clientID: "c", cookie: "COOKIE"))
        let uri = "tv:isdbt?trip=31874.31874.56336&srvName=KBC"
        StubTV.handler = { request in
            XCTAssertEqual(request.headers["Cookie"], "auth=COOKIE")
            switch request.method {
            case "getContentList":
                let asked = request.params.first as? [String: Any]
                XCTAssertEqual(asked?["source"] as? String, "tv:isdbt")
                let rows: [[String: Any]] = (asked?["stIdx"] as? Int) == 0
                    ? [["uri": uri, "tripletStr": "31874.31874.56336", "title": "KBC"],
                       ["uri": "tv:isdbt?trip=31875.31875.56344", "tripletStr": "31875.31875.56344"]]
                    : []
                return rpcResult([rows])
            case "getConflictScheduleList":
                return rpcResult([[Any]()])
            case "addSchedule":
                return rpcResult([["annotation": 0]])
            default:
                return rpcError(12, "No Such Method")
            }
        }
        let client = BraviaClient(host: "192.168.1.20", store: store, session: StubTV.session())
        let reservation = try await client.reservation(for: program())
        let conflicts = try await client.conflicts(for: reservation)
        XCTAssertTrue(conflicts.isEmpty)
        try await client.add(reservation)

        let add = try XCTUnwrap(StubTV.requests.last)
        XCTAssertEqual(add.path, "/sony/recording")
        XCTAssertEqual(add.json["version"] as? String, "1.1")
        let body = try XCTUnwrap(add.params.first as? [String: Any])
        XCTAssertEqual(body["uri"] as? String, uri)
        XCTAssertEqual(body["eventId"] as? String, "3528")
        XCTAssertEqual(body["startDateTime"] as? String, "2026-10-08T21:00:00+0900")
        XCTAssertEqual(body["durationSec"] as? Int, 1800)
        XCTAssertEqual(body["repeatType"] as? String, "1")
        XCTAssertEqual(body["type"] as? String, "recording")
        XCTAssertEqual(body["title"] as? String, "テレビ千鳥")
        XCTAssertEqual(Set(body.keys).count, 7)

        let conflict = try XCTUnwrap(StubTV.requests.first { $0.method == "getConflictScheduleList" })
        let conflictKeys = Set((conflict.params.first as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(conflictKeys, ["uri", "title", "startDateTime", "durationSec", "repeatType"])
    }

    func testUnknownStationAndMissingEvent() async {
        let store = MemoryCredentialStore(BraviaCredentials(clientID: "c", cookie: "COOKIE"))
        StubTV.handler = { _ in rpcResult([[Any]()]) }
        let client = BraviaClient(host: "192.168.1.20", store: store, session: StubTV.session())
        do {
            _ = try await client.reservation(for: program())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? BraviaError, .stationNotFound)
        }
        do {
            _ = try await client.reservation(for: program(event: nil))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? BraviaError, .noBroadcastEvent)
        }
    }

    func testExpiredCookieIsRenewedOnce() async throws {
        let store = MemoryCredentialStore(BraviaCredentials(clientID: "c", cookie: "OLD"))
        StubTV.handler = { request in
            if request.method == "actRegister" {
                return rpcResult([], headers: ["Set-Cookie": "auth=NEW; Path=/sony/"])
            }
            if request.headers["Cookie"] == "auth=OLD" { return httpStatus(403) }
            let row: [String: Any] = ["id": "1", "type": "recording", "uri": "tv:isdbt?trip=1.1.1",
                                      "startDateTime": "2026-10-08T21:00:00+0900", "durationSec": 1800,
                                      "title": "テレビ千鳥", "channelName": "KBC", "eventId": "3528",
                                      "overlapStatus": "notOverlapped"]
            return rpcResult([[row]])
        }
        let client = BraviaClient(host: "192.168.1.20", store: store, session: StubTV.session())
        let schedules = try await client.schedules()
        XCTAssertEqual(store.load()?.cookie, "NEW")
        XCTAssertEqual(schedules.count, 1)
        XCTAssertTrue(schedules[0].matches(program()))
        XCTAssertFalse(schedules[0].isOverlapped)
    }

    func testErrorMessages() {
        XCTAssertEqual(BraviaError.rpc(code: 41222, message: "").localizedDescription, "この番組はすでに予約されています。")
        XCTAssertEqual(BraviaClient.authCookie("auth=abc; Path=/sony/; Max-Age=100"), "abc")
        XCTAssertNil(BraviaClient.authCookie("other=1"))
        XCTAssertEqual(BraviaClient.serviceID(ofTriplet: "31874.31874.56336"), 56336)
        XCTAssertEqual(BraviaClient.url(host: "192.168.1.20", service: "recording")?.absoluteString,
                       "http://192.168.1.20/sony/recording")
        XCTAssertNil(BraviaClient.url(host: " ", service: "recording"))
    }
}

final class BroadcastEventParsingTests: XCTestCase {
    func testXMLTVBroadcastAttributes() throws {
        let xml = #"""
        <tv><channel id="KBC.jp" broadcast="terrestrial" service-id="56336" network-id="31874">
          <display-name>KBC九州朝日</display-name><display-name>1</display-name></channel>
        <programme start="20261008210000 +0900" stop="20261008213000 +0900" channel="KBC.jp"
          broadcast="terrestrial" service-id="56336" event-id="3528"><title>テレビ千鳥</title>
          <icon src="https://example.com/a.jpg"/></programme>
        <programme start="20261008213000 +0900" stop="20261008220000 +0900" channel="KBC.jp"><title>イベントなし</title></programme>
        </tv>
        """#
        let schedule = try XMLTVProgramProvider.parse(Data(xml.utf8))
        XCTAssertEqual(schedule.channels.first?.number, 1)
        let reservable = try XCTUnwrap(schedule.programs.first { $0.title == "テレビ千鳥" })
        XCTAssertEqual(reservable.broadcastEvent, BroadcastEvent(kind: .terrestrial, serviceID: 56336, eventID: 3528))
        XCTAssertEqual(reservable.imageURL, URL(string: "https://example.com/a.jpg"))
        XCTAssertNil(schedule.programs.first { $0.title == "イベントなし" }?.broadcastEvent)
    }

    func testNHKBroadcastEvent() throws {
        let json = """
        {"g1":{"publication":[{"name":"ニュース","description":"",
          "startDate":"2026-10-07T05:00:00+09:00","endDate":"2026-10-07T06:00:00+09:00",
          "identifierGroup":{"serviceId":"g1","eventId":"27486","sid":"0400","onid":"7fe0"}}]},
         "s1":{"publication":[{"name":"BS","startDate":"2026-10-07T05:00:00+09:00","endDate":"2026-10-07T06:00:00+09:00",
          "identifierGroup":{"eventId":"100","sid":"0065"}}]}}
        """
        let schedule = try NHKProgramProvider.decode(Data(json.utf8))
        XCTAssertEqual(schedule.programs.first { $0.channelID == "g1" }?.broadcastEvent,
                       BroadcastEvent(kind: .terrestrial, serviceID: 1024, eventID: 27486))
        XCTAssertEqual(schedule.programs.first { $0.channelID == "s1" }?.broadcastEvent,
                       BroadcastEvent(kind: .bs, serviceID: 101, eventID: 100))
    }
}
