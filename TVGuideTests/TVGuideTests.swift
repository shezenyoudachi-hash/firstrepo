import XCTest
@testable import TVGuide

final class BroadcastDayTests: XCTestCase {
    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    func testLateNightBelongsToPreviousDay() {
        let day = BroadcastDay(containing: date("2026-10-07T02:30:00+09:00"))
        XCTAssertEqual(day.start, date("2026-10-06T05:00:00+09:00"))
        XCTAssertEqual(day.end, date("2026-10-07T05:00:00+09:00"))
    }

    func testMorningStartsNewDay() {
        let day = BroadcastDay(containing: date("2026-10-07T05:00:00+09:00"))
        XCTAssertEqual(day.start, date("2026-10-07T05:00:00+09:00"))
        XCTAssertEqual(day.minutes(from: date("2026-10-07T06:30:00+09:00")), 90)
        XCTAssertEqual(day.displayHour(offset: 23), 28)
    }
}

final class GenreTests: XCTestCase {
    func testGenreCode() {
        XCTAssertEqual(Genre(code: "0000"), .news)
        XCTAssertEqual(Genre(code: "0100"), .sports)
        XCTAssertEqual(Genre(code: "0700"), .anime)
        XCTAssertEqual(Genre(code: "0A00"), .hobby)
        XCTAssertEqual(Genre(code: "10"), .hobby)
        XCTAssertEqual(Genre(code: "zz"), .other)
    }
}

final class NHKProgramProviderTests: XCTestCase {
    /// v3 のレスポンス（ラジオ版で確認できている name/description/startDate/endDate と、
    /// テレビ版で入っている可能性のあるジャンル・出演者）
    func testDecodeV3() throws {
        let json = """
        {"e1":{"publication":[
          {"id":"e1-20261007-1","name":"サイエンスZERO","description":"宇宙の謎",
           "startDate":"2026-10-07T21:00:00+09:00","endDate":"2026-10-07T21:30:00+09:00",
           "identifierGroup":{"genre":[{"id":"0800","name1":"ドキュメンタリー／教養"}]},
           "actor":[{"name":"出演者A"},{"name":"出演者B"}]},
          {"name":"","startDate":"2026-10-07T22:00:00+09:00","endDate":"2026-10-07T22:30:00+09:00"}
        ]}}
        """
        let schedule = try NHKProgramProvider.decode(Data(json.utf8))
        XCTAssertEqual(schedule.channels.map(\.name), ["NHK Eテレ"])
        XCTAssertEqual(schedule.programs.count, 1)

        let program = try XCTUnwrap(schedule.programs.first)
        XCTAssertEqual(program.title, "サイエンスZERO")
        XCTAssertEqual(program.description, "宇宙の謎")
        XCTAssertEqual(program.primaryGenre, .documentary)
        XCTAssertEqual(program.cast, "出演者A、出演者B")
        XCTAssertEqual(program.duration, 30 * 60)
    }

    func testDecodeMinimalV3() throws {
        let json = """
        {"g1":{"publication":[{"name":"ニュース","description":"",
          "startDate":"2026-10-07T19:00:00","endDate":"2026-10-07T19:30:00"}]}}
        """
        let schedule = try NHKProgramProvider.decode(Data(json.utf8))
        let program = try XCTUnwrap(schedule.programs.first)
        XCTAssertEqual(schedule.channels.first?.name, "NHK総合")
        // タイムゾーンなしは日本時間
        XCTAssertEqual(program.startDate, ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z"))
        XCTAssertEqual(program.primaryGenre, .other)
    }

    func testUnexpectedResponseIsError() {
        XCTAssertThrowsError(try NHKProgramProvider.decode(Data(#"{"error":"x"}"#.utf8)))
    }
}

final class SampleProgramProviderTests: XCTestCase {
    func testProgramsCoverWholeDayWithoutGaps() async throws {
        let day = BroadcastDay()
        let schedule = try await SampleProgramProvider().fetchSchedule(for: day)
        for channel in schedule.channels {
            let programs = schedule.programs(on: channel)
            XCTAssertEqual(programs.first?.startDate, day.start)
            XCTAssertEqual(programs.last?.endDate, day.end)
            for (a, b) in zip(programs, programs.dropFirst()) {
                XCTAssertEqual(a.endDate, b.startDate)
            }
        }
    }

    func testDeterministic() async throws {
        let day = BroadcastDay()
        let first = try await SampleProgramProvider().fetchSchedule(for: day)
        let second = try await SampleProgramProvider().fetchSchedule(for: day)
        XCTAssertEqual(first.programs, second.programs)
    }
}

@MainActor
final class GuideStoreTests: XCTestCase {
    func testSearchAndOnAir() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = GuideStore(defaults: defaults, provider: SampleProgramProvider())
        await store.load()

        XCTAssertEqual(store.schedule.channels.count, SampleProgramProvider.channels.count)
        XCTAssertTrue(store.search("").isEmpty)
        XCTAssertFalse(store.search("ニュース").isEmpty)
        XCTAssertEqual(store.onAirPrograms(at: store.day.start).count, store.schedule.channels.count)
    }
}

final class MirakurunProgramProviderTests: XCTestCase {
    private let baseURL = URL(string: "http://192.168.1.10:40772")!

    private let services = """
    [
      {"id":3273601024,"serviceId":1024,"networkId":32736,"name":"ＮＨＫ総合１・東京","type":1,
       "remoteControlKeyId":1,"hasLogoData":true,"channel":{"type":"GR","channel":"27"}},
      {"id":3273701032,"serviceId":1032,"networkId":32737,"name":"ＮＨＫＥテレ１東京","type":1,
       "remoteControlKeyId":2,"channel":{"type":"GR","channel":"26"}},
      {"id":3274101064,"serviceId":1064,"networkId":32741,"name":"テレビ朝日","type":1,
       "remoteControlKeyId":5,"channel":{"type":"GR","channel":"24"}},
      {"id":3274101064,"serviceId":1064,"networkId":32741,"name":"テレビ朝日","type":1,
       "remoteControlKeyId":5,"channel":{"type":"GR","channel":"24"}},
      {"id":3274101065,"serviceId":1065,"networkId":32741,"name":"データ","type":192,
       "channel":{"type":"GR","channel":"24"}},
      {"id":400101,"serviceId":101,"networkId":4,"name":"ＮＨＫ ＢＳ","type":1,
       "remoteControlKeyId":1,"channel":{"type":"BS","channel":"BS15_0"}}
    ]
    """

    private let programs = """
    [
      {"id":327410106412345,"eventId":12345,"serviceId":1064,"networkId":32741,
       "startAt":1791374400000,"duration":3600000,"isFree":true,
       "name":"報道ステーション","description":"今日のニュース",
       "genres":[{"lv1":0,"lv2":0,"un1":15,"un2":15}],
       "extended":{"出演者":"アナウンサー","番組内容":"詳しい内容"}},
      {"id":327410106412346,"eventId":12346,"serviceId":1064,"networkId":32741,
       "startAt":1791378000000,"duration":1800000,"isFree":true},
      {"id":40010100001,"eventId":1,"serviceId":101,"networkId":4,
       "startAt":1791374400000,"duration":3600000,"isFree":true,"name":"BS の番組"}
    ]
    """

    func testDecodeTerrestrialOnly() throws {
        let schedule = try MirakurunProgramProvider.decode(
            services: Data(services.utf8), programs: Data(programs.utf8),
            baseURL: baseURL, channelTypes: ["GR"])

        XCTAssertEqual(schedule.channels.map(\.number), [1, 2, 5])
        XCTAssertEqual(schedule.channels.first?.logoURL,
                       URL(string: "http://192.168.1.10:40772/api/services/3273601024/logo"))
        XCTAssertNil(schedule.channels.last?.logoURL)

        // 名前のない番組と、表示対象外（BS）の番組は除かれる
        XCTAssertEqual(schedule.programs.count, 1)
        let program = try XCTUnwrap(schedule.programs.first)
        XCTAssertEqual(program.title, "報道ステーション")
        XCTAssertEqual(program.channelID, schedule.channels.last?.id)
        XCTAssertEqual(program.cast, "アナウンサー")
        XCTAssertTrue(program.description.contains("【番組内容】"))
        XCTAssertEqual(program.primaryGenre, .news)
        XCTAssertEqual(program.duration, 3600)
    }

    func testDecodeWithBS() throws {
        let schedule = try MirakurunProgramProvider.decode(
            services: Data(services.utf8), programs: Data(programs.utf8),
            baseURL: baseURL, channelTypes: ["GR", "BS"])
        XCTAssertEqual(schedule.channels.map(\.number), [1, 2, 5, 101])
        XCTAssertEqual(schedule.programs.count, 2)
    }
}

final class XMLTVProgramProviderTests: XCTestCase {
    func testParse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch4"><display-name>日本テレビ</display-name><display-name>4</display-name>
            <icon src="https://example.com/ntv.png"/></channel>
          <channel id="ch8"><display-name>フジテレビ</display-name></channel>
          <programme start="20261006190000 +0900" stop="20261006200000 +0900" channel="ch4">
            <title lang="ja">クイズ番組</title>
            <sub-title>秋の特番</sub-title>
            <desc>豪華ゲストが登場</desc>
            <category lang="ja">バラエティ</category>
            <credits><presenter>司会者</presenter><actor>ゲストA</actor></credits>
          </programme>
          <programme start="20261006200000 +0900" stop="20261006210000 +0900" channel="unknown">
            <title>不明なチャンネル</title>
          </programme>
        </tv>
        """
        let schedule = try XMLTVProgramProvider.parse(Data(xml.utf8))
        XCTAssertEqual(schedule.channels.map(\.name), ["日本テレビ", "フジテレビ"])
        XCTAssertEqual(schedule.channels.first?.number, 4)
        XCTAssertEqual(schedule.channels.first?.logoURL, URL(string: "https://example.com/ntv.png"))

        XCTAssertEqual(schedule.programs.count, 1)
        let program = try XCTUnwrap(schedule.programs.first)
        XCTAssertEqual(program.title, "クイズ番組")
        XCTAssertEqual(program.subtitle, "秋の特番")
        XCTAssertEqual(program.cast, "司会者、ゲストA")
        XCTAssertEqual(program.primaryGenre, .variety)
        XCTAssertEqual(program.startDate, ISO8601DateFormatter().date(from: "2026-10-06T10:00:00Z"))
    }

    func testParseDateWithoutTimeZoneIsJST() {
        XCTAssertEqual(XMLTVProgramProvider.parseDate("202610060500"),
                       ISO8601DateFormatter().date(from: "2026-10-05T20:00:00Z"))
    }

    func testGenreFromCategoryName() {
        XCTAssertEqual(Genre(categoryName: "アニメ／特撮"), .anime)
        XCTAssertEqual(Genre(categoryName: "Movie"), .movie)
        XCTAssertNil(Genre(categoryName: "???"))
    }
}

@MainActor
final class DataSourceSettingsTests: XCTestCase {
    func testServerURL() {
        XCTAssertEqual(GuideStore.serverURL("192.168.1.10:40772"), URL(string: "http://192.168.1.10:40772"))
        XCTAssertEqual(GuideStore.serverURL("https://tv.example.com"), URL(string: "https://tv.example.com"))
        XCTAssertNil(GuideStore.serverURL(""))
        XCTAssertNil(GuideStore.serverURL("ftp://example.com"))
    }

    func testLegacyNHKKeyMigratesToNHKSource() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("dummy-key", forKey: GuideStore.SettingsKey.apiKey)
        XCTAssertEqual(GuideStore(defaults: defaults).dataSource, .nhk)
    }

    func testInvalidMirakurunURLShowsError() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(DataSource.mirakurun.rawValue, forKey: GuideStore.SettingsKey.dataSource)
        let store = GuideStore(defaults: defaults)
        await store.load()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.schedule.channels.isEmpty)
    }
}
