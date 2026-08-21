import CryptoKit
import FeedFlowDomain
import Foundation
import GRDB
import USearch

public enum VectorIndexError: LocalizedError, Equatable {
    case invalidDimension(expected: Int, actual: Int)
    case mismatchedBatch(ids: Int, vectors: Int)
    case invalidDescriptor

    public var errorDescription: String? {
        switch self {
        case let .invalidDimension(expected, actual):
            "Embedding dimension mismatch: expected \(expected), received \(actual)."
        case let .mismatchedBatch(ids, vectors):
            "Vector batch mismatch: \(ids) identifiers and \(vectors) vectors."
        case .invalidDescriptor:
            "The embedding descriptor cannot create a vector namespace."
        }
    }
}

/// A rebuildable vector namespace outside the canonical database and its backup domain.
/// Each embedding descriptor receives its own directory, manifest, key map, and USearch file.
public actor USearchVectorIndex: VectorIndex {
    public nonisolated let descriptor: EmbeddingDescriptor

    public let directory: URL
    private let indexURL: URL
    private let manifestURL: URL
    private let metadata: DatabaseQueue
    private let index: USearchIndex

    public init(rootDirectory: URL, descriptor: EmbeddingDescriptor) throws {
        guard descriptor.dimension > 0 else { throw VectorIndexError.invalidDescriptor }
        self.descriptor = descriptor

        let descriptorData = try JSONEncoder.feedFlowStable.encode(descriptor)
        let namespace = SHA256.hash(data: descriptorData).prefix(12).map { String(format: "%02x", $0) }.joined()
        let directory = rootDirectory.appending(path: namespace, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        indexURL = directory.appending(path: "vectors.usearch")
        manifestURL = directory.appending(path: "descriptor.json")

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        metadata = try DatabaseQueue(path: directory.appending(path: "metadata.sqlite").path, configuration: configuration)
        try metadata.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS vector_keys (stable_id TEXT PRIMARY KEY, numeric_key INTEGER NOT NULL UNIQUE, updated_at REAL NOT NULL) STRICT")
        }

        let quantization: USearchScalar = descriptor.scalarType == .float16 ? .f16 : .f32
        index = try USearchIndex.make(metric: .cos, dimensions: UInt32(descriptor.dimension), connectivity: 16, quantization: quantization)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try index.load(path: indexURL.path)
        }
        try descriptorData.write(to: manifestURL, options: .atomic)
    }

    public func upsert(ids: [String], vectors: [[Float]]) throws {
        guard ids.count == vectors.count else { throw VectorIndexError.mismatchedBatch(ids: ids.count, vectors: vectors.count) }
        guard !ids.isEmpty else { return }
        for vector in vectors where vector.count != descriptor.dimension {
            throw VectorIndexError.invalidDimension(expected: descriptor.dimension, actual: vector.count)
        }

        let existingCount = try metadata.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vector_keys") ?? 0 }
        try index.reserve(UInt32(existingCount + ids.count))

        for (stableID, vector) in zip(ids, vectors) {
            let key = try numericKey(for: stableID)
            if try index.contains(key: key) { _ = try index.remove(key: key) }
            try index.add(key: key, vector: vector)
        }
    }

    public func search(vector: [Float], limit: Int) throws -> [(id: String, score: Double)] {
        guard vector.count == descriptor.dimension else {
            throw VectorIndexError.invalidDimension(expected: descriptor.dimension, actual: vector.count)
        }
        let boundedLimit = max(1, min(limit, 500))
        let (keys, distances) = try index.search(vector: vector, count: boundedLimit)
        guard !keys.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let keyToID: [UInt64: String] = try metadata.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT stable_id, numeric_key FROM vector_keys WHERE numeric_key IN (\(placeholders))", arguments: StatementArguments(keys.map { Int64(bitPattern: $0) }))
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let signed: Int64 = row["numeric_key"]
                return (UInt64(bitPattern: signed), row["stable_id"] as String)
            })
        }
        return zip(keys, distances).compactMap { key, distance in
            keyToID[key].map { ($0, max(-1, min(1, 1 - Double(distance)))) }
        }
    }

    public func persist() throws {
        let temporary = directory.appending(path: "vectors-\(UUID().uuidString.lowercased()).tmp")
        try index.save(path: temporary.path)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: indexURL)
        }
    }

    public func removeAllDerivedFiles() throws {
        try index.clear()
        try metadata.write { db in try db.execute(sql: "DELETE FROM vector_keys") }
        if FileManager.default.fileExists(atPath: indexURL.path) { try FileManager.default.removeItem(at: indexURL) }
    }

    private func numericKey(for stableID: String) throws -> UInt64 {
        if let signed = try metadata.read({ db in
            try Int64.fetchOne(db, sql: "SELECT numeric_key FROM vector_keys WHERE stable_id=?", arguments: [stableID])
        }) {
            return UInt64(bitPattern: signed)
        }

        let digest = SHA256.hash(data: Data(stableID.utf8))
        let initial = digest.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        var candidate = initial == 0 ? 1 : initial
        while true {
            let collision: String? = try metadata.read { db in
                try String.fetchOne(db, sql: "SELECT stable_id FROM vector_keys WHERE numeric_key=?", arguments: [Int64(bitPattern: candidate)])
            }
            if collision == nil || collision == stableID { break }
            candidate &+= 1
            if candidate == 0 { candidate = 1 }
        }
        try metadata.write { db in
            try db.execute(sql: "INSERT INTO vector_keys (stable_id, numeric_key, updated_at) VALUES (?, ?, ?)", arguments: [stableID, Int64(bitPattern: candidate), Date.now.timeIntervalSince1970])
        }
        return candidate
    }
}

private extension JSONEncoder {
    static var feedFlowStable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
