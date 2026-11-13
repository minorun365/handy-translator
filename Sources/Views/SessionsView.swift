import SwiftUI

/// 過去の聞き取りを新しい順に並べる。開くと要約と字幕を読める。
struct SessionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !model.uploadNotice.isEmpty || model.pendingUploads > 0, model.hasS3Key {
                    Section {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("未送信 \(model.pendingUploads)件")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                if !model.uploadNotice.isEmpty {
                                    Text(model.uploadNotice)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.sub)
                                }
                            }
                            Spacer()
                            if model.isUploading {
                                ProgressView()
                            } else {
                                Button("送り直す") { Task { await model.uploadPending() } }
                                    .font(.system(size: 15, weight: .medium))
                            }
                        }
                    }
                }
                Section {
                    ForEach(model.sessions) { entry in
                        NavigationLink(value: entry.id) { SessionRow(entry: entry, showsCloud: model.hasS3Key) }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.delete(model.sessions[index]) }
                    }
                } footer: {
                    if model.sessions.isEmpty {
                        Text("聞き取りを停止すると、ここに記録が並びます")
                    }
                }
            }
            .navigationTitle("過去の記録")
            .navigationDestination(for: String.self) { id in
                if let entry = model.sessions.first(where: { $0.id == id }), let record = model.record(for: entry) {
                    SessionDetailView(entry: entry, record: record, showsEnglish: model.showEnglish)
                }
            }
            .sheetChrome { dismiss() }
        }
        .tint(Theme.ink)
        .preferredColorScheme(.light)
    }
}

private struct SessionRow: View {
    let entry: SessionEntry
    let showsCloud: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.stamp(entry))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.mute)
                Text(entry.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if showsCloud {
                Image(systemName: entry.uploaded ? "checkmark.icloud" : "icloud.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(entry.uploaded ? Theme.mute : Theme.live)
                    .padding(.top, 2)
                    .accessibilityLabel(entry.uploaded ? "送信済み" : "未送信")
            }
        }
        .padding(.vertical, 4)
    }

    static func stamp(_ entry: SessionEntry) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d（E）H:mm"
        return "\(formatter.string(from: entry.startedAt))・\(entry.minutes)分・\(entry.lineCount)文"
    }
}

private struct SessionDetailView: View {
    let entry: SessionEntry
    let record: SessionRecord
    let showsEnglish: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(SessionRow.stamp(entry))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.mute)
                    .padding(.bottom, 14)

                ForEach(record.cards.reversed()) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(card.at, format: .dateTime.hour().minute())
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.mute)
                        Text(card.overview)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(4)
                        ForEach(card.points, id: \.self) { point in
                            Text(point)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.sub)
                                .lineSpacing(4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.bottom, 10)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(record.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.japanese.isEmpty ? line.english : line.japanese)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(5)
                            if showsEnglish, !line.japanese.isEmpty {
                                Text(line.english)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.mute)
                                    .lineSpacing(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, Theme.edge)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: record.markdown) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}
