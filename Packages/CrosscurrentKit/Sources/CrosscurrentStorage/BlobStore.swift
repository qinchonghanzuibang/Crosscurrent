import Foundation
import CrosscurrentDomain
import GRDB

public actor CanonicalBlobStore {
    private let root: URL
    private let repository: CrosscurrentRepository

    public init(locations: DatabaseLocations, repository: CrosscurrentRepository) {
        self.root = locations.blobs
        self.repository = repository
    }

    public func put(_ data: Data, mediaType: String? = nil, retentionClass: BlobRetentionClass) async throws -> StoredBlob {
        let digest = HTTPMetadataRedactor.digest(data)
        let relativePath = "\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)"
        let blob = StoredBlob(
            id: BlobID(Self.uuid(fromSHA256: digest)),
            sha256: digest,
            relativePath: relativePath,
            byteCount: data.count,
            mediaType: mediaType,
            retentionClass: retentionClass
        )
        try await repository.storeBlob(blob, contents: data)
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
        let result = try database.withCanonicalWriteAccess {
            try database.pool.write { db in
                // Check reachability under the same writer transaction that
                // removes the file; another process cannot attach it in between.
                let candidates = try Row.fetchAll(db, sql: "SELECT id, sha256, relative_path, quarantined_at FROM blobs b WHERE \(Self.unreferencedPredicate)")
                var quarantined = 0, deleted = 0
                for candidate in candidates {
                    let date = (candidate["quarantined_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                    if let date, now.timeIntervalSince(date) >= quarantineDuration {
                        try remove(candidate, db: db)
                        deleted += 1
                    } else if date == nil {
                        try db.execute(sql: "UPDATE blobs SET quarantined_at=? WHERE id=?", arguments: [now.timeIntervalSince1970, candidate["id"] as String])
                        quarantined += 1
                    }
                }
                if quarantined + deleted > 0 { try advanceGeneration(db, at: now) }
                return BlobGarbageCollectionResult(newlyQuarantined: quarantined, deleted: deleted)
            }
        }
        if result.newlyQuarantined + result.deleted > 0 { CrossProcessObservationHub().postWakeHint() }
        return result
    }

    public func purgeImmediately(blobID: BlobID) throws {
        let removed = try database.withCanonicalWriteAccess {
            try database.pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM blobs WHERE id=?", arguments: [blobID.description]) else { return false }
                let unreferenced = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM blobs b WHERE b.id=? AND \(Self.unreferencedPredicate))", arguments: [blobID.description]) ?? false
                guard unreferenced else { throw CrosscurrentStorageError.invalidStagedData }
                try remove(row, db: db)
                try advanceGeneration(db, at: .now)
                return true
            }
        }
        if removed { CrossProcessObservationHub().postWakeHint() }
    }

    private static let unreferencedPredicate = """
        NOT EXISTS (SELECT 1 FROM raw_fetches r WHERE r.blob_id=b.id)
        AND NOT EXISTS (SELECT 1 FROM item_revisions r WHERE r.sanitized_html_blob_id=b.id OR r.evidence_blob_id=b.id)
        AND NOT EXISTS (SELECT 1 FROM item_assets a WHERE a.blob_id=b.id)
        """

    private func remove(_ row: Row, db: Database) throws {
        let url = database.locations.blobs.appending(path: row["relative_path"] as String)
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        try db.execute(sql: "DELETE FROM blobs WHERE id=?", arguments: [row["id"] as String])
        // A content-addressed blob can legitimately be fetched again after GC.
        try db.execute(sql: "DELETE FROM idempotency_commits WHERE idempotency_key=?", arguments: ["blob:" + (row["sha256"] as String)])
    }

    private func advanceGeneration(_ db: Database, at date: Date) throws {
        try db.execute(sql: """
            INSERT INTO database_change_generations (domain, generation, committed_at, writer_instance)
            VALUES ('blobs', 1, ?, 'blob-gc') ON CONFLICT(domain) DO UPDATE SET
              generation=generation+1, committed_at=excluded.committed_at, writer_instance=excluded.writer_instance
            """, arguments: [date.timeIntervalSince1970])
    }
}
