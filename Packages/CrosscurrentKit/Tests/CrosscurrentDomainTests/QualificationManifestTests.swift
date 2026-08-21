import Foundation
import Testing

@Test func embeddingQualificationManifestsStayPinnedAndEvidenceDriven() throws {
    let root = repositoryRoot()
    let candidateData = try Data(
        contentsOf: root.appending(path: "Qualification/embedding-candidates.v1.json")
    )
    let candidateObject = try #require(
        JSONSerialization.jsonObject(with: candidateData) as? [String: Any]
    )
    let policy = try #require(candidateObject["selectionPolicy"] as? String)
    #expect(policy.contains("Pareto objective"))
    #expect(policy.contains("no invented hard limits"))
    let candidates = try #require(candidateObject["candidates"] as? [[String: Any]])
    let candidateIDs = Set(candidates.compactMap { $0["id"] as? String })
    #expect(candidateIDs.contains("minilm-l12-native-coreml-all"))
    #expect(candidateIDs.contains("multilingual-e5-small-mlx"))
    #expect(candidateIDs.contains("multilingual-e5-small-ort-coreml"))

    for candidate in candidates where candidate["status"] as? String == "benchmarkable" {
        #expect((candidate["modelRevision"] as? String)?.count == 40)
        let artifacts = try #require(candidate["artifacts"] as? [[String: Any]])
        if candidate["inheritsArtifactsFrom"] == nil {
            #expect(!artifacts.isEmpty)
        }
        for artifact in artifacts {
            #expect((artifact["bytes"] as? Int ?? 0) > 0)
            let checksum = artifact["sha256"] as? String ?? ""
            #expect(checksum.count == 64)
            #expect(checksum.allSatisfy { $0.isHexDigit })
        }
    }

    let referenceData = try Data(
        contentsOf: root.appending(path: "Qualification/tokenizer-references.v1.json")
    )
    let references = try #require(
        JSONSerialization.jsonObject(with: referenceData) as? [[String: Any]]
    )
    #expect(!references.isEmpty)
    for reference in references {
        #expect(!(reference["candidateIDs"] as? [String] ?? []).isEmpty)
        #expect(!(reference["expectedTokenIDs"] as? [Int] ?? []).isEmpty)
        #expect(!(reference["referenceImplementation"] as? String ?? "").isEmpty)
    }

    let vectorData = try Data(
        contentsOf: root.appending(path: "Qualification/vector-references.v1.json")
    )
    let vectorReferences = try #require(
        JSONSerialization.jsonObject(with: vectorData) as? [[String: Any]]
    )
    #expect(!vectorReferences.isEmpty)
    for reference in vectorReferences {
        let dimensions = reference["dimensions"] as? Int ?? 0
        let encoded = reference["float32LittleEndianBase64"] as? String ?? ""
        #expect(!(reference["candidateIDs"] as? [String] ?? []).isEmpty)
        #expect(Data(base64Encoded: encoded)?.count == dimensions * MemoryLayout<Float>.size)
        #expect(!(reference["referenceImplementation"] as? String ?? "").isEmpty)
    }

    let selectionData = try Data(
        contentsOf: root.appending(path: "Qualification/embedding-selection.v1.json")
    )
    let selection = try #require(
        JSONSerialization.jsonObject(with: selectionData) as? [String: Any]
    )
    #expect(selection["decision"] as? String == "development-selected-release-qualification-pending")
    #expect(selection["selectedCandidateID"] as? String == "multilingual-e5-small-ort-cpu")
    #expect((selection["releaseLimitations"] as? [String] ?? []).contains {
        $0.contains("M1-class")
    })
}

private func repositoryRoot() -> URL {
    var result = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { result.deleteLastPathComponent() }
    return result
}
