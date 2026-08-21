import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct SemanticIndexUpdate: Codable, Hashable, Sendable {
    public var descriptor: EmbeddingDescriptor
    public var documentCount: Int
    public var canonicalGeneration: Int64
}

/// Rebuilds a descriptor-specific namespace and flips only the derived active
/// pointer after the complete index has persisted. Canonical revisions are
/// never rewritten and lexical search remains independent.
public actor SemanticIndexCoordinator {
    private struct ActiveNamespace: Codable {
        var descriptor: EmbeddingDescriptor
        var buildID: String
        var generation: Int64
        var switchedAt: Date
    }

    private let repository: CrosscurrentRepository
    private let runtime: any EmbeddingRuntime
    private let rootDirectory: URL
    private let activeManifestURL: URL
    private var index: USearchVectorIndex?

    public init(repository: CrosscurrentRepository, runtime: any EmbeddingRuntime, rootDirectory: URL) {
        self.repository = repository
        self.runtime = runtime
        self.rootDirectory = rootDirectory
        activeManifestURL = rootDirectory.appending(path: "active-vector-namespace.json")
    }

    public func rebuild() async throws -> SemanticIndexUpdate {
        let descriptor = await runtime.descriptor
        let documents = try await repository.searchDocuments(includeHistory: false)
        let current = documents.filter { !$0.isHistorical }
        let keys = current.map { "\($0.kind):\($0.stableID)" }
        let texts = current.map { $0.title + "\n" + String($0.body.prefix(4_000)) }
        let vectors = try await runtime.embed(texts, kind: .document)
        let buildID = UUID().uuidString.lowercased()
        let buildRoot = rootDirectory.appending(path: "namespaces/\(buildID)", directoryHint: .isDirectory)
        let next = try USearchVectorIndex(rootDirectory: buildRoot, descriptor: descriptor)
        try await next.upsert(ids: keys, vectors: vectors)
        try await next.persist()
        let generation = try await repository.generations()[.searchInputs]?.generation ?? 0
        let manifest = ActiveNamespace(descriptor: descriptor, buildID: buildID, generation: generation, switchedAt: .now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: activeManifestURL, options: .atomic)
        index = next
        return SemanticIndexUpdate(descriptor: descriptor, documentCount: current.count, canonicalGeneration: generation)
    }

    public func search(_ text: String, limit: Int = 50) async throws -> [(id: String, score: Double)] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if index == nil { try await loadActiveIndex() }
        guard let index else { return [] }
        let vectors = try await runtime.embed([text], kind: .query)
        guard let vector = vectors.first else { return [] }
        return try await index.search(vector: vector, limit: limit)
    }

    private func loadActiveIndex() async throws {
        guard let data = try? Data(contentsOf: activeManifestURL),
              let active = try? JSONDecoder().decode(ActiveNamespace.self, from: data)
        else { return }
        let runtimeDescriptor = await runtime.descriptor
        guard active.descriptor == runtimeDescriptor else { return }
        let buildRoot = rootDirectory.appending(path: "namespaces/\(active.buildID)", directoryHint: .isDirectory)
        index = try USearchVectorIndex(rootDirectory: buildRoot, descriptor: active.descriptor)
    }
}
