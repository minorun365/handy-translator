import Foundation

/// 一覧の1行。記録の本体は開いたときに読む。
struct SessionEntry: Identifiable, Equatable {
    let id: String          // ファイル名（拡張子なし）。例：2026-12-01_0930
    let startedAt: Date
    let endedAt: Date?
    let title: String
    let lineCount: Int
    var uploaded: Bool

    var minutes: Int {
        guard let endedAt else { return 0 }
        return max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
    }
}

/// 聞き取りの記録を端末の書類フォルダに置き、一覧・読み出し・削除を受け持つ。
enum SessionStore {
    private static let uploadedKey = "uploadedSessions"

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func name(for startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: startedAt)
    }

    @discardableResult
    static func save(_ record: SessionRecord) -> String? {
        let name = name(for: record.startedAt)
        let url = folder.appendingPathComponent("\(name).json")
        guard let data = try? encoder.encode(record), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        setUploaded(name, false)
        return name
    }

    static func load(_ name: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")) else { return nil }
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).json"))
        setUploaded(name, false)
    }

    /// 新しい順の一覧。
    static func list() -> [SessionEntry] {
        let uploaded = Set(UserDefaults.standard.stringArray(forKey: uploadedKey) ?? [])
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionEntry? in
                let name = url.deletingPathExtension().lastPathComponent
                guard let record = load(name) else { return nil }
                return SessionEntry(
                    id: name, startedAt: record.startedAt, endedAt: record.endedAt,
                    title: record.title, lineCount: record.lines.count, uploaded: uploaded.contains(name)
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func setUploaded(_ name: String, _ value: Bool) {
        var names = Set(UserDefaults.standard.stringArray(forKey: uploadedKey) ?? [])
        if value { names.insert(name) } else { names.remove(name) }
        UserDefaults.standard.set(Array(names).sorted(), forKey: uploadedKey)
    }

    /// S3 での置き場所。月ごとのフォルダに分ける。
    static func objectKey(_ name: String, ext: String) -> String {
        "sessions/\(name.prefix(4))/\(name.dropFirst(5).prefix(2))/\(name).\(ext)"
    }
}

extension SessionRecord {
    /// 一覧に出す題。最初の要約があればそれ、無ければ最初の字幕。
    var title: String {
        if let first = cards.last?.overview, !first.isEmpty { return first }
        if let line = lines.first(where: { !$0.japanese.isEmpty }) { return String(line.japanese.prefix(40)) }
        return String((lines.first?.english ?? "").prefix(60))
    }

    /// 人が読む用の Markdown。5分ごとの要約と、日本語・英語の字幕。
    var markdown: String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "ja_JP")
        day.dateFormat = "yyyy-MM-dd（E）HH:mm"
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "ja_JP")
        clock.dateFormat = "HH:mm"
        let second = DateFormatter()
        second.locale = Locale(identifier: "ja_JP")
        second.dateFormat = "HH:mm:ss"

        var out = "# \(title)\n\n"
        out += "- 開始：\(day.string(from: startedAt))\n"
        if let endedAt {
            out += "- 終了：\(clock.string(from: endedAt))（\(max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded())))分）\n"
        }
        out += "- 字幕：\(lines.count)文\n\n"

        if !cards.isEmpty {
            out += "## 要約（5分ごと）\n\n"
            for card in cards.reversed() {
                out += "### \(clock.string(from: card.at))\n\n\(card.overview)\n\n"
                for point in card.points { out += "- \(point)\n" }
                out += "\n"
            }
        }
        out += "## 字幕\n\n"
        for line in lines {
            out += "**\(second.string(from: line.at))** \(line.japanese.isEmpty ? "（訳なし）" : line.japanese)\n\n"
            out += "> \(line.english)\n\n"
        }
        return out
    }
}
