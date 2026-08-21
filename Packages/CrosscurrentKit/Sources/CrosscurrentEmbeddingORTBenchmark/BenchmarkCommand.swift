import CrosscurrentEmbeddingORT
import CrosscurrentEmbeddingQualification
import Foundation

@main
private enum ORTEmbeddingBenchmarkCommand {
    static func main() async throws {
        let provider: ORTEmbeddingEngine.ExecutionProvider = argument("--provider") == "coreml"
            ? .coreml
            : .cpu
        let candidateID = "multilingual-e5-small-ort-\(provider.rawValue)"
        var inputs = try EmbeddingBenchmarkArguments.parse(defaultCandidateID: candidateID)
        if inputs.runtimeDirectory == nil {
            inputs.runtimeDirectory = inputs.modelDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        }
        let start = ContinuousClock.now
        let engine = try ORTEmbeddingEngine(modelDirectory: inputs.modelDirectory, provider: provider)
        let cold = milliseconds(start.duration(to: .now))
        let shipping = EmbeddingShippingAssessment(
            tokenizerReferenceParity: "measured by pinned references",
            dylibFrameworkPackaging: "official Microsoft arm64 dylib plus a source-built qualification shim; rpaths and app archive embedding remain release work",
            signingNotarization: "upstream dylib signature inspected; Crosscurrent Developer ID/notarization and update validation remain open",
            modelPackaging: "pinned upstream ONNX model/tokenizer and runtime archive with checksum/license validation during development",
            license: "MIT model and runtime; official third-party notices retained in the runtime distribution",
            maintenance: "maintained ONNX Runtime C API behind a small qualification-only C++ ABI shim; no Swift wrapper is assumed",
            selectableForProduction: false,
            limitations: [
                "The official runtime is a thin arm64 dylib, not a SwiftPM package or universal framework.",
                provider == .coreml
                    ? "On this qualification host, Core ML accepted 562 of 623 graph nodes across 38 partitions but emitted repeated unbounded-shape conversion failures; CPU fallback and partition overhead materially worsened measured latency and memory."
                    : "The CPU execution-provider result does not establish Core ML execution-provider behavior.",
                "The complete app archive has not passed Developer ID signing, notarization, Sparkle update, and rollback qualification."
            ]
        )
        _ = try await EmbeddingQualificationRunner.run(
            engine: engine,
            coldStartMilliseconds: cold,
            inputs: inputs,
            shipping: shipping
        )
        print(inputs.outputURL.path)
    }

    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) + Double(components.attoseconds) / 1e18) * 1_000
    }
}
