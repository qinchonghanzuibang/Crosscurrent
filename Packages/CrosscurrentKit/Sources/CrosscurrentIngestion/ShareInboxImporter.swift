import CryptoKit
import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct ShareInboxImportBatch: Codable, Hashable, Sendable {
    public var importedRecords: Int
    public var importedItemRevisions: Int
    public var failures: [String]

    public init(importedRecords: Int = 0, importedItemRevisions: Int = 0, failures: [String] = []) {
        self.importedRecords = importedRecords
        self.importedItemRevisions = importedItemRevisions
        self.failures = failures
    }
}

public actor ShareInboxImporter {
    private let locations: DatabaseLocations
    private let repository: CrosscurrentRepository
    private let web: WebConnector
    private let manager: FileManager
    private let leaseOwner: String

    public init(
        locations: DatabaseLocations,
        repository: CrosscurrentRepository,
        http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        manager: FileManager = .default,
        leaseOwner: String = UUID().uuidString.lowercased()
    ) {
        self.locations = locations
        self.repository = repository
        web = WebConnector(http: http)
        self.manager = manager
        self.leaseOwner = leaseOwner
    }

    public func importAvailable(limit: Int = 20, now: Date = .now) async throws -> ShareInboxImportBatch {
        try manager.createDirectory(at: locations.shareInbox, withIntermediateDirectories: true)
        try recoverExpiredFileLeases(now: now)
        let records = try manager.contentsOfDirectory(
            at: locations.shareInbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var batch = ShareInboxImportBatch()
        for original in records.prefix(max(1, limit)) {
            let claimed = original.appendingPathExtension("lease-\(leaseOwner)")
            do {
                try manager.moveItem(at: original, to: claimed)
            } catch {
                continue // Another canonical writer won the atomic file lease.
            }
            do {
                let record = try JSONDecoder().decode(ShareInboxRecord.self, from: Data(contentsOf: claimed))
                let imported = try await importRecord(record)
                batch.importedRecords += 1
                batch.importedItemRevisions += imported
                try manager.removeItem(at: claimed)
            } catch {
                batch.failures.append("\(original.lastPathComponent): \(error.localizedDescription)")
                if !manager.fileExists(atPath: original.path) {
                    try? manager.moveItem(at: claimed, to: original)
                }
            }
        }
        return batch
    }

    private func importRecord(_ record: ShareInboxRecord) async throws -> Int {
        let canonicalURL = URLNormalizer.canonicalize(record.url)
        let stableKey = canonicalURL.absoluteString
        let sourceID = SourceID(Self.stableUUID("shared-source:\(stableKey)"))
        let revisionID = SourceRevisionID(Self.stableUUID("shared-source-revision:\(record.id.uuidString.lowercased())"))
        let endpointID = SourceEndpointID(Self.stableUUID("shared-endpoint:\(stableKey)"))

        let candidate: ConnectorItemCandidate
        let displayName: String
        let contentPrivacy: ContentPrivacy
        if let selection = record.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            // A selection can come from an authenticated/private page. Capture
            // does not prove the publication boundary, so cloud use remains
            // blocked until the user classifies it.
            contentPrivacy = .unknown
            displayName = record.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? canonicalURL.host
                ?? canonicalURL.absoluteString
            candidate = ConnectorItemCandidate(
                externalID: stableKey,
                canonicalURL: canonicalURL,
                title: displayName,
                publishedAt: record.createdAt,
                summary: selection,
                contentText: selection
            )
        } else {
            contentPrivacy = .public
            let discovered = try await web.discover(input: ConnectorDiscoveryInput(url: canonicalURL), context: ConnectorContext())
            displayName = record.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? discovered.sourceRevision.displayName
            guard let preview = discovered.recentCandidates.first else { throw ConnectorError.invalidResponse("shared page produced no content") }
            candidate = try await web.fetchContent(candidate: preview, context: ConnectorContext())
        }

        let source = LogicalSource(id: sourceID, currentRevisionID: revisionID, kind: .website)
        let sourceRevision = SourceRevision(id: revisionID, sourceID: sourceID, displayName: displayName)
        let endpoint = SourceEndpoint(
            id: endpointID,
            sourceID: sourceID,
            connector: .website,
            externalID: stableKey,
            canonicalURL: canonicalURL,
            accessRequirement: .anonymous,
            contentPrivacy: contentPrivacy
        )
        let discovery = ConnectorDiscoveryResult(
            source: source,
            sourceRevision: sourceRevision,
            endpoints: [endpoint],
            aiClassification: SourceAIClassification(sourceID: sourceID, accessRequirement: .anonymous, contentPrivacy: contentPrivacy, provenance: .user, confidence: contentPrivacy == .unknown ? .unknown : .certain),
            coverageCandidate: SourceCoverageAssertion(sourceID: sourceID, ecosystem: .unknown, provenance: .user, confidence: .unknown),
            recentCandidates: [candidate]
        )
        let service = SourceDiscoveryService(repository: repository)
        return try await service.commit(discovery, idempotencyPrefix: "share:\(record.id.uuidString.lowercased())").importedItems
    }

    private func recoverExpiredFileLeases(now: Date) throws {
        let files = try manager.contentsOfDirectory(
            at: locations.shareInbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for file in files where file.lastPathComponent.contains(".json.lease-") {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values.contentModificationDate, now.timeIntervalSince(modified) > 10 * 60 else { continue }
            let name = file.lastPathComponent.components(separatedBy: ".lease-").first ?? file.deletingPathExtension().lastPathComponent
            let recovered = locations.shareInbox.appending(path: name)
            if !manager.fileExists(atPath: recovered.path) { try? manager.moveItem(at: file, to: recovered) }
        }
    }

    private static func stableUUID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
