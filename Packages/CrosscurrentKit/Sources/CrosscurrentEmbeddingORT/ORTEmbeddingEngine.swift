import CrosscurrentEmbeddingQualification
import CrosscurrentDomain
import CryptoKit
import Darwin
import Foundation
import Hub
import CrosscurrentSearch
import Tokenizers

public actor ORTEmbeddingEngine: QualificationEmbeddingEngine {
    private struct DynamicPointer: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    public enum ExecutionProvider: String, Sendable {
        case cpu
        case coreml
    }

    private typealias LastErrorFunction = @convention(c) () -> UnsafePointer<CChar>?
    private typealias CreateFunction = @convention(c) (
        UnsafePointer<CChar>?, Int32, Int
    ) -> UnsafeMutableRawPointer?
    private typealias DestroyFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias EmbedFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<Int64>?, UnsafePointer<Int64>?,
        Int, Int, UnsafeMutablePointer<Float>?, Int
    ) -> Int32

    public nonisolated let descriptor: QualificationEmbeddingDescriptor
    private let tokenizer: any Tokenizers.Tokenizer
    private let runtimeLibrary: DynamicPointer
    private let shimLibrary: DynamicPointer
    private let lastError: LastErrorFunction
    private let destroy: DestroyFunction
    private let embedFunction: EmbedFunction
    private let handle: DynamicPointer

    public init(modelDirectory: URL, provider: ExecutionProvider) throws {
        tokenizer = try Self.loadTokenizer(from: modelDirectory)
        let runtimeRoot = modelDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        let distribution = runtimeRoot.appending(
            path: "onnxruntime-osx-arm64-1.29.0",
            directoryHint: .isDirectory
        )
        let runtimeURL = distribution.appending(path: "lib/libonnxruntime.1.29.0.dylib")
        let shimURL = runtimeRoot.appending(path: "libcrosscurrent_ort_qualification.dylib")
        runtimeLibrary = DynamicPointer(raw: try Self.openLibrary(runtimeURL, flags: RTLD_NOW | RTLD_GLOBAL))
        shimLibrary = DynamicPointer(raw: try Self.openLibrary(shimURL, flags: RTLD_NOW | RTLD_LOCAL))
        lastError = try Self.symbol("cc_ort_last_error", in: shimLibrary.raw, as: LastErrorFunction.self)
        let create = try Self.symbol("cc_ort_create", in: shimLibrary.raw, as: CreateFunction.self)
        destroy = try Self.symbol("cc_ort_destroy", in: shimLibrary.raw, as: DestroyFunction.self)
        embedFunction = try Self.symbol("cc_ort_embed", in: shimLibrary.raw, as: EmbedFunction.self)
        let modelURL = modelDirectory.appending(path: "model.onnx")
        let created = modelURL.path.withCString {
            create($0, provider == .coreml ? 1 : 0, 384)
        }
        guard let created else {
            let message = lastError().map(String.init(cString:)) ?? "unknown ONNX Runtime error"
            throw EmbeddingQualificationError.invalidVector(message)
        }
        handle = DynamicPointer(raw: created)
        descriptor = QualificationEmbeddingDescriptor(
            candidateID: "multilingual-e5-small-ort-\(provider.rawValue)",
            modelID: "intfloat/multilingual-e5-small",
            modelRevision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
            runtime: provider == .coreml ? "ONNX Runtime Core ML EP" : "ONNX Runtime CPU",
            runtimeVersion: "1.29.0 official macOS arm64 dylib",
            dimensions: 384,
            dtype: .float32,
            maximumTokens: 256,
            pooling: "attention-mask mean pooling",
            normalized: true
        )
    }

    deinit {
        destroy(handle.raw)
        dlclose(shimLibrary.raw)
        dlclose(runtimeLibrary.raw)
    }

    public func tokenIDs(for text: String, role: EmbeddingInputRole) -> [Int] {
        truncated(tokenizer.encode(text: Self.prefixed(text, role: role), addSpecialTokens: true))
    }

    public func embed(_ texts: [String], role: EmbeddingInputRole) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let encoded = texts.map {
            truncated(tokenizer.encode(text: Self.prefixed($0, role: role), addSpecialTokens: true))
        }
        let sequence = max(1, encoded.map(\.count).max() ?? 1)
        var ids = [Int64](repeating: 0, count: texts.count * sequence)
        var mask = [Int64](repeating: 0, count: ids.count)
        for row in encoded.indices {
            for column in encoded[row].indices {
                ids[row * sequence + column] = Int64(encoded[row][column])
                mask[row * sequence + column] = 1
            }
        }
        var output = [Float](repeating: 0, count: texts.count * descriptor.dimensions)
        let outputCount = output.count
        let success = ids.withUnsafeBufferPointer { idBuffer in
            mask.withUnsafeBufferPointer { maskBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    embedFunction(
                        handle.raw, idBuffer.baseAddress, maskBuffer.baseAddress,
                        texts.count, sequence, outputBuffer.baseAddress, outputCount
                    )
                }
            }
        }
        guard success == 1 else {
            let message = lastError().map(String.init(cString:)) ?? "unknown ONNX Runtime error"
            throw EmbeddingQualificationError.invalidVector(message)
        }
        return output.indices.stride(by: descriptor.dimensions).map {
            Array(output[$0..<($0 + descriptor.dimensions)])
        }
    }

    private func truncated(_ ids: [Int]) -> [Int] {
        guard ids.count > descriptor.maximumTokens else { return ids }
        var result = Array(ids.prefix(descriptor.maximumTokens))
        if let eos = tokenizer.eosTokenId { result[result.count - 1] = eos }
        return result
    }

    private nonisolated static func prefixed(_ value: String, role: EmbeddingInputRole) -> String {
        switch role {
        case .query: "query: \(value)"
        case .passage: "passage: \(value)"
        }
    }

    private static func loadTokenizer(from directory: URL) throws -> any Tokenizers.Tokenizer {
        let configData = try Data(contentsOf: directory.appending(path: "tokenizer_config.json"))
        let tokenizerData = try Data(contentsOf: directory.appending(path: "tokenizer.json"))
        guard var rawConfig = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw EmbeddingQualificationError.invalidVector("tokenizer_config.json is not an object")
        }
        if rawConfig["tokenizer_class"] == nil { rawConfig["tokenizer_class"] = "XLMRobertaTokenizer" }
        let config = Config(Dictionary(uniqueKeysWithValues: rawConfig.map { ($0.key as NSString, $0.value) }))
        let tokenizerConfig = try JSONDecoder().decode(Config.self, from: tokenizerData)
        return try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: tokenizerConfig)
    }

    private static func openLibrary(_ url: URL, flags: Int32) throws -> UnsafeMutableRawPointer {
        guard let handle = dlopen(url.path, flags) else {
            let message = String(cString: dlerror())
            throw EmbeddingQualificationError.invalidVector(
                "Could not load \(url.lastPathComponent): \(message)"
            )
        }
        return handle
    }

    private static func symbol<T>(_ name: String, in library: UnsafeMutableRawPointer, as _: T.Type) throws -> T {
        guard let value = dlsym(library, name) else {
            throw EmbeddingQualificationError.invalidVector("Missing qualification shim symbol \(name)")
        }
        return unsafeBitCast(value, to: T.self)
    }
}

/// The evidence-selected development runtime. It remains dynamically described
/// and loads only from a checksum-verified managed asset directory.
public actor SelectedORTEmbeddingRuntime: EmbeddingRuntime {
    private struct InstalledArtifactManifest: Decodable {
        struct Artifact: Decodable {
            var destination: String
            var bytes: Int64
            var sha256: String
        }

        var candidateID: String
        var model: String
        var modelRevision: String
        var license: String
        var artifacts: [Artifact]
    }

    public nonisolated let descriptor = EmbeddingDescriptor(
        runtimeID: "onnxruntime-cpu-1.29.0",
        modelID: "intfloat/multilingual-e5-small",
        modelRevision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        dimension: 384,
        scalarType: .float32,
        pooling: "attention-mask mean pooling",
        normalization: "l2",
        queryPrefix: "query: ",
        documentPrefix: "passage: "
    )

    private let engine: ORTEmbeddingEngine

    public init(verifiedAssetDirectory: URL) throws {
        try Self.validateInstalledAsset(at: verifiedAssetDirectory)
        engine = try ORTEmbeddingEngine(modelDirectory: verifiedAssetDirectory, provider: .cpu)
    }

    public func embed(_ texts: [String], kind: EmbeddingInputKind) async throws -> [[Float]] {
        try await engine.embed(texts, role: kind == .query ? .query : .passage)
    }

    public func resourceEstimate(batchSize: Int) -> EmbeddingResourceEstimate {
        // Evidence from Qualification/embedding-selection.v1.json. This is a
        // scheduling estimate, never a qualification hard gate.
        EmbeddingResourceEstimate(
            peakBytes: 1_541_275_648,
            seconds: max(0.05, Double(max(1, batchSize)) / 25.13)
        )
    }

    private static func validateInstalledAsset(at directory: URL) throws {
        let manifestURL = directory.appending(path: "artifact-manifest.json")
        let manifest = try JSONDecoder().decode(InstalledArtifactManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.candidateID == "multilingual-e5-small-ort-cpu",
              manifest.model == "intfloat/multilingual-e5-small",
              manifest.modelRevision == "614241f622f53c4eeff9890bdc4f31cfecc418b3",
              manifest.license == "MIT",
              !manifest.artifacts.isEmpty
        else {
            throw EmbeddingQualificationError.invalidVector("The installed artifact manifest does not describe the evidence-selected model/runtime pair.")
        }
        let root = directory.standardizedFileURL.path + "/"
        for artifact in manifest.artifacts {
            let url = directory.appending(path: artifact.destination).standardizedFileURL
            guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) else {
                throw EmbeddingQualificationError.invalidVector("Missing managed artifact \(artifact.destination).")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == artifact.bytes,
                  try sha256(url) == artifact.sha256.lowercased()
            else {
                throw EmbeddingQualificationError.invalidVector("Checksum or size mismatch for managed artifact \(artifact.destination).")
            }
        }
        for relativePath in [
            "runtime/onnxruntime-osx-arm64-1.29.0/lib/libonnxruntime.1.29.0.dylib",
            "runtime/libcrosscurrent_ort_qualification.dylib",
        ] where !FileManager.default.fileExists(atPath: directory.appending(path: relativePath).path) {
            throw EmbeddingQualificationError.invalidVector("The verified development artifact is not prepared for local execution: missing \(relativePath).")
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension Collection where Index == Int {
    func stride(by amount: Int) -> StrideTo<Int> {
        Swift.stride(from: startIndex, to: endIndex, by: amount)
    }
}
