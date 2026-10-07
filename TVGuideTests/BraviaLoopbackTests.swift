import Network
import XCTest
@testable import TVGuide

/// iPhone の中（127.0.0.1）に立てる、テレビの代わりの小さな HTTP サーバー。
/// URLProtocol のスタブでは URLSession の「401 に自動で送り直す」動きが起きないため、本物の通信で確かめる。
final class LoopbackTV: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackTV")
    private let lock = NSLock()
    private var received: [String] = []
    private let respond: @Sendable (String) -> String

    var requests: [String] { lock.withLock { received } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(respond: @escaping @Sendable (String) -> String) throws {
        self.respond = respond
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// ヘッダーと本文（Content-Length 分）を読み終えたら 1 件の要求として記録して答える
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let lock = self.lock
            let text = String(decoding: buffer, as: UTF8.self)
            if let headerEnd = text.range(of: "\r\n\r\n") {
                let header = text[..<headerEnd.lowerBound]
                let length = header.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let bodyBytes = buffer.count - text[..<headerEnd.upperBound].utf8.count
                if bodyBytes >= length {
                    lock.withLock { self.received.append(text) }
                    let response = self.respond(text)
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }
}

final class BraviaLoopbackTests: XCTestCase {
    /// 未登録の登録要求に 401 + Basic 認証の問い合わせで答えるテレビに、要求が 1 回しか届かないこと。
    /// 2 回届くと、テレビは表示した PIN を取り消す（「登録がキャンセルされました」）
    func testRegistrationRequestIsSentOnlyOnce() async throws {
        let tv = try LoopbackTV { _ in
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"BRAVIA\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        try await tv.start()
        defer { tv.stop() }

        let client = BraviaClient(host: "127.0.0.1:\(tv.port)", store: MemoryCredentialStore())
        let registered = try await client.startRegistration()
        XCTAssertFalse(registered, "PIN を求められたら false")

        // 送り直しが遅れて届く場合に備えて少し待つ
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(tv.requests.count, 1, "登録の要求は 1 回だけ送る")
        XCTAssertTrue(tv.requests.first?.hasPrefix("POST /sony/accessControl") == true)
    }

    /// 正しい PIN で 200 とクッキーが返れば登録できる（本物の通信で）
    func testRegistrationWithPINOverRealHTTP() async throws {
        let tv = try LoopbackTV { request in
            if request.contains("Authorization: Basic " + Data(":1234".utf8).base64EncodedString()) {
                let body = #"{"result":[],"id":1}"#
                return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: auth=REAL; Path=/sony/\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            }
            return "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"BRAVIA\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        try await tv.start()
        defer { tv.stop() }

        let store = MemoryCredentialStore()
        let client = BraviaClient(host: "127.0.0.1:\(tv.port)", store: store)
        let registeredWithoutPIN = try await client.startRegistration()
        XCTAssertFalse(registeredWithoutPIN)
        do {
            try await client.register(pin: "9999")
            XCTFail("違う PIN では登録できない")
        } catch {
            XCTAssertEqual(error as? BraviaError, .wrongPIN)
        }
        try await client.register(pin: "1234")
        XCTAssertEqual(store.load()?.cookie, "REAL")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tv.requests.count, 3, "PIN なし・違う PIN・正しい PIN の 3 回だけ")
    }
}
