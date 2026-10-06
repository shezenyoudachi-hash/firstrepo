import Foundation

/// API キーなしでも動作確認できるよう、ダミーの番組表を生成する
struct SampleProgramProvider: ProgramProvider {
    static let channels: [Channel] = [
        Channel(id: "ch1", name: "NHK総合", number: 1),
        Channel(id: "ch2", name: "Eテレ", number: 2),
        Channel(id: "ch4", name: "日テレ", number: 4),
        Channel(id: "ch5", name: "テレ朝", number: 5),
        Channel(id: "ch6", name: "TBS", number: 6),
        Channel(id: "ch7", name: "テレ東", number: 7),
        Channel(id: "ch8", name: "フジ", number: 8),
    ]

    private static let templates: [(title: String, genre: Genre, minutes: [Int])] = [
        ("おはようニュース", .news, [30, 60]),
        ("ニュース・天気予報", .news, [10, 15, 30]),
        ("朝の情報ワイド", .information, [60, 90, 120]),
        ("お昼のバラエティ", .variety, [60, 90]),
        ("連続ドラマ「春の風」", .drama, [15, 60]),
        ("サスペンス劇場", .drama, [60, 120]),
        ("プロ野球中継", .sports, [120, 180]),
        ("サッカー ハイライト", .sports, [30, 60]),
        ("ミュージックステージ", .music, [60, 90]),
        ("金曜ロードショー", .movie, [120]),
        ("アニメ「星の旅人」", .anime, [30]),
        ("こども向けアニメ", .anime, [15, 30]),
        ("世界の絶景ドキュメント", .documentary, [30, 60]),
        ("歴史ヒストリア", .documentary, [45, 60]),
        ("きょうの料理", .hobby, [15, 25]),
        ("英会話レッスン", .hobby, [15, 30]),
        ("深夜のトーク番組", .variety, [30, 60]),
        ("クイズ王決定戦", .variety, [60, 120]),
        ("ステージ中継", .theater, [90, 120]),
        ("みんなの手話", .welfare, [15, 30]),
    ]

    func fetchSchedule(for day: BroadcastDay) async throws -> Schedule {
        var programs: [Program] = []
        let daySeed = UInt64(day.start.timeIntervalSince1970 / 86_400)

        for channel in Self.channels {
            var rng = SeededGenerator(seed: daySeed &* 31 &+ UInt64(channel.number))
            var cursor = day.start
            var index = 0
            while cursor < day.end {
                let template = Self.templates.randomElement(using: &rng)!
                let minutes = template.minutes.randomElement(using: &rng)!
                let end = min(cursor.addingTimeInterval(TimeInterval(minutes * 60)), day.end)
                programs.append(Program(
                    id: "\(channel.id)-\(Int(day.start.timeIntervalSince1970))-\(index)",
                    channelID: channel.id,
                    title: template.title,
                    subtitle: "第\(Int.random(in: 1...20, using: &rng))回",
                    description: "\(template.title)の番組説明です。これはサンプルデータです。設定画面で番組表の取得元を変更すると、実際の番組表が表示されます。",
                    cast: ["山田太郎", "佐藤花子", "鈴木一郎", "田中美咲"].shuffled(using: &rng).prefix(2).joined(separator: "、"),
                    startDate: cursor,
                    endDate: end,
                    genres: [template.genre]
                ))
                cursor = end
                index += 1
            }
        }
        return Schedule(channels: Self.channels, programs: programs)
    }
}

/// 再現性のある乱数（同じ日付なら同じ番組表になる）
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
