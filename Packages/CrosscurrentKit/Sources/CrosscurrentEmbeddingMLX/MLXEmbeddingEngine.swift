import CrosscurrentEmbeddingQualification
import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

private struct SwiftTransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let configData = try Data(contentsOf: directory.appending(path: "tokenizer_config.json"))
        let tokenizerData = try Data(contentsOf: directory.appending(path: "tokenizer.json"))
        guard var rawConfig = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw EmbeddingQualificationError.invalidVector("tokenizer_config.json is not an object")
        }
        if rawConfig["tokenizer_class"] == nil { rawConfig["tokenizer_class"] = "XLMRobertaTokenizer" }
        let config = Config(Dictionary(uniqueKeysWithValues: rawConfig.map { ($0.key as NSString, $0.value) }))
        let tokenizerConfig = try JSONDecoder().decode(Config.self, from: tokenizerData)
        return SwiftTransformersTokenizerAdapter(base: try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: tokenizerConfig))
    }
}

private struct SwiftTransformersTokenizerAdapter: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        guard tools == nil else { throw MLXLMCommon.TokenizerError.missingChatTemplate }
        return try base.applyChatTemplate(
            messages: messages,
            tools: nil,
            additionalContext: additionalContext
        )
    }
}

public actor MLXEmbeddingEngine: QualificationEmbeddingEngine {
    public nonisolated let descriptor = QualificationEmbeddingDescriptor(
        candidateID: "multilingual-e5-small-mlx",
        modelID: "intfloat/multilingual-e5-small",
        modelRevision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        runtime: "MLXEmbedders",
        runtimeVersion: "mlx-swift-lm-3.31.4 / mlx-swift-0.31.6",
        dimensions: 384,
        dtype: .float32,
        maximumTokens: 256,
        pooling: "attention-mask mean pooling",
        normalized: true
    )

    private let container: EmbedderModelContainer

    public init(modelDirectory: URL) async throws {
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: SwiftTransformersTokenizerLoader()
        )
    }

    public func tokenIDs(for text: String, role: EmbeddingInputRole) async throws -> [Int] {
        await container.perform { context in
            Array(context.tokenizer.encode(text: Self.prefixed(text, role: role), addSpecialTokens: true).prefix(self.descriptor.maximumTokens))
        }
    }

    public func embed(_ texts: [String], role: EmbeddingInputRole) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let maximumTokens = descriptor.maximumTokens
        return await container.perform { context in
            let encoded = texts.map {
                Array(context.tokenizer.encode(text: Self.prefixed($0, role: role), addSpecialTokens: true).prefix(maximumTokens))
            }
            let maxLength = max(1, encoded.map(\.count).max() ?? 1)
            let padded = MLX.stacked(encoded.map { tokens in
                MLXArray(tokens + Array(repeating: 0, count: maxLength - tokens.count))
            })
            let mask = MLX.stacked(encoded.map { tokens in
                MLXArray(Array(repeating: Int32(1), count: tokens.count) + Array(repeating: Int32(0), count: maxLength - tokens.count))
            })
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = context.model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
            let vectors = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: false)
            vectors.eval()
            return vectors.map { $0.asArray(Float.self) }
        }
    }

    private nonisolated static func prefixed(_ value: String, role: EmbeddingInputRole) -> String {
        switch role {
        case .query: "query: \(value)"
        case .passage: "passage: \(value)"
        }
    }
}
