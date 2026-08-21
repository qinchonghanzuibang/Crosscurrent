import CoreML
import CrosscurrentEmbeddingQualification
import Foundation
import Hub
import Tokenizers

public actor CoreMLEmbeddingEngine: QualificationEmbeddingEngine {
    public enum ComputeConfiguration: String, Sendable {
        case all
        case cpuOnly

        var units: MLComputeUnits {
            switch self {
            case .all: .all
            case .cpuOnly: .cpuOnly
            }
        }
    }

    public nonisolated let descriptor: QualificationEmbeddingDescriptor
    private let tokenizer: any Tokenizers.Tokenizer
    private let model: MLModel
    private let inputIDsName: String
    private let attentionMaskName: String
    private let tokenTypeIDsName: String?
    private let outputName: String

    public init(modelDirectory: URL, compute: ComputeConfiguration = .all) async throws {
        tokenizer = try Self.loadTokenizer(from: modelDirectory)
        let packageURL = try Self.modelURL(in: modelDirectory)
        let compiledURL: URL
        if packageURL.pathExtension == "mlmodelc" {
            compiledURL = packageURL
        } else {
            compiledURL = try await MLModel.compileModel(at: packageURL)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = compute.units
        model = try await MLModel.load(contentsOf: compiledURL, configuration: configuration)

        let inputs = model.modelDescription.inputDescriptionsByName
        inputIDsName = try Self.featureName(in: inputs, preferred: ["input_ids", "inputIds"], containing: "input")
        attentionMaskName = try Self.featureName(in: inputs, preferred: ["attention_mask", "attentionMask"], containing: "mask")
        tokenTypeIDsName = Self.optionalFeatureName(in: inputs, preferred: ["token_type_ids", "tokenTypeIds"], containing: "token")
        let outputs = model.modelDescription.outputDescriptionsByName
        outputName = try Self.featureName(in: outputs, preferred: ["last_hidden_state", "sentence_embedding"], containing: "hidden")

        descriptor = QualificationEmbeddingDescriptor(
            candidateID: "minilm-l12-native-coreml-\(compute.rawValue)",
            modelID: "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
            modelRevision: "a39062b9112d981477eb4dcdc8b2e9f1a4b5a883",
            runtime: "native-coreml-\(compute.rawValue)",
            runtimeVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            dimensions: 384,
            dtype: .float32,
            maximumTokens: 128,
            pooling: "attention-mask mean pooling",
            normalized: true
        )
    }

    public func tokenIDs(for text: String, role _: EmbeddingInputRole) -> [Int] {
        truncated(tokenizer.encode(text: text, addSpecialTokens: true))
    }

    public func embed(_ texts: [String], role: EmbeddingInputRole) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(try await embedOne(text, role: role))
        }
        return vectors
    }

    private func embedOne(_ text: String, role: EmbeddingInputRole) async throws -> [Float] {
        let encoded = truncated(tokenizer.encode(text: prefixed(text, role: role), addSpecialTokens: true))
        let sequenceLength = max(1, encoded.count)
        // The pinned upstream Core ML export advertises a flexible sequence
        // dimension but a fixed batch dimension of one. Throughput is therefore
        // measured honestly as repeated single-example predictions.
        let shape = [1 as NSNumber, NSNumber(value: sequenceLength)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        let tokenTypes = tokenTypeIDsName == nil ? nil : try MLMultiArray(shape: shape, dataType: .int32)
        for token in 0..<sequenceLength {
            ids[token] = NSNumber(value: token < encoded.count ? encoded[token] : 0)
            mask[token] = NSNumber(value: token < encoded.count ? 1 : 0)
            tokenTypes?[token] = 0
        }
        var features: [String: MLFeatureValue] = [
            inputIDsName: MLFeatureValue(multiArray: ids),
            attentionMaskName: MLFeatureValue(multiArray: mask),
        ]
        if let tokenTypeIDsName, let tokenTypes { features[tokenTypeIDsName] = MLFeatureValue(multiArray: tokenTypes) }
        let prediction = try predict(MLDictionaryFeatureProvider(dictionary: features))
        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw EmbeddingQualificationError.invalidVector("Core ML output \(outputName) is not an MLMultiArray")
        }
        return try Self.pool(output: output, attentionMask: [encoded.count], dimensions: descriptor.dimensions)[0]
    }

    private func predict(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: provider)
    }

    private func prefixed(_ value: String, role _: EmbeddingInputRole) -> String { value }

    private func truncated(_ ids: [Int]) -> [Int] {
        guard ids.count > descriptor.maximumTokens else { return ids }
        var result = Array(ids.prefix(descriptor.maximumTokens))
        if let eos = tokenizer.eosTokenId { result[result.count - 1] = eos }
        return result
    }

    private static func pool(output: MLMultiArray, attentionMask lengths: [Int], dimensions: Int) throws -> [[Float]] {
        let shape = output.shape.map(\.intValue)
        guard let batch = shape.first, batch == lengths.count else {
            throw EmbeddingQualificationError.invalidVector("unexpected Core ML output shape \(shape)")
        }
        if shape.count == 2, shape[1] == dimensions {
            return (0..<batch).map { row in normalize((0..<dimensions).map { output[[row as NSNumber, $0 as NSNumber]].floatValue }) }
        }
        guard shape.count == 3, shape[2] == dimensions else {
            throw EmbeddingQualificationError.invalidVector("expected [batch, tokens, \(dimensions)], received \(shape)")
        }
        return (0..<batch).map { row in
            let count = max(1, min(lengths[row], shape[1]))
            var vector = [Float](repeating: 0, count: dimensions)
            for token in 0..<count {
                for dimension in 0..<dimensions {
                    vector[dimension] += output[[row as NSNumber, token as NSNumber, dimension as NSNumber]].floatValue
                }
            }
            let divisor = Float(count)
            return normalize(vector.map { $0 / divisor })
        }
    }

    private static func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    private static func modelURL(in directory: URL) throws -> URL {
        if ["mlpackage", "mlmodelc"].contains(directory.pathExtension) { return directory }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        if let compiled = children.first(where: { $0.pathExtension == "mlmodelc" }) { return compiled }
        if let package = children.first(where: { $0.pathExtension == "mlpackage" }) { return package }
        throw EmbeddingQualificationError.missingArgument("model directory containing .mlpackage or .mlmodelc")
    }

    private static func loadTokenizer(from directory: URL) throws -> any Tokenizers.Tokenizer {
        let configData = try Data(contentsOf: directory.appending(path: "tokenizer_config.json"))
        let tokenizerData = try Data(contentsOf: directory.appending(path: "tokenizer.json"))
        guard var rawConfig = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw EmbeddingQualificationError.invalidVector("tokenizer_config.json is not an object")
        }
        // This older pinned model predates tokenizer_class metadata. The overlay
        // is runtime configuration, not a mutation of the checksum-validated
        // artifact; independent token-ID references verify the XLM-R choice.
        if rawConfig["tokenizer_class"] == nil { rawConfig["tokenizer_class"] = "XLMRobertaTokenizer" }
        let config = Config(Dictionary(uniqueKeysWithValues: rawConfig.map { ($0.key as NSString, $0.value) }))
        let tokenizerConfig = try JSONDecoder().decode(Config.self, from: tokenizerData)
        return try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: tokenizerConfig)
    }

    private static func featureName(in descriptions: [String: MLFeatureDescription], preferred: [String], containing fragment: String) throws -> String {
        if let exact = preferred.first(where: { descriptions[$0] != nil }) { return exact }
        if let matching = descriptions.keys.first(where: { $0.localizedCaseInsensitiveContains(fragment) }) { return matching }
        if descriptions.count == 1, let only = descriptions.keys.first { return only }
        throw EmbeddingQualificationError.invalidVector("could not resolve Core ML feature from \(descriptions.keys.sorted())")
    }

    private static func optionalFeatureName(in descriptions: [String: MLFeatureDescription], preferred: [String], containing fragment: String) -> String? {
        preferred.first(where: { descriptions[$0] != nil })
            ?? descriptions.keys.first(where: { $0.localizedCaseInsensitiveContains(fragment) && !$0.localizedCaseInsensitiveContains("input") })
    }
}
