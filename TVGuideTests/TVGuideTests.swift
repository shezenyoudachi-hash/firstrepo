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
    func testDecode() throws {
        let json = """
        {"list":{"e1":[{"id":"2026100612345","event_id":"12345",
          "start_time":"2026-10-06T21:00:00+09:00","end_time":"2026-10-06T21:30:00+09:00",
          "area":{"id":"130","name":"東京"},
          "service":{"id":"e1","name":"ＮＨＫＥテレ１","logo_s":{"url":"https://example.com/e1.png","width":"100","height":"50"}},
          "title":"サイエンスZERO","subtitle":"宇宙の謎","content":"番組内容","act":"出演者","genres":["0800"]}],
          "g1":[{"id":"2026100600001","event_id":"1",
          "start_time":"2026-10-06T19:00:00+09:00","end_time":"2026-10-06T19:30:00+09:00",
          "area":{"id":"130","name":"東京"},"service":{"id":"g1","name":"ＮＨＫ総合１"},
          "title":"ニュース7","subtitle":"","content":"","act":"","genres":["0000"]}]}}
        """
        let schedule = try NHKProgramProvider.decode(Data(json.utf8))
        XCTAssertEqual(schedule.channels.map(\.id), ["g1", "e1"])
        XCTAssertEqual(schedule.programs.count, 2)

        let program = try XCTUnwrap(schedule.programs.first { $0.channelID == "e1" })
        XCTAssertEqual(program.title, "サイエンスZERO")
        XCTAssertEqual(program.primaryGenre, .documentary)
        XCTAssertEqual(program.duration, 30 * 60)
        XCTAssertEqual(schedule.channels.last?.logoURL, URL(string: "https://example.com/e1.png"))
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
