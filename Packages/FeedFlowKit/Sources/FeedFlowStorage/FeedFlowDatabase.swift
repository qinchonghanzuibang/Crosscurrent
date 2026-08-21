import Darwin
import Foundation
import GRDB

public final class FeedFlowDatabase: @unchecked Sendable {
    public static let requiredSchemaVersion = CanonicalSchema.version

    public let pool: DatabasePool
    public let locations: DatabaseLocations
    public let role: RepositoryRole

    private init(pool: DatabasePool, locations: DatabaseLocations, role: RepositoryRole) {
        self.pool = pool
        self.locations = locations
        self.role = role
    }

    public static func open(at locations: DatabaseLocations, role: RepositoryRole) throws -> FeedFlowDatabase {
        if role == .mainApp {
            try locations.prepare()
        } else if !FileManager.default.fileExists(atPath: locations.canonicalDatabase.path) {
            throw FeedFlowStorageError.databaseNotInitialized
        }

        let lockMode: MigrationFileLock.Mode = role == .mainApp ? .exclusive : .shared
        return try MigrationFileLock.withLock(at: locations.migrationLock, mode: lockMode) {
            let pool = try makePool(path: locations.canonicalDatabase.path)
            let foundVersion = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }

            switch role {
            case .agent:
                guard foundVersion == requiredSchemaVersion else {
                    throw FeedFlowStorageError.incompatibleSchema(found: foundVersion, required: requiredSchemaVersion)
                }
            case .mainApp:
                if foundVersion > 0, foundVersion != requiredSchemaVersion {
                    try createMigrationBackup(pool: pool, locations: locations, fromVersion: foundVersion)
                }
                try CanonicalSchema.migrator().migrate(pool)
                let migratedVersion = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
                guard migratedVersion == requiredSchemaVersion else {
                    throw FeedFlowStorageError.incompatibleSchema(found: migratedVersion, required: requiredSchemaVersion)
                }
                let integrity = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
                guard integrity == "ok" else {
                    throw FeedFlowStorageError.integrityFailure(integrity ?? "unknown")
                }
            }

            return FeedFlowDatabase(pool: pool, locations: locations, role: role)
        }
    }

    /// Coordinates every canonical transaction with main-app-owned schema maintenance.
    /// An Agent that was launched from an older bundle is also stopped here after the main
    /// app promotes a newer schema; checking only once at process launch is insufficient.
    func withCanonicalWriteAccess<T>(_ operation: () throws -> T) throws -> T {
        try MigrationFileLock.withLock(at: locations.migrationLock, mode: .shared) {
            let foundVersion = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
            guard foundVersion == Self.requiredSchemaVersion else {
                throw FeedFlowStorageError.incompatibleSchema(found: foundVersion, required: Self.requiredSchemaVersion)
            }
            return try operation()
        }
    }

    private static func makePool(path: String) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "FeedFlowCanonical"
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 6
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }
        return try DatabasePool(path: path, configuration: configuration)
    }

    private static func createMigrationBackup(pool: DatabasePool, locations: DatabaseLocations, fromVersion: Int) throws {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = locations.backups.appending(path: "FeedFlow-v\(fromVersion)-\(timestamp).sqlite")
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [backup.path])
        }
    }
}

private enum MigrationFileLock {
    enum Mode { case shared, exclusive }

    static func withLock<T>(at url: URL, mode: Mode, operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(.EACCES)
        }
        defer { Darwin.close(descriptor) }
        let operationCode = mode == .exclusive ? LOCK_EX : LOCK_SH
        guard flock(descriptor, operationCode) == 0 else {
            throw POSIXError(.EBUSY)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
