import Foundation

/// 字幕の1文。英語の原文と日本語訳を持ち、あとから良い訳で上書きされる。
struct CaptionLine: Identifiable, Codable, Equatable {
    enum Stage: String, Codable {
        case fast      // 端末内の即時訳
        case cloud     // クラウドで訳し直した
        case local     // 端末内のモデルで訳し直した
    }

    let id: UUID
    var english: String
    var japanese: String
    var stage: Stage
    var heardAgain: Bool   // Whisper で聞き直したか
    let at: Date
    var audioStart: Double?
    var audioEnd: Double?
}

/// 要約1件。直近5分の表示と、5分ごとに積む履歴の両方で使う。
struct SummaryCard: Identifiable, Codable, Equatable {
    let id: UUID
    let at: Date
    var overview: String
    var points: [String]

    var isEmpty: Bool { overview.isEmpty && points.isEmpty }
}

/// 訳し直しと要約をどこで行うか。
enum Engine: String, Codable {
    case cloud   // Bedrock
    case local   // 端末内のモデル
    case none    // 即時訳のみ

    var label: String {
        switch self {
        case .cloud: "高品質"
        case .local: "端末内のみ"
        case .none: "即時訳のみ"
        }
    }
}

/// 1分ごとの電池と熱の記録。
struct MetricSample: Codable {
    let minute: Int
    let battery: Double      // 0〜1。取得できないときは -1
    let thermal: String
    let charging: Bool
}

struct SessionRecord: Codable {
    var startedAt: Date
    var endedAt: Date?
    var lines: [CaptionLine]
    var cards: [SummaryCard]
    var metrics: [MetricSample]
    var settings: [String: String]
    var timings: [String: Double]
    var problems: [String]?
}

enum Vocabulary {
    /// 聞き違えやすい語。訳し直しのときに渡す。
    static let defaults = """
    AWS, Amazon Bedrock, AgentCore, Strands Agents, Amazon Nova, Amazon Q, Kiro, SageMaker, \
    Lambda, S3, S3 Vectors, DynamoDB, Aurora, EC2, EKS, ECS, Fargate, CloudWatch, IAM, \
    Step Functions, EventBridge, API Gateway, CloudFront, Cognito, Graviton, Trainium, \
    Anthropic, Claude, MCP, A2A, re:Invent, Matt Garman, Werner Vogels, Swami Sivasubramanian
    """
}
