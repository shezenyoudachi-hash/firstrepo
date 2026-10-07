import SwiftUI

/// 番組表に表示するチャンネルを選ぶ
struct ChannelSelectionView: View {
    @Environment(GuideStore.self) private var store
    @State private var query = ""

    private var channels: [Channel] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.schedule.channels }
        return store.schedule.channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(channels) { channel in
                Toggle(isOn: Binding(
                    get: { store.isVisible(channel) },
                    set: { store.setVisible(channel, $0) }
                )) {
                    HStack(spacing: 8) {
                        Text(channel.displayNumber ?? "")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(channel.name)
                    }
                }
            }
        }
        .overlay {
            if store.schedule.channels.isEmpty {
                ContentUnavailableView("チャンネルがありません", systemImage: "tv",
                                       description: Text("番組表を読み込むとチャンネルが表示されます"))
            }
        }
        .navigationTitle("表示するチャンネル")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "チャンネル名")
        .toolbar {
            Menu {
                Button("表示中の一覧をすべてオン") { store.setAllVisible(true, channels: channels) }
                Button("表示中の一覧をすべてオフ") { store.setAllVisible(false, channels: channels) }
            } label: {
                Image(systemName: "checklist")
            }
        }
    }
}
