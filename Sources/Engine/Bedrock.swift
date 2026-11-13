import Foundation
import Security

/// Amazon Bedrock の Converse API を、API キーで直接呼ぶ。
struct BedrockClient {
    var region: String
    var modelID: String
    var apiKey: String

    enum Failure: LocalizedError {
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Bedrock \(code): \(body.prefix(160))"
            case .empty: "Bedrock から本文が返りませんでした"
            }
        }
    }

    /// `thinks` を false にすると、モデルの「考える」処理を切って応答時間と出力量を安定させる。
    /// Haiku 5.5 は既定で考えるので、切らないと出力枠を考える側で使い切って本文が空になることがある。
    func converse(system: String, user: String, maxTokens: Int, thinks: Bool) async throws -> String {
        let encodedModel = modelID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? modelID
        guard let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModel)/converse") else {
            throw Failure.empty
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "system": [["text": system]],
            "messages": [["role": "user", "content": [["text": user]]]],
            "inferenceConfig": ["maxTokens": maxTokens],
        ]
        if !thinks {
            body["additionalModelRequestFields"] = ["thinking": ["type": "disabled"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let output = json["output"] as? [String: Any],
            let message = output["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { throw Failure.empty }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }
}

/// API キーの保管先。UserDefaults には置かない。
enum KeyStore {
    private static let service = "com.minoruonda.handytranslator"
    static let bedrock = "bedrock-api-key"
    static let s3 = "s3-credentials"

    static func load(_ account: String = bedrock) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String, account: String = bedrock) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
