import Foundation
import GRDB

public struct LocalDataUsage: Equatable, Sendable {
    public var totalBytes: Int64
    public var articlesAndMediaBytes: Int64
    public var searchIndexBytes: Int64
    public var localModelBytes: Int64
    public var backupsBytes: Int64
    public var location: URL
    public var isDevelopment: Bool

    public init(totalBytes: Int64 = 0, articlesAndMediaBytes: Int64 = 0, searchIndexBytes: Int64 = 0, localModelBytes: Int64 = 0, backupsBytes: Int64 = 0, location: URL, isDevelopment: Bool) {
        self.totalBytes = totalBytes
        self.articlesAndMediaBytes = articlesAndMediaBytes
        self.searchIndexBytes = searchIndexBytes
        self.localModelBytes = localModelBytes
        self.backupsBytes = backupsBytes
        self.location = location
        self.isDevelopment = isDevelopment
    }
}

public enum DevelopmentDataMigrationResult: Equatable, Sendable {
    case notNeeded
    case migrated(preservedCopy: URL)
}

public enum LocalDataManager {
    public static let deleteOnNextLaunchMarker = ".delete-on-next-launch"
    private static let suppressLegacyMigrationMarker = ".do-not-restore-legacy-data"

    /// Handles only the one known legacy unsigned root. Callers that supply a test or
    /// qualification root never enter this path.
    public static func prepareDevelopmentRoot(
        _ locations: DatabaseLocations,
        legacyRoot: URL = FileManager.default.temporaryDirectory.appending(path: "Crosscurrent-Development", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) throws -> DevelopmentDataMigrationResult {
        let root = locations.container
        let deleteMarker = root.appending(path: deleteOnNextLaunchMarker)
        if fileManager.fileExists(atPath: deleteMarker.path) {
            try fileManager.removeItem(at: root)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appending(path: suppressLegacyMigrationMarker), options: .atomic)
            return .notNeeded
        }

        guard isEmptyOrMissing(root, fileManager: fileManager),
              !fileManager.fileExists(atPath: root.appending(path: suppressLegacyMigrationMarker).path),
              fileManager.fileExists(atPath: DatabaseLocations(container: legacyRoot).canonicalDatabase.path)
        else { return .notNeeded }

        try verifyDatabase(at: DatabaseLocations(container: legacyRoot).canonicalDatabase)
        let parent = root.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appending(path: ".Development-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: stage) }
        try fileManager.copyItem(at: legacyRoot, to: stage)
        try verifyDatabase(at: DatabaseLocations(container: stage).canonicalDatabase)
        if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
        try fileManager.moveItem(at: stage, to: root)
        // The old root remains a recoverable copy until the new root has opened. Keeping it
        // afterward is safer than silently discarding dogfooding evidence.
        return .migrated(preservedCopy: legacyRoot)
    }

    public static func verifyDatabase(at url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let result = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard result == "ok" else { throw CrosscurrentStorageError.integrityFailure(result ?? "unknown") }
    }

    public static func usage(at locations: DatabaseLocations, isDevelopment: Bool, fileManager: FileManager = .default) -> LocalDataUsage {
        let root = locations.container
        return LocalDataUsage(
            totalBytes: directorySize(root, fileManager: fileManager),
            articlesAndMediaBytes: directorySize(locations.blobs, fileManager: fileManager),
            searchIndexBytes: directorySize(locations.derivedSearch, fileManager: fileManager),
            localModelBytes: directorySize(root.appending(path: "Models", directoryHint: .isDirectory), fileManager: fileManager),
            backupsBytes: directorySize(locations.backups, fileManager: fileManager),
            location: root,
            isDevelopment: isDevelopment
        )
    }

    public static func markForDeletionOnNextLaunch(_ locations: DatabaseLocations) throws {
        try locations.prepare()
        try Data().write(to: locations.container.appending(path: deleteOnNextLaunchMarker), options: .atomic)
    }

    public static func clearRebuildableCache(_ locations: DatabaseLocations, fileManager: FileManager = .default) throws {
        let derived = locations.container.appending(path: "Derived", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: derived.path) { try fileManager.removeItem(at: derived) }
        try fileManager.createDirectory(at: locations.derivedSearch, withIntermediateDirectories: true)
    }

    private static func isEmptyOrMissing(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        return (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) ?? false
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
