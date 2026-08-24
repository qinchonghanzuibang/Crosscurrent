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
    private static let hostGate = HostRequestGate()
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> ConnectorHTTPResponse {
        let host = url.host?.lowercased() ?? url.absoluteString
        await Self.hostGate.acquire(host)
        defer { Task { await Self.hostGate.release(host) } }
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
            let retry = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw ConnectorError.rateLimited(retryAfter: retry)
        }
        if [502, 503, 504].contains(http.statusCode) {
            throw ConnectorError.transientHTTP(statusCode: http.statusCode, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            throw ConnectorError.invalidResponse("HTTP \(http.statusCode)")
        }
        let responseHeaders = http.allHeaderFields.reduce(into: [String: String]()) { output, pair in
            output[String(describing: pair.key)] = String(describing: pair.value)
        }
        return ConnectorHTTPResponse(data: data, statusCode: http.statusCode, headers: responseHeaders, finalURL: finalURL)
    }

    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        }
        return nil
    }
}

private actor HostRequestGate {
    private var occupied: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ host: String) async {
        if occupied.insert(host).inserted { return }
        await withCheckedContinuation { waiters[host, default: []].append($0) }
    }

    func release(_ host: String) {
        if var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            occupied.remove(host)
        }
    }
}
