import CryptoKit
import Foundation

public struct RedactedHTTPMetadata: Codable, Hashable, Sendable {
    public var safeURL: URL
    public var headers: [String: String]

    public init(safeURL: URL, headers: [String: String]) {
        self.safeURL = safeURL
        self.headers = headers
    }
}

public enum HTTPMetadataRedactor {
    private static let secretHeaderFragments = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "api-key", "apikey",
        "access-token", "session", "csrf", "xsrf", "client-secret", "signature"
    ]
    private static let secretQueryFragments = [
        "token", "key", "secret", "signature", "sig", "auth", "session", "code", "credential", "password"
    ]

    public static func redact(url: URL, headers: [String: String], connectorSecretNames: Set<String> = []) -> RedactedHTTPMetadata {
        let connectorNames = Set(connectorSecretNames.map { $0.lowercased() })
        var safeHeaders: [String: String] = [:]
        for (name, value) in headers {
            let normalized = name.lowercased()
            let isSecret = connectorNames.contains(normalized) || secretHeaderFragments.contains { normalized.contains($0) }
            safeHeaders[name] = isSecret ? "<redacted>" : value
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.user = nil
        components?.password = nil
        let originalQueryItems = components?.queryItems
        components?.queryItems = originalQueryItems?.map { item in
            let normalized = item.name.lowercased()
            let isSecret = connectorNames.contains(normalized) || secretQueryFragments.contains { normalized.contains($0) }
            return URLQueryItem(name: item.name, value: isSecret ? "<redacted>" : item.value)
        }
        return RedactedHTTPMetadata(safeURL: components?.url ?? url, headers: safeHeaders)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
