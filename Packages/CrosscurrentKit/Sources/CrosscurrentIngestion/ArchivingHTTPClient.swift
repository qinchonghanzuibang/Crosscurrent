import CrosscurrentConnectors
import CrosscurrentStorage
import Foundation

/// Persists public connector responses in the rebuildable raw-fetch domain. The repository
/// applies the shared secret-redaction boundary before any metadata reaches SQLite.
public actor ArchivingConnectorHTTPClient: ConnectorHTTPClient {
    private let upstream: any ConnectorHTTPClient
    private let repository: CrosscurrentRepository
    private let blobStore: CanonicalBlobStore
    private let maximumResponseBytes: Int

    public init(upstream: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(), repository: CrosscurrentRepository, blobStore: CanonicalBlobStore, maximumResponseBytes: Int = 20 * 1_024 * 1_024) {
        self.upstream = upstream
        self.repository = repository
        self.blobStore = blobStore
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        let cached = try await repository.latestRawFetchCache(for: url)
        var requestHeaders = headers
        if !requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare("If-None-Match") == .orderedSame }),
           let etag = cached?.responseHeaders.header("ETag") {
            requestHeaders["If-None-Match"] = etag
        }
        if !requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare("If-Modified-Since") == .orderedSame }),
           let modified = cached?.responseHeaders.header("Last-Modified") {
            requestHeaders["If-Modified-Since"] = modified
        }
        let response = try await upstream.get(url, headers: requestHeaders)
        if response.statusCode == 304, let cached {
            let receipt = RawFetchReceipt(
                safeURL: response.finalURL,
                statusCode: 304,
                responseSHA256: cached.blob.sha256,
                blobID: cached.blob.id,
                retentionClass: cached.blob.retentionClass,
                extractionOutcome: "notModified"
            )
            _ = try await repository.saveRawFetch(
                receipt: receipt,
                requestURL: url,
                requestHeaders: requestHeaders,
                responseHeaders: response.headers,
                idempotencyKey: "raw-fetch:304:\(cached.blob.sha256):\(Int(Date.now.timeIntervalSince1970))"
            )
            return ConnectorHTTPResponse(
                data: try await blobStore.data(for: cached.blob),
                statusCode: 200,
                headers: cached.responseHeaders.merging(response.headers) { _, fresh in fresh },
                finalURL: cached.finalURL
            )
        }
        guard response.data.count <= maximumResponseBytes else {
            throw ConnectorError.invalidResponse("response exceeded \(maximumResponseBytes) bytes")
        }
        let mediaType = response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let blob = try await blobStore.put(response.data, mediaType: mediaType, retentionClass: .publicRaw30Days)
        let receipt = RawFetchReceipt(
            safeURL: response.finalURL,
            statusCode: response.statusCode,
            responseSHA256: blob.sha256,
            blobID: blob.id,
            retentionClass: .publicRaw30Days,
            extractionOutcome: "fetched"
        )
        _ = try await repository.saveRawFetch(
            receipt: receipt,
            requestURL: url,
            requestHeaders: requestHeaders,
            responseHeaders: response.headers,
            idempotencyKey: "raw-fetch:\(blob.sha256):\(HTTPMetadataRedactor.digest(Data(url.absoluteString.utf8)))"
        )
        return response
    }
}

private extension Dictionary where Key == String, Value == String {
    func header(_ name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
