import CryptoKit
import Foundation

/// 自分の S3 へ、記録のファイルを置く。SDK を使わず、署名（SigV4）を自前で付けて PUT する。
/// 鍵は「書き込むだけ」の権限に絞る前提で、読み出しと削除はここに無い。
struct S3Uploader {
    var bucket: String
    var region: String
    var accessKeyID: String
    var secretKey: String

    enum Failure: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            guard case .http(let code, let body) = self else { return "S3 の保存先が未設定です" }
            // 本文は XML で返る。<Code> の中身だけを拾って短く伝える。
            var reason = ""
            if let start = body.range(of: "<Code>"),
               let end = body.range(of: "</Code>", range: start.upperBound..<body.endIndex) {
                reason = String(body[start.upperBound..<end.lowerBound])
            }
            if code == 404 { return "バケットが見つかりません。名前とリージョンを確認してください" }
            if code == 403, reason == "SignatureDoesNotMatch" || reason == "InvalidAccessKeyId" {
                return "鍵が正しくありません。貼り直してください"
            }
            if code == 403 { return "書き込みを拒否されました。鍵の権限とバケット名を確認してください" }
            return "S3 が \(code) を返しました\(reason.isEmpty ? "" : "（\(reason)）")"
        }
    }

    /// 「アクセスキーID:シークレット」の1行を分けて作る。
    init?(bucket: String, region: String, credentials: String) {
        let parts = credentials.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1)
        let name = bucket.trimmingCharacters(in: .whitespaces)
        guard parts.count == 2, !name.isEmpty, !region.isEmpty else { return nil }
        self.bucket = name
        self.region = region.trimmingCharacters(in: .whitespaces)
        self.accessKeyID = String(parts[0])
        self.secretKey = String(parts[1])
    }

    func put(key: String, data: Data, contentType: String, now: Date = Date()) async throws {
        let host = "\(bucket).s3.\(region).amazonaws.com"
        let path = "/" + key.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/")
        guard let url = URL(string: "https://\(host)\(path)") else { throw Failure.notConfigured }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = stamp.string(from: now)
        let day = String(amzDate.prefix(8))

        let payloadHash = Self.hex(SHA256.hash(data: data))
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [
            "PUT", path, "",
            "host:\(host)", "x-amz-content-sha256:\(payloadHash)", "x-amz-date:\(amzDate)", "",
            signedHeaders, payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8))),
        ].joined(separator: "\n")

        var signingKey = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, "s3", "aws4_request"] {
            signingKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: signingKey)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signingKey))

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, String(data: body, encoding: .utf8) ?? "")
        }
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// S3 の署名で決められた文字だけを残して、ほかは %XX にする。
    private static func encode(_ segment: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
