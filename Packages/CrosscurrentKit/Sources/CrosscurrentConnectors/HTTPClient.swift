import Foundation

public struct ConnectorHTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    public var finalURL: URL

    public init(data: Data, statusCode: Int, headers: [String: String], finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }
}

public protocol ConnectorHTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse
}

public struct URLSessionConnectorHTTPClient: ConnectorHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> ConnectorHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Crosscurrent/1 (+https://github.com/chonghanqin/Crosscurrent)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw ConnectorError.invalidResponse("not an HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw ConnectorError.authenticationRequired }
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ConnectorError.rateLimited(retryAfter: retry)
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            throw ConnectorError.invalidResponse("HTTP \(http.statusCode)")
        }
        let responseHeaders = http.allHeaderFields.reduce(into: [String: String]()) { output, pair in
            output[String(describing: pair.key)] = String(describing: pair.value)
        }
        return ConnectorHTTPResponse(data: data, statusCode: http.statusCode, headers: responseHeaders, finalURL: finalURL)
    }
}
