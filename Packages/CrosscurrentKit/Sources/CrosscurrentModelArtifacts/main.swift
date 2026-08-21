import CryptoKit
import Foundation

private struct CandidateManifest: Decodable {
    struct Artifact: Codable {
        var sourcePath: String?
        var sourceURL: URL?
        var destination: String
        var bytes: Int64
        var sha256: String
    }

    struct Candidate: Decodable {
        var id: String
        var inheritsArtifactsFrom: String?
        var model: String
        var modelRevision: String?
        var license: String?
        var status: String
        var artifacts: [Artifact]
    }

    var version: Int
    var candidates: [Candidate]
}

private struct InstalledArtifactManifest: Encodable {
    var qualificationManifestVersion: Int
    var candidateID: String
    var model: String
    var modelRevision: String
    var license: String
    var validatedAt: Date
    var artifacts: [CandidateManifest.Artifact]
}

private enum ArtifactError: LocalizedError {
    case usage(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .usage(value), let .invalid(value): value
        }
    }
}

@main
private enum ModelArtifactCommand {
    static func main() async throws {
        let root = try repositoryRoot()
        let manifestURL = argument("--manifest").map(URL.init(fileURLWithPath:))
            ?? root.appending(path: "Qualification/embedding-candidates.v1.json")
        guard let candidateID = argument("--candidate") else { throw ArtifactError.usage("Pass --candidate <candidate-id>.") }
        let outputRoot = argument("--output").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appending(path: ".crosscurrent-qualification/models/\(candidateID)", directoryHint: .isDirectory)
        let manifest = try JSONDecoder().decode(CandidateManifest.self, from: Data(contentsOf: manifestURL))
        guard let candidate = manifest.candidates.first(where: { $0.id == candidateID }) else {
            throw ArtifactError.invalid("Unknown candidate \(candidateID).")
        }
        guard candidate.status == "benchmarkable" else {
            throw ArtifactError.invalid("Candidate \(candidateID) is \(candidate.status), not benchmarkable.")
        }
        guard let revision = candidate.modelRevision, revision.count >= 12 else {
            throw ArtifactError.invalid("Candidate \(candidateID) does not pin a model revision.")
        }
        let license = candidate.license ?? ""
        guard ["MIT", "Apache-2.0"].contains(license) else {
            throw ArtifactError.invalid("Candidate \(candidateID) has an unapproved or missing license: \(license).")
        }
        let artifacts: [CandidateManifest.Artifact]
        if let inherited = candidate.inheritsArtifactsFrom {
            guard let base = manifest.candidates.first(where: { $0.id == inherited }) else {
                throw ArtifactError.invalid("Candidate \(candidateID) inherits missing artifacts from \(inherited).")
            }
            artifacts = base.artifacts
        } else {
            artifacts = candidate.artifacts
        }
        guard !artifacts.isEmpty else { throw ArtifactError.invalid("Candidate \(candidateID) has no verified artifact set.") }

        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        for artifact in artifacts {
            let destination = outputRoot.appending(path: artifact.destination)
            try validateDestination(destination, inside: outputRoot)
            if try validates(destination, artifact: artifact) { continue }
            if FileManager.default.fileExists(atPath: destination.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let size = fileSize(attributes)
                let digest = try sha256(destination)
                print("re-fetching \(artifact.destination): size \(size)/\(artifact.bytes), sha256 \(digest)/\(artifact.sha256)")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url: URL
            if let sourceURL = artifact.sourceURL {
                guard sourceURL.scheme == "https" else {
                    throw ArtifactError.invalid("Runtime artifact URL must use HTTPS.")
                }
                url = sourceURL
            } else if let sourcePath = artifact.sourcePath,
                      let encodedPath = sourcePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let modelURL = URL(string: "https://huggingface.co/\(candidate.model)/resolve/\(revision)/\(encodedPath)") {
                url = modelURL
            } else {
                throw ArtifactError.invalid("Artifact has neither a valid pinned model path nor an HTTPS source URL.")
            }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ArtifactError.invalid("Artifact download failed for \(url.absoluteString).")
            }
            guard try validates(temporary, artifact: artifact) else {
                throw ArtifactError.invalid("Checksum or size mismatch for \(url.absoluteString).")
            }
            let staged = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).staged-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: temporary, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            print("validated \(artifact.destination)")
        }

        let installed = InstalledArtifactManifest(
            qualificationManifestVersion: manifest.version,
            candidateID: candidateID,
            model: candidate.model,
            modelRevision: revision,
            license: license,
            validatedAt: .now,
            artifacts: artifacts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(installed).write(to: outputRoot.appending(path: "artifact-manifest.json"), options: .atomic)
        print(outputRoot.path)
    }

    private static func validates(_ url: URL, artifact: CandidateManifest.Artifact) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard fileSize(attributes) == artifact.bytes else { return false }
        return try sha256(url) == artifact.sha256.lowercased()
    }

    private static func fileSize(_ attributes: [FileAttributeKey: Any]) -> Int64 {
        if let value = attributes[.size] as? NSNumber { return value.int64Value }
        if let value = attributes[.size] as? Int { return Int64(value) }
        if let value = attributes[.size] as? Int64 { return value }
        return -1
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateDestination(_ destination: URL, inside root: URL) throws {
        let rootPath = root.standardizedFileURL.path + "/"
        guard destination.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw ArtifactError.invalid("Artifact destination escapes the selected output directory.")
        }
    }

    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func repositoryRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appending(path: "AGENTS.md").path) { return current }
            current.deleteLastPathComponent()
        }
        throw ArtifactError.usage("Run inside the Crosscurrent repository or pass --manifest and --output.")
    }
}
