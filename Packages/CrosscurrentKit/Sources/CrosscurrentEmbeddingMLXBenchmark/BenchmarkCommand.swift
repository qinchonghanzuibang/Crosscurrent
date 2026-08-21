import CrosscurrentEmbeddingMLX
import CrosscurrentEmbeddingQualification
import Foundation

@main
private enum MLXEmbeddingBenchmarkCommand {
    static func main() async throws {
        let inputs = try EmbeddingBenchmarkArguments.parse(defaultCandidateID: "multilingual-e5-small-mlx")
        let start = ContinuousClock.now
        let engine = try await MLXEmbeddingEngine(modelDirectory: inputs.modelDirectory)
        let cold = milliseconds(start.duration(to: .now))
        let shipping = EmbeddingShippingAssessment(
            tokenizerReferenceParity: "measured by pinned references",
            dylibFrameworkPackaging: "SwiftPM static products plus MLX metal library; exact release archive inspection remains required",
            signingNotarization: "unsigned local integration only; Developer ID/notarization gate remains open",
            modelPackaging: "pinned upstream safetensors and tokenizer files with checksum/license validation during development",
            license: "MIT model; MIT runtime; transitive dependency license inventory required for release",
            maintenance: "actively maintained MLX Swift and MLXEmbedders; Crosscurrent owns a small explicit tokenizer adapter",
            selectableForProduction: false,
            limitations: [
                "The Xcode-built Metal resource bundle and complete app archive have not passed Developer ID signing, notarization, Sparkle update, and rollback qualification."
            ]
        )
        _ = try await EmbeddingQualificationRunner.run(engine: engine, coldStartMilliseconds: cold, inputs: inputs, shipping: shipping)
        print(inputs.outputURL.path)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) + Double(components.attoseconds) / 1e18) * 1_000
    }
}
