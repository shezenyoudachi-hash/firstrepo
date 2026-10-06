import SwiftUI

/// 縦軸が時刻、横軸がチャンネルの番組表
struct GuideGridView: View {
    @Environment(GuideStore.self) private var store
    var onSelect: (Program) -> Void

    enum Metrics {
        static let pointsPerMinute: CGFloat = 2.4
        static let columnWidth: CGFloat = 128
        static let timeColumnWidth: CGFloat = 28
        static let headerHeight: CGFloat = 44
        static let minutesPerDay: Double = 24 * 60
        static var dayHeight: CGFloat { CGFloat(minutesPerDay) * pointsPerMinute }
    }

    var body: some View {
        let channels = store.schedule.channels
        let width = Metrics.timeColumnWidth + Metrics.columnWidth * CGFloat(channels.count)

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            HStack(alignment: .top, spacing: 0) {
                                TimeRuler(day: store.day)
                                ForEach(channels) { channel in
                                    ChannelColumn(
                                        programs: store.programs(on: channel),
                                        day: store.day,
                                        onSelect: onSelect
                                    )
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                NowIndicator(day: store.day)
                            }
                        } header: {
                            ChannelHeaderRow(channels: channels)
                        }
                    }
                }
                .frame(width: max(width, Metrics.timeColumnWidth))
            }
            .task(id: store.day) {
                scrollToNow(proxy)
            }
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let now = Date.now
        let hour = store.day.contains(now) ? Int(store.day.minutes(from: now) / 60) : 0
        // 固定ヘッダーに隠れないよう 1 時間前から表示する
        proxy.scrollTo(TimeRuler.anchorID(max(hour - 1, 0)), anchor: .top)
    }
}

// MARK: - 時刻列

private struct TimeRuler: View {
    let day: BroadcastDay

    static func anchorID(_ hourOffset: Int) -> String { "hour-\(hourOffset)" }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { offset in
                Text("\(day.displayHour(offset: offset))")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                    .frame(width: GuideGridView.Metrics.timeColumnWidth,
                           height: 60 * GuideGridView.Metrics.pointsPerMinute,
                           alignment: .top)
                    .background(timeColor(day.displayHour(offset: offset) % 24))
                    .overlay(alignment: .top) { Divider() }
                    .id(Self.anchorID(offset))
            }
        }
    }

    /// 朝・昼・夜・深夜で色分け
    private func timeColor(_ hour: Int) -> Color {
        switch hour {
        case 5..<11: Color(red: 0.95, green: 0.55, blue: 0.20)
        case 11..<18: Color(red: 0.30, green: 0.60, blue: 0.85)
        case 18..<23: Color(red: 0.35, green: 0.30, blue: 0.70)
        default: Color(red: 0.20, green: 0.20, blue: 0.35)
        }
    }
}

// MARK: - チャンネルヘッダー

private struct ChannelHeaderRow: View {
    let channels: [Channel]

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: GuideGridView.Metrics.timeColumnWidth)
            ForEach(channels) { channel in
                VStack(spacing: 0) {
                    Text("\(channel.number)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(channel.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: GuideGridView.Metrics.columnWidth,
                       height: GuideGridView.Metrics.headerHeight)
                .overlay(alignment: .trailing) { Divider() }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - チャンネル列

private struct ChannelColumn: View {
    let programs: [Program]
    let day: BroadcastDay
    var onSelect: (Program) -> Void

    @Environment(GuideStore.self) private var store

    var body: some View {
        let ppm = GuideGridView.Metrics.pointsPerMinute
        let limit = GuideGridView.Metrics.minutesPerDay

        ZStack(alignment: .topLeading) {
            ForEach(programs) { program in
                let top = min(max(day.minutes(from: program.startDate), 0), limit)
                let bottom = min(max(day.minutes(from: program.endDate), 0), limit)
                ProgramCell(program: program, hasReminder: store.hasReminder(program))
                    .frame(width: GuideGridView.Metrics.columnWidth,
                           height: max(CGFloat(bottom - top) * ppm, 1))
                    .offset(y: CGFloat(top) * ppm)
                    .onTapGesture { onSelect(program) }
            }
        }
        .frame(width: GuideGridView.Metrics.columnWidth,
               height: GuideGridView.Metrics.dayHeight,
               alignment: .topLeading)
        .background(Color(white: 0.96))
    }
}

private struct ProgramCell: View {
    let program: Program
    let hasReminder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(minuteLabel)
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 2))
                if hasReminder {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(program.title)
                .font(.caption.bold())
            if !program.subtitle.isEmpty {
                Text(program.subtitle)
                    .font(.caption2)
            }
        }
        .foregroundStyle(.black)
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(program.primaryGenre.color)
        .overlay {
            Rectangle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
        }
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(program.startDate.formatted(date: .omitted, time: .shortened)) \(program.title)")
    }

    private var minuteLabel: String {
        String(format: "%02d", BroadcastDay.calendar.component(.minute, from: program.startDate))
    }
}

// MARK: - 現在時刻ライン

private struct NowIndicator: View {
    let day: BroadcastDay

    var body: some View {
        TimelineView(.everyMinute) { context in
            if day.contains(context.date) {
                Rectangle()
                    .fill(.red)
                    .frame(height: 2)
                    .offset(y: CGFloat(day.minutes(from: context.date)) * GuideGridView.Metrics.pointsPerMinute)
            }
        }
        .allowsHitTesting(false)
    }
}

