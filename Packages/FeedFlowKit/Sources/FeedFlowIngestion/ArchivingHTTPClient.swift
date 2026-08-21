import FeedFlowConnectors
import FeedFlowStorage
import Foundation

/// Persists public connector responses in the rebuildable raw-fetch domain. The repository
/// applies the shared secret-redaction boundary before any metadata reaches SQLite.
public actor ArchivingConnectorHTTPClient: ConnectorHTTPClient {
    private let upstream: any ConnectorHTTPClient
    private let repository: FeedFlowRepository
    private let blobStore: CanonicalBlobStore

    public init(upstream: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(), repository: FeedFlowRepository, blobStore: CanonicalBlobStore) {
        self.upstream = upstream
        self.repository = repository
        self.blobStore = blobStore
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        let response = try await upstream.get(url, headers: headers)
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
            requestHeaders: headers,
            responseHeaders: response.headers,
            idempotencyKey: "raw-fetch:\(blob.sha256):\(HTTPMetadataRedactor.digest(Data(url.absoluteString.utf8)))"
        )
        return response
    }
}
