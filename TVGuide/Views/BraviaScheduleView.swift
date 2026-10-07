import SwiftUI

/// ブラビアの録画予約の一覧
struct BraviaScheduleView: View {
    @Environment(BraviaStore.self) private var bravia
    @State private var deleting: BraviaSchedule?

    var body: some View {
        List {
            if let error = bravia.schedulesError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(bravia.schedules) { schedule in
                ScheduleRow(schedule: schedule)
                    .swipeActions {
                        Button("削除", role: .destructive) { deleting = schedule }
                    }
            }
        }
        .overlay {
            if bravia.schedules.isEmpty && !bravia.isLoadingSchedules && bravia.schedulesError == nil {
                ContentUnavailableView("予約はありません", systemImage: "record.circle",
                                       description: Text("番組の詳細画面の「ブラビアで録画予約」から予約できます"))
            } else if bravia.isLoadingSchedules && bravia.schedules.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("ブラビアの録画予約")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await bravia.loadSchedules() }
        .task { await bravia.loadSchedules() }
        .confirmationDialog("この予約を削除しますか？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { schedule in
            Button("削除", role: .destructive) {
                Task { await bravia.delete(schedule) }
            }
        } message: { schedule in
            Text(schedule.title + (schedule.isRecording ? "" : "（視聴予約）") + "\n毎回録画の予約はまとめて削除されます。")
        }
    }
}

private struct ScheduleRow: View {
    let schedule: BraviaSchedule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: schedule.isRecording ? "record.circle" : "eye")
                    .foregroundStyle(schedule.isRecording ? .red : .secondary)
                Text(schedule.title.isEmpty ? "（番組名なし）" : schedule.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack {
                if let start = schedule.startDate {
                    Text(start.formatted(.dateTime.month().day().weekday(.short).hour().minute()))
                        .monospacedDigit()
                    Text("（\(schedule.durationSec / 60)分）")
                }
                Text(schedule.channelName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if schedule.isOverlapped {
                Label("ほかの予約と重なっています", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
