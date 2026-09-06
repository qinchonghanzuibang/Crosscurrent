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

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> ConnectorHTTPResponse {
        let host = url.host?.lowercased() ?? url.absoluteString
        try await Self.hostGate.acquire(host)
        defer { Task { await Self.hostGate.release(host) } }
        try Task.checkCancellation()
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
        if (500...599).contains(http.statusCode) {
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

actor HostRequestGate {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }
    private var occupied: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func acquire(_ host: String) async throws {
        try Task.checkCancellation()
        if occupied.insert(host).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[host, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id: id, host: host) }
        }
    }

    private func cancel(id: UUID, host: String) {
        guard let index = waiters[host]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[host]?.remove(at: index) else { return }
        if waiters[host]?.isEmpty == true { waiters[host] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(_ host: String) {
        if var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue.isEmpty ? nil : queue
            next.continuation.resume()
        } else {
            occupied.remove(host)
        }
    }
}
