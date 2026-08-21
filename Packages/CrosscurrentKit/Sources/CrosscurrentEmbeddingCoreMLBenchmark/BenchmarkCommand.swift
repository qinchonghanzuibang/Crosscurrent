import CrosscurrentEmbeddingCoreML
import CrosscurrentEmbeddingQualification
import Foundation

@main
private enum CoreMLEmbeddingBenchmarkCommand {
    static func main() async throws {
        let compute = argument("--compute") == "cpuOnly" ? CoreMLEmbeddingEngine.ComputeConfiguration.cpuOnly : .all
        let candidateID = "minilm-l12-native-coreml-\(compute.rawValue)"
        let inputs = try EmbeddingBenchmarkArguments.parse(defaultCandidateID: candidateID)
        let start = ContinuousClock.now
        let engine = try await CoreMLEmbeddingEngine(modelDirectory: inputs.modelDirectory, compute: compute)
        let cold = milliseconds(start.duration(to: .now))
        let shipping = EmbeddingShippingAssessment(
            tokenizerReferenceParity: "measured by pinned references",
            dylibFrameworkPackaging: "Apple system CoreML framework; no third-party dylib",
            signingNotarization: "system framework is compatible; downloaded model asset remains unsigned release-qualification work",
            modelPackaging: "pinned upstream mlpackage with checksum/license validation during development",
            license: "Apache-2.0",
            maintenance: "native Core ML plus maintained Swift Transformers tokenizer",
            selectableForProduction: false,
            limitations: [
                "The downloaded model asset and complete app archive have not passed Developer ID signing, notarization, Sparkle update, and rollback qualification."
            ]
        )
        _ = try await EmbeddingQualificationRunner.run(engine: engine, coldStartMilliseconds: cold, inputs: inputs, shipping: shipping)
        print(inputs.outputURL.path)
    }

    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) + Double(components.attoseconds) / 1e18) * 1_000
    }
}
