import SwiftUI

/// 現在放送中の番組一覧
struct OnAirView: View {
    @Environment(GuideStore.self) private var store
    @State private var selectedProgram: Program?

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                let items = store.onAirPrograms(at: context.date)
                List(items) { item in
                    Button { selectedProgram = item.program } label: {
                        OnAirRow(channel: item.channel, program: item.program, now: context.date)
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if items.isEmpty && !store.isLoading {
                        ContentUnavailableView(
                            "放送中の番組はありません",
                            systemImage: "tv",
                            description: Text("番組表タブで今日の日付を選択してください")
                        )
                    }
                }
            }
            .navigationTitle("放送中")
            .refreshable { await store.load() }
            .sheet(item: $selectedProgram) { program in
                ProgramDetailView(program: program)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct OnAirRow: View {
    let channel: Channel
    let program: Program
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack {
                Text("\(channel.number)")
                    .font(.title3.bold().monospacedDigit())
                Text(channel.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(program.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(program.startDate.formatted(date: .omitted, time: .shortened))〜\(program.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: program.progress(at: now) ?? 0)
                    .tint(.red)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
