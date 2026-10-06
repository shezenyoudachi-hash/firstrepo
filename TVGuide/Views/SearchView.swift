import SwiftUI

/// 表示中の日付の番組をキーワード検索
struct SearchView: View {
    @Environment(GuideStore.self) private var store
    @State private var query = ""
    @State private var selectedProgram: Program?

    var body: some View {
        NavigationStack {
            let results = store.search(query)
            List(results) { program in
                Button { selectedProgram = program } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(program.title).font(.headline)
                        HStack {
                            Text(program.startDate.formatted(.dateTime.month().day().hour().minute()))
                                .monospacedDigit()
                            Text(store.channel(for: program)?.name ?? "")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("番組を検索", systemImage: "magnifyingglass",
                                           description: Text("\(store.day.label) の番組から、タイトル・出演者などで検索します"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("検索")
            .searchable(text: $query, prompt: "番組名・出演者")
            .sheet(item: $selectedProgram) { program in
                ProgramDetailView(program: program)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}
