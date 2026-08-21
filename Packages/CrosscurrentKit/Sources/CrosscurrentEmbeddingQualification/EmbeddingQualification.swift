import CrosscurrentDomain
import CrosscurrentStorage
import Darwin
import Foundation

public enum EmbeddingInputRole: String, Codable, Sendable {
    case query
    case passage
}

public struct QualificationEmbeddingDescriptor: Codable, Hashable, Sendable {
    public var candidateID: String
    public var modelID: String
    public var modelRevision: String
    public var runtime: String
    public var runtimeVersion: String
    public var dimensions: Int
    public var dtype: EmbeddingDescriptor.ScalarType
    public var maximumTokens: Int
    public var pooling: String
    public var normalized: Bool

    public init(candidateID: String, modelID: String, modelRevision: String, runtime: String, runtimeVersion: String, dimensions: Int, dtype: EmbeddingDescriptor.ScalarType, maximumTokens: Int, pooling: String, normalized: Bool) {
        self.candidateID = candidateID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
        self.dimensions = dimensions
        self.dtype = dtype
        self.maximumTokens = maximumTokens
        self.pooling = pooling
        self.normalized = normalized
    }
}

public protocol QualificationEmbeddingEngine: Sendable {
    var descriptor: QualificationEmbeddingDescriptor { get }
    func tokenIDs(for text: String, role: EmbeddingInputRole) async throws -> [Int]
    func embed(_ texts: [String], role: EmbeddingInputRole) async throws -> [[Float]]
}

public struct TokenizerReference: Codable, Hashable, Sendable {
    public var id: String
    public var candidateIDs: [String]
    public var text: String
    public var role: EmbeddingInputRole
    public var expectedTokenIDs: [Int]
    public var referenceImplementation: String
}

public struct TokenizerParityResult: Codable, Hashable, Sendable {
    public var referenceID: String
    public var expected: [Int]
    public var actual: [Int]
    public var matches: Bool
    public var referenceImplementation: String
}

public struct EmbeddingVectorReference: Codable, Hashable, Sendable {
    public var id: String
    public var candidateIDs: [String]
    public var text: String
    public var role: EmbeddingInputRole
    public var dimensions: Int
    public var float32LittleEndianBase64: String
    public var referenceImplementation: String
}

public struct EmbeddingVectorParityResult: Codable, Hashable, Sendable {
    public var referenceID: String
    public var dimensions: Int
    public var cosineSimilarity: Double
    public var maximumAbsoluteDifference: Double
    public var referenceImplementation: String
}

public struct EmbeddingQualificationEnvironment: Codable, Hashable, Sendable {
    public var hardwareModel: String
    public var processor: String
    public var memoryBytes: UInt64
    public var operatingSystem: String
    public var operatingSystemBuild: String
    public var lowPowerModeEnabled: Bool
    public var thermalState: String
    public var executableBytes: Int64
    public var modelArtifactBytes: Int64
    public var runtimeArtifactBytes: Int64
    public var qualificationLimitation: String?
}

public struct RetrievalJudgmentResult: Codable, Hashable, Sendable {
    public var query: String
    public var expectedHigh: [String]
    public var topTen: [String]
    public var expectedFoundInTopTen: Int
}

public struct PairSimilarityResult: Codable, Hashable, Sendable {
    public var left: String
    public var right: String
    public var expected: String
    public var cosineSimilarity: Double
}

public struct EmbeddingQualificationMetrics: Codable, Hashable, Sendable {
    public var coldStartMilliseconds: Double
    public var warmLatencyMilliseconds: [Double]
    public var p50WarmLatencyMilliseconds: Double
    public var p95WarmLatencyMilliseconds: Double
    public var batchSegmentsPerSecond: Double
    public var peakResidentBytes: UInt64
    public var vectorIndexProjectedBytes: Int64
    public var retrieval: [RetrievalJudgmentResult]
    public var pairSimilarities: [PairSimilarityResult]
    public var positiveDuplicatePairs: Int
    public var crossLanguagePositivePairs: Int
}

public struct EmbeddingShippingAssessment: Codable, Hashable, Sendable {
    public var tokenizerReferenceParity: String
    public var dylibFrameworkPackaging: String
    public var signingNotarization: String
    public var modelPackaging: String
    public var license: String
    public var maintenance: String
    public var selectableForProduction: Bool
    public var limitations: [String]

    public init(tokenizerReferenceParity: String, dylibFrameworkPackaging: String, signingNotarization: String, modelPackaging: String, license: String, maintenance: String, selectableForProduction: Bool, limitations: [String]) {
        self.tokenizerReferenceParity = tokenizerReferenceParity
        self.dylibFrameworkPackaging = dylibFrameworkPackaging
        self.signingNotarization = signingNotarization
        self.modelPackaging = modelPackaging
        self.license = license
        self.maintenance = maintenance
        self.selectableForProduction = selectableForProduction
        self.limitations = limitations
    }
}

public struct EmbeddingQualificationResult: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var descriptor: QualificationEmbeddingDescriptor
    public var environment: EmbeddingQualificationEnvironment
    public var tokenizerParity: [TokenizerParityResult]
    public var vectorParity: [EmbeddingVectorParityResult]
    public var metrics: EmbeddingQualificationMetrics
    public var shipping: EmbeddingShippingAssessment
}

public enum EmbeddingQualificationError: LocalizedError {
    case missingArgument(String)
    case missingFrozenEvidence(String)
    case invalidVector(String)

    public var errorDescription: String? {
        switch self {
        case let .missingArgument(value): "Missing required argument: \(value)"
        case let .missingFrozenEvidence(value): "Frozen evidence is missing: \(value)"
        case let .invalidVector(value): "Embedding runtime returned an invalid vector: \(value)"
        }
    }
}

public struct EmbeddingBenchmarkInputs: Sendable {
    public var runRoot: URL
    public var casebookURL: URL
    public var tokenizerReferencesURL: URL
    public var vectorReferencesURL: URL
    public var modelDirectory: URL
    public var runtimeDirectory: URL?
    public var outputURL: URL
    public var iterations: Int

    public init(runRoot: URL, casebookURL: URL, tokenizerReferencesURL: URL, vectorReferencesURL: URL, modelDirectory: URL, runtimeDirectory: URL? = nil, outputURL: URL, iterations: Int) {
        self.runRoot = runRoot
        self.casebookURL = casebookURL
        self.tokenizerReferencesURL = tokenizerReferencesURL
        self.vectorReferencesURL = vectorReferencesURL
        self.modelDirectory = modelDirectory
        self.runtimeDirectory = runtimeDirectory
        self.outputURL = outputURL
        self.iterations = max(2, min(iterations, 50))
    }
}

public enum EmbeddingQualificationRunner {
    private struct Casebook: Decodable {
        struct Binding: Decodable { var id: String; var url: URL; var revisionID: String; var contentHash: String }
        struct Pair: Decodable { var left: String; var right: String; var expected: String }
        struct Search: Decodable { var query: String; var expectedHigh: [String] }
        var evidenceRevisionBindings: [Binding]
        var duplicateJudgments: [Pair]
        var searchJudgments: [Search]
    }

    public static func run(
        engine: any QualificationEmbeddingEngine,
        coldStartMilliseconds: Double,
        inputs: EmbeddingBenchmarkInputs,
        shipping: EmbeddingShippingAssessment
    ) async throws -> EmbeddingQualificationResult {
        let database = try CrosscurrentDatabase.open(at: DatabaseLocations(container: inputs.runRoot), role: .agent)
        let repository = CrosscurrentRepository(database: database, writerInstance: "embedding-qualification")
        let evidence = try await repository.qualificationEmbeddingEvidence()
        let casebook = try JSONDecoder().decode(Casebook.self, from: Data(contentsOf: inputs.casebookURL))
        let referenceManifest = try JSONDecoder().decode([TokenizerReference].self, from: Data(contentsOf: inputs.tokenizerReferencesURL))
        let vectorReferenceManifest = try JSONDecoder().decode(
            [EmbeddingVectorReference].self,
            from: Data(contentsOf: inputs.vectorReferencesURL)
        )

        let evidenceByRevision = Dictionary(uniqueKeysWithValues: evidence.map { ($0.itemRevisionID.description, $0) })
        let evidenceByHash = Dictionary(grouping: evidence, by: \.contentHash)
        var bound: [(String, QualificationEmbeddingRecord)] = []
        for binding in casebook.evidenceRevisionBindings {
            let record = evidenceByRevision[binding.revisionID] ?? evidenceByHash[binding.contentHash]?.first
            guard let record else { throw EmbeddingQualificationError.missingFrozenEvidence(binding.id) }
            bound.append((binding.id, record))
        }

        let references = referenceManifest.filter { $0.candidateIDs.contains(engine.descriptor.candidateID) }
        var parity: [TokenizerParityResult] = []
        for reference in references {
            let actual = try await engine.tokenIDs(for: reference.text, role: reference.role)
            parity.append(TokenizerParityResult(
                referenceID: reference.id,
                expected: reference.expectedTokenIDs,
                actual: actual,
                matches: actual == reference.expectedTokenIDs,
                referenceImplementation: reference.referenceImplementation
            ))
        }


        let vectorReferences = vectorReferenceManifest.filter {
            $0.candidateIDs.contains(engine.descriptor.candidateID)
        }
        var vectorParity: [EmbeddingVectorParityResult] = []
        for reference in vectorReferences {
            let expected = try decodeVector(reference)
            let actual = try await engine.embed([reference.text], role: reference.role)
            try validate(vectors: actual, expectedCount: 1, dimensions: reference.dimensions)
            vectorParity.append(EmbeddingVectorParityResult(
                referenceID: reference.id,
                dimensions: reference.dimensions,
                cosineSimilarity: cosine(expected, actual[0]),
                maximumAbsoluteDifference: zip(expected, actual[0]).map { pair in
                    abs(Double(pair.0) - Double(pair.1))
                }.max() ?? 0,
                referenceImplementation: reference.referenceImplementation
            ))
        }

        let passageTexts = bound.map { qualificationText($0.1) }
        let passageVectors = try await engine.embed(passageTexts, role: .passage)
        try validate(vectors: passageVectors, expectedCount: passageTexts.count, dimensions: engine.descriptor.dimensions)
        let vectorsByID = Dictionary(uniqueKeysWithValues: zip(bound.map(\.0), passageVectors))

        var retrieval: [RetrievalJudgmentResult] = []
        for judgment in casebook.searchJudgments {
            let query = try await engine.embed([judgment.query], role: .query)
            try validate(vectors: query, expectedCount: 1, dimensions: engine.descriptor.dimensions)
            let top = vectorsByID
                .map { ($0.key, cosine($0.value, query[0])) }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map(\.0)
            retrieval.append(RetrievalJudgmentResult(
                query: judgment.query,
                expectedHigh: judgment.expectedHigh,
                topTen: Array(top),
                expectedFoundInTopTen: judgment.expectedHigh.filter { top.contains($0) }.count
            ))
        }

        let languagesByID = Dictionary(uniqueKeysWithValues: bound.map { ($0.0, languageFamily(for: $0.1)) })
        var pairs: [PairSimilarityResult] = []
        var positiveCount = 0
        var crossLanguageCount = 0
        for judgment in casebook.duplicateJudgments {
            guard let left = vectorsByID[judgment.left], let right = vectorsByID[judgment.right] else { continue }
            pairs.append(PairSimilarityResult(left: judgment.left, right: judgment.right, expected: judgment.expected, cosineSimilarity: cosine(left, right)))
            if judgment.expected != "unrelated" {
                positiveCount += 1
                if languagesByID[judgment.left] != languagesByID[judgment.right] { crossLanguageCount += 1 }
            }
        }

        let sample = Array(passageTexts.prefix(min(12, passageTexts.count)))
        var warm: [Double] = []
        for _ in 0..<inputs.iterations {
            for text in sample {
                let start = ContinuousClock.now
                _ = try await engine.embed([text], role: .passage)
                warm.append(milliseconds(start.duration(to: .now)))
            }
        }
        let throughputStart = ContinuousClock.now
        _ = try await engine.embed(passageTexts, role: .passage)
        let throughputSeconds = max(0.000_001, seconds(throughputStart.duration(to: .now)))
        let sortedWarm = warm.sorted()

        var limitations = shipping.limitations
        if references.isEmpty { limitations.append("No independent tokenizer reference is registered for this candidate.") }
        if vectorReferences.isEmpty {
            limitations.append("No independent reference vector is registered for this candidate; vector parity remains unqualified.")
        }
        if positiveCount == 0 { limitations.append("The current frozen casebook has no positive duplicate pair for candidate-recall qualification.") }
        if crossLanguageCount == 0 { limitations.append("The current frozen casebook has no hash-bound cross-language positive pair; production selection is blocked until one is added.") }
        limitations.append("No representative baseline M1-class Mac was available; this host cannot establish baseline-device performance.")
        var assessedShipping = shipping
        assessedShipping.limitations = Array(Set(limitations)).sorted()
        assessedShipping.selectableForProduction = shipping.selectableForProduction
            && !parity.isEmpty && parity.allSatisfy(\.matches)
            && positiveCount > 0 && crossLanguageCount > 0

        let result = EmbeddingQualificationResult(
            generatedAt: .now,
            descriptor: engine.descriptor,
            environment: environment(
                modelDirectory: inputs.modelDirectory,
                runtimeDirectory: inputs.runtimeDirectory
            ),
            tokenizerParity: parity,
            vectorParity: vectorParity,
            metrics: EmbeddingQualificationMetrics(
                coldStartMilliseconds: coldStartMilliseconds,
                warmLatencyMilliseconds: warm,
                p50WarmLatencyMilliseconds: percentile(sortedWarm, 0.50),
                p95WarmLatencyMilliseconds: percentile(sortedWarm, 0.95),
                batchSegmentsPerSecond: Double(passageTexts.count) / throughputSeconds,
                peakResidentBytes: peakResidentBytes(),
                vectorIndexProjectedBytes: Int64(passageVectors.count * engine.descriptor.dimensions * MemoryLayout<Float>.size),
                retrieval: retrieval,
                pairSimilarities: pairs,
                positiveDuplicatePairs: positiveCount,
                crossLanguagePositivePairs: crossLanguageCount
            ),
            shipping: assessedShipping
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: inputs.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(result).write(to: inputs.outputURL, options: .atomic)
        return result
    }

    private static func qualificationText(_ evidence: QualificationEmbeddingRecord) -> String {
        let body = evidence.segments.map(\.text).joined(separator: "\n")
        return evidence.title + "\n" + String(body.prefix(4_000))
    }

    private static func validate(vectors: [[Float]], expectedCount: Int, dimensions: Int) throws {
        guard vectors.count == expectedCount else { throw EmbeddingQualificationError.invalidVector("expected \(expectedCount) vectors, received \(vectors.count)") }
        guard vectors.allSatisfy({ $0.count == dimensions && $0.allSatisfy(\.isFinite) })
        else { throw EmbeddingQualificationError.invalidVector("dimension or finite-value mismatch") }
    }

    private static func decodeVector(_ reference: EmbeddingVectorReference) throws -> [Float] {
        guard let data = Data(base64Encoded: reference.float32LittleEndianBase64),
              data.count == reference.dimensions * MemoryLayout<UInt32>.size
        else {
            throw EmbeddingQualificationError.invalidVector(
                "reference \(reference.id) does not contain \(reference.dimensions) little-endian float32 values"
            )
        }
        return Swift.stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        var dot = 0.0, left = 0.0, right = 0.0
        for index in lhs.indices {
            let l = Double(lhs[index]), r = Double(rhs[index])
            dot += l * r; left += l * l; right += r * r
        }
        return dot / max(1e-12, sqrt(left * right))
    }

    private static func languageFamily(_ value: String?) -> String {
        value?.lowercased().split(separator: "-").first.map(String.init) ?? "unknown"
    }

    private static func languageFamily(for evidence: QualificationEmbeddingRecord) -> String {
        let stored = languageFamily(evidence.languageCode)
        guard stored == "unknown" else { return stored }
        // Some public feed formats omit language metadata. Qualification may
        // infer only the broad script family from the exact frozen text; this is
        // deterministic and never rewrites the hash-bound canonical evidence.
        let sample = evidence.title + "\n" + evidence.segments.map(\.text).joined(separator: "\n")
        let han = sample.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.count
        let latin = sample.unicodeScalars.filter {
            (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value))
        }.count
        if han >= 8, han > latin / 8 { return "zh" }
        if latin >= 16 { return "en" }
        return "unknown"
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * quantile).rounded(.up))))
        return values[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double { seconds(duration) * 1_000 }
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func environment(modelDirectory: URL, runtimeDirectory: URL?) -> EmbeddingQualificationEnvironment {
        let runtimeBytes = runtimeDirectory.map(directorySize) ?? 0
        return EmbeddingQualificationEnvironment(
            hardwareModel: sysctl("hw.model"),
            processor: sysctl("machdep.cpu.brand_string"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemBuild: sysctl("kern.osversion"),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: String(describing: ProcessInfo.processInfo.thermalState),
            executableBytes: fileSize(URL(fileURLWithPath: CommandLine.arguments[0])),
            modelArtifactBytes: max(0, directorySize(modelDirectory) - runtimeBytes),
            runtimeArtifactBytes: runtimeBytes,
            qualificationLimitation: "Measured on this host only; no representative slower Apple-silicon machine was available."
        )
    }

    private static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard Darwin.sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard Darwin.sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

public enum EmbeddingBenchmarkArguments {
    public static func parse(defaultCandidateID: String) throws -> EmbeddingBenchmarkInputs {
        let root = try repositoryRoot()
        let casebook = value("--casebook").map(URL.init(fileURLWithPath:)) ?? root.appending(path: "Qualification/casebook.v1.json")
        let references = value("--tokenizer-references").map(URL.init(fileURLWithPath:)) ?? root.appending(path: "Qualification/tokenizer-references.v1.json")
        let vectorReferences = value("--vector-references").map(URL.init(fileURLWithPath:)) ?? root.appending(path: "Qualification/vector-references.v1.json")
        guard let run = value("--run") else { throw EmbeddingQualificationError.missingArgument("--run <frozen run directory>") }
        guard let model = value("--model-dir") else { throw EmbeddingQualificationError.missingArgument("--model-dir <verified artifact directory>") }
        let output = value("--output").map(URL.init(fileURLWithPath:))
            ?? root.appending(path: ".crosscurrent-qualification/embedding/\(defaultCandidateID).json")
        return EmbeddingBenchmarkInputs(
            runRoot: URL(fileURLWithPath: run, isDirectory: true),
            casebookURL: casebook,
            tokenizerReferencesURL: references,
            vectorReferencesURL: vectorReferences,
            modelDirectory: URL(fileURLWithPath: model, isDirectory: true),
            runtimeDirectory: value("--runtime-dir").map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            outputURL: output,
            iterations: Int(value("--iterations") ?? "3") ?? 3
        )
    }

    private static func value(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func repositoryRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appending(path: "AGENTS.md").path) { return current }
            current.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
