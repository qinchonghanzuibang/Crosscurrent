import Foundation
import CrosscurrentDomain
import GRDB

public actor CanonicalBlobStore {
    private let root: URL
    private let repository: CrosscurrentRepository
    private let manager: FileManager

    public init(locations: DatabaseLocations, repository: CrosscurrentRepository, manager: FileManager = .default) {
        self.root = locations.blobs
        self.repository = repository
        self.manager = manager
    }

    public func put(_ data: Data, mediaType: String? = nil, retentionClass: BlobRetentionClass) async throws -> StoredBlob {
        let digest = HTTPMetadataRedactor.digest(data)
        let relativePath = "\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)"
        let destination = root.appending(path: relativePath)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        let blob = StoredBlob(
            id: BlobID(Self.uuid(fromSHA256: digest)),
            sha256: digest,
            relativePath: relativePath,
            byteCount: data.count,
            mediaType: mediaType,
            retentionClass: retentionClass
        )
        _ = try await repository.registerBlob(blob, idempotencyKey: "blob:\(digest)")
        return blob
    }

    private static func uuid(fromSHA256 digest: String) -> UUID {
        let prefix = String(digest.prefix(32))
        let parts = [8, 4, 4, 4, 12]
        var offset = prefix.startIndex
        let formatted = parts.map { length -> String in
            let end = prefix.index(offset, offsetBy: length)
            defer { offset = end }
            return String(prefix[offset..<end])
        }.joined(separator: "-")
        return UUID(uuidString: formatted)!
    }

    public func data(for blob: StoredBlob) throws -> Data {
        let url = root.appending(path: blob.relativePath)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == blob.byteCount, HTTPMetadataRedactor.digest(data) == blob.sha256 else {
            throw CrosscurrentStorageError.invalidStagedData
        }
        return data
    }
}

public struct BlobGarbageCollectionResult: Codable, Hashable, Sendable {
    public var newlyQuarantined: Int
    public var deleted: Int

    public init(newlyQuarantined: Int, deleted: Int) {
        self.newlyQuarantined = newlyQuarantined
        self.deleted = deleted
    }
}

public actor BlobGarbageCollector {
    private let database: CrosscurrentDatabase
    private let manager: FileManager
    private let quarantineDuration: TimeInterval

    public init(database: CrosscurrentDatabase, manager: FileManager = .default, quarantineDuration: TimeInterval = 7 * 24 * 60 * 60) {
        self.database = database
        self.manager = manager
        self.quarantineDuration = quarantineDuration
    }

    public func run(now: Date = .now) throws -> BlobGarbageCollectionResult {
        struct Candidate { var id: String; var relativePath: String; var quarantinedAt: Date? }

        let candidates: [Candidate] = try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, relative_path, quarantined_at FROM blobs b
                WHERE NOT EXISTS (SELECT 1 FROM raw_fetches r WHERE r.blob_id=b.id)
                  AND NOT EXISTS (SELECT 1 FROM item_revisions r WHERE r.sanitized_html_blob_id=b.id OR r.evidence_blob_id=b.id)
                  AND NOT EXISTS (SELECT 1 FROM item_assets a WHERE a.blob_id=b.id)
                """
            )
            return rows.map { row in
                Candidate(
                    id: row["id"],
                    relativePath: row["relative_path"],
                    quarantinedAt: (row["quarantined_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
        }

        var quarantined = 0
        var deleted = 0
        try database.withCanonicalWriteAccess {
            try database.pool.write { db in
                for candidate in candidates {
                    if let date = candidate.quarantinedAt, now.timeIntervalSince(date) >= quarantineDuration {
                        let url = database.locations.blobs.appending(path: candidate.relativePath)
                        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                        try db.execute(sql: "DELETE FROM blobs WHERE id=?", arguments: [candidate.id])
                        deleted += 1
                    } else if candidate.quarantinedAt == nil {
                        try db.execute(sql: "UPDATE blobs SET quarantined_at=? WHERE id=?", arguments: [now.timeIntervalSince1970, candidate.id])
                        quarantined += 1
                    }
                }
            }
        }
        return BlobGarbageCollectionResult(newlyQuarantined: quarantined, deleted: deleted)
    }

    public func purgeImmediately(blobID: BlobID) throws {
        let path: String? = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT relative_path FROM blobs WHERE id=?", arguments: [blobID.description])
        }
        if let path {
            let url = database.locations.blobs.appending(path: path)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try database.withCanonicalWriteAccess {
                try database.pool.write { db in
                    try db.execute(sql: "DELETE FROM blobs WHERE id=?", arguments: [blobID.description])
                }
            }
        }
    }
}
