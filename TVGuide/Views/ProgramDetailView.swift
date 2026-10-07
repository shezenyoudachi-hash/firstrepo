import SwiftUI

/// 番組の詳細
struct ProgramDetailView: View {
    let program: Program
    @Environment(GuideStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let imageURL = program.imageURL {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.secondary.opacity(0.1)
                                .aspectRatio(16 / 9, contentMode: .fit)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    header
                    if let progress = program.progress() {
                        ProgressView(value: progress) {
                            Text("放送中").font(.caption.bold()).foregroundStyle(.red)
                        }
                    }
                    if !program.description.isEmpty {
                        section("番組内容", text: program.description)
                    }
                    if !program.cast.isEmpty {
                        section("出演", text: program.cast)
                    }
                    reminderButton
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: shareText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let channel = store.channel(for: program) {
                    Text(channel.name)
                        .font(.subheadline.bold())
                }
                Text(timeRange)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(program.title)
                .font(.title2.bold())
            if !program.subtitle.isEmpty {
                Text(program.subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                ForEach(program.genres, id: \.self) { genre in
                    Text(genre.displayName)
                        .font(.caption)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(genre.color, in: Capsule())
                }
            }
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.body)
        }
    }

    @ViewBuilder
    private var reminderButton: some View {
        if program.startDate > .now {
            let isOn = store.hasReminder(program)
            Button {
                Task { await store.toggleReminder(program) }
            } label: {
                Label(isOn ? "通知を解除" : "放送前に通知",
                      systemImage: isOn ? "bell.slash" : "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isOn ? .gray : .orange)
        }
    }

    private var timeRange: String {
        let start = program.startDate.formatted(.dateTime.month().day().weekday(.short).hour().minute())
        let end = program.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start)〜\(end)"
    }

    private var shareText: String {
        "\(program.title) \(timeRange) \(store.channel(for: program)?.name ?? "")"
    }
}
