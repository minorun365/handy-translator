import Foundation
import FoundationModels
import WhisperKit

/// 端末内の言語モデル（Apple Intelligence）。回線が無いときの要約と訳し直しに使う。
struct LocalLanguageModel {
    private let model = SystemLanguageModel.default

    /// 使えないときは理由を返す。使えるなら nil。
    var unavailableReason: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "この端末は Apple Intelligence に対応していません"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence を有効にすると使えます"
            case .modelNotReady: return "端末内のモデルを準備中です"
            @unknown default: return "端末内のモデルを使えません"
            }
        @unknown default:
            return "端末内のモデルを使えません"
        }
    }

    func respond(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: system)
        return try await session.respond(to: user).content
    }

    /// 上限（約4,000トークン）に収まるよう、後ろ側を残して切り詰める。
    func fit(_ text: String, share: Double = 0.55) async -> String {
        let budget = Int(Double(model.contextSize) * share)
        var current = text
        while current.count > 400 {
            if let count = try? await model.tokenCount(for: current), count <= budget { break }
            current = String(current.suffix(current.count * 3 / 4))
        }
        return current
    }
}

/// 端末内の Whisper。確定した発話の音を聞き直して、英語の原文を置き換える。
actor WhisperEngine {
    /// 選べるモデル。大きいほうが正確で、小さいほうが速い。
    static let models: [(name: String, label: String)] = [
        ("large-v3-v20240930_626MB", "large-v3-turbo（正確・約630MB）"),
        ("small.en", "small.en（速い・英語専用）"),
    ]

    private var pipe: WhisperKit?
    private var loadedModel = ""
    private(set) var lastRealtimeFactor: Double = 0

    var isReady: Bool { pipe != nil }

    /// 初回はモデルを取得する。
    func load(model: String) async throws {
        guard pipe == nil || loadedModel != model else { return }
        pipe = nil
        pipe = try await WhisperKit(WhisperKitConfig(model: model))
        loadedModel = model
    }

    func unload() {
        pipe = nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe, samples.count > 8_000 else { return "" }
        let started = Date()
        var options = DecodingOptions()
        options.language = "en"
        options.withoutTimestamps = true
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let seconds = Double(samples.count) / 16_000
        lastRealtimeFactor = Date().timeIntervalSince(started) / max(seconds, 0.1)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
