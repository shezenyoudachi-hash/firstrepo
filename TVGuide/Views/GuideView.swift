import SwiftUI

/// 番組表タブ：日付選択 + 番組表グリッド
struct GuideView: View {
    @Environment(GuideStore.self) private var store
    @State private var selectedProgram: Program?
    @State private var nowRequest = 0

    var body: some View {
        NavigationStack {
            GuideGridView(nowRequest: nowRequest, onSelect: { selectedProgram = $0 })
                .overlay {
                    if store.isLoading && store.schedule.programs.isEmpty {
                        ProgressView("読み込み中…")
                    }
                }
                .navigationTitle(store.day.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(store.day.label)
                                .font(.headline)
                            if store.isUsingSampleData {
                                Text("サンプルデータ")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .fixedSize()
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("今") {
                            Task {
                                await store.select(day: BroadcastDay())
                                nowRequest += 1
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        dayMenu
                    }
                }
                .refreshable { await store.load() }
                .sheet(item: $selectedProgram) { program in
                    ProgramDetailView(program: program)
                        .presentationDetents([.medium, .large])
                }
        }
    }

    private var dayMenu: some View {
        Menu {
            ForEach(store.availableDays, id: \.self) { day in
                Button {
                    Task { await store.select(day: day) }
                } label: {
                    if day == store.day {
                        Label(day.label, systemImage: "checkmark")
                    } else {
                        Text(day.label)
                    }
                }
            }
        } label: {
            Label("日付", systemImage: "calendar")
        }
    }
}
