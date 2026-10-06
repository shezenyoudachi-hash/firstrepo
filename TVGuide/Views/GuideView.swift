import SwiftUI

/// 番組表タブ：日付選択 + 番組表グリッド
struct GuideView: View {
    @Environment(GuideStore.self) private var store
    @State private var selectedProgram: Program?

    var body: some View {
        NavigationStack {
            GuideGridView(onSelect: { selectedProgram = $0 })
                .overlay {
                    if store.isLoading && store.schedule.programs.isEmpty {
                        ProgressView("読み込み中…")
                    }
                }
                .navigationTitle(store.day.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if store.isUsingSampleData {
                            Text("サンプル")
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
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
