import Foundation
import Observation

/// BRAVIA への録画予約の状態（設定・登録・予約一覧）
@MainActor
@Observable
final class BraviaStore {
    static let hostKey = "braviaHost"

    enum RegistrationStep: Equatable {
        /// テレビに PIN が表示された。PIN の入力を待つ
        case pinRequested
        case registered
        case failed(String)
    }

    enum ReserveStep: Equatable {
        /// 予約すると録画できなくなる予約がある。確認してから `reserve(_:force:)` を呼ぶ
        case needsConfirmation(conflicts: [String])
        case reserved
        case failed(String)
    }

    private(set) var isRegistered: Bool
    private(set) var schedules: [BraviaSchedule] = []
    private(set) var isLoadingSchedules = false
    var schedulesError: String?

    private let defaults: UserDefaults
    private let credentials: any BraviaCredentialStore
    private let session: URLSession
    @ObservationIgnored private var client: BraviaClient?

    init(defaults: UserDefaults = .standard,
         credentials: any BraviaCredentialStore = KeychainCredentialStore(),
         session: URLSession = BraviaClient.makeSession()) {
        self.defaults = defaults
        self.credentials = credentials
        self.session = session
        self.isRegistered = credentials.load()?.cookie != nil
    }

    var host: String { (defaults.string(forKey: Self.hostKey) ?? "").trimmingCharacters(in: .whitespaces) }

    /// IP アドレスが入っていて登録済み
    var isReady: Bool { !host.isEmpty && isRegistered }

    private func currentClient() throws -> BraviaClient {
        guard BraviaClient.url(host: host, service: "system") != nil else { throw BraviaError.invalidAddress }
        if let client, client.host == host { return client }
        let client = BraviaClient(host: host, store: credentials, session: session)
        self.client = client
        return client
    }

    /// IP アドレスが変わったとき（別のテレビの可能性があるので登録をやり直す）
    func hostDidChange() {
        client = nil
        schedules = []
        if var saved = credentials.load(), saved.cookie != nil {
            saved.cookie = nil
            credentials.save(saved)
        }
        isRegistered = false
    }

    // MARK: - 登録

    func startRegistration() async -> RegistrationStep {
        do {
            let client = try currentClient()
            _ = try await client.powerStatus()
            if try await client.startRegistration() {
                isRegistered = true
                return .registered
            }
            return .pinRequested
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    func register(pin: String) async -> RegistrationStep {
        do {
            try await currentClient().register(pin: pin.trimmingCharacters(in: .whitespaces))
            isRegistered = true
            return .registered
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    func unregister() {
        credentials.remove()
        client = nil
        schedules = []
        isRegistered = false
    }

    // MARK: - 予約

    /// 録画予約する。`force` が false なら、先に録画できなくなる予約がないか確かめる
    func reserve(_ program: Program, force: Bool = false) async -> ReserveStep {
        do {
            let client = try currentClient()
            let reservation = try await client.reservation(for: program)
            if !force {
                let conflicts = try await client.conflicts(for: reservation)
                if !conflicts.isEmpty {
                    return .needsConfirmation(conflicts: conflicts.map(\.title))
                }
            }
            try await client.add(reservation)
            await loadSchedules()
            return .reserved
        } catch {
            refreshRegistration(after: error)
            return .failed(Self.message(for: error))
        }
    }

    func loadSchedules() async {
        guard isReady else { return }
        isLoadingSchedules = true
        defer { isLoadingSchedules = false }
        do {
            schedules = try await currentClient().schedules()
                .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            schedulesError = nil
        } catch {
            refreshRegistration(after: error)
            schedulesError = Self.message(for: error)
        }
    }

    func delete(_ schedule: BraviaSchedule) async {
        do {
            try await currentClient().delete(schedule)
            schedules.removeAll { $0.id == schedule.id }
            await loadSchedules()
        } catch {
            refreshRegistration(after: error)
            schedulesError = Self.message(for: error)
        }
    }

    /// テレビに予約されている番組か（最後に読んだ予約一覧で判断する）
    func isReserved(_ program: Program) -> Bool {
        schedules.contains { $0.isRecording && $0.matches(program) }
    }

    private func refreshRegistration(after error: Error) {
        if let error = error as? BraviaError, error == .cookieExpired || error == .notRegistered {
            isRegistered = credentials.load()?.cookie != nil
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? BraviaError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "テレビに接続できませんでした。テレビの電源が入っているか、iPhone と同じ Wi-Fi につながっているか、IP アドレスが正しいか確認してください。"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
