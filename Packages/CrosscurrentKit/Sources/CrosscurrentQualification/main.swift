import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentIntelligence
import CrosscurrentRanking
import CrosscurrentSearch
import CrosscurrentStorage
import Darwin
import Foundation

private struct QualificationManifest: Codable {
    var version: Int
    var sources: [LiveSource]
}

private struct LiveSource: Codable {
    var id: String
    var url: URL
    var maximumSamples: Int
}

private struct SourceRun: Codable {
    var id: String
    var url: URL
    var connector: ConnectorKind?
    var importedItems: Int
    var error: String?
}

private struct QualificationEnvironment: Codable {
    var hardwareModel: String
    var processor: String
    var memoryBytes: UInt64
    var operatingSystem: String
}

private struct CasebookManifest: Codable {
    var version: Int
    var evidenceRevisionBindings: [CasebookBinding]
}

private struct CasebookBinding: Codable {
    var id: String
    var url: URL
    var revisionID: String
    var contentHash: String
}

private struct CasebookBindingStatus: Codable {
    enum Status: String, Codable { case exactFrozenRevision, sameContentNewRevision, contentDiverged, missing }
    var id: String
    var url: URL
    var expectedRevisionID: String
    var expectedContentHash: String
    var actualRevisionID: String?
    var actualContentHash: String?
    var status: Status
}

private struct QualificationResult: Codable {
    var manifestVersion: Int
    var frozenAt: Date
    var environment: QualificationEnvironment
    var sources: [SourceRun]
    var evidence: [QualificationEvidenceRecord]
    var casebookBindings: [CasebookBindingStatus]
}

private actor UnavailableBrowser: BrowserCreatorSessionClient {
    func authenticate(platform _: AuthenticatedCreatorPlatform, accountID _: ConnectorAccountID, allowsInteraction _: Bool) async throws { throw ConnectorError.authenticationRequired }
    func discover(_: BrowserCreatorDiscoveryRequest) async throws -> BrowserCreatorIdentity { throw ConnectorError.authenticationRequired }
    func refresh(_: BrowserCreatorRefreshRequest) async throws -> ConnectorRefreshPage { throw ConnectorError.authenticationRequired }
    func health(platform _: AuthenticatedCreatorPlatform, accountID _: ConnectorAccountID?) async -> ConnectorHealth { .authenticationRequired }
    func disconnect(platform _: AuthenticatedCreatorPlatform, accountID _: ConnectorAccountID) async throws {}
}

@main
private struct CrosscurrentQualificationCommand {
    static func main() async throws {
        let root = try repositoryRoot()
        let manifestURL = argument("--manifest").map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: "Qualification/live-sources.v1.json")
        let cacheRoot = argument("--cache").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appending(path: ".crosscurrent-qualification", directoryHint: .isDirectory)
        let manifest = try JSONDecoder().decode(QualificationManifest.self, from: Data(contentsOf: manifestURL))
        let casebookURL = argument("--casebook").map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: "Qualification/casebook.v1.json")
        let casebook = try JSONDecoder().decode(CasebookManifest.self, from: Data(contentsOf: casebookURL))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let runKey = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let runRoot = cacheRoot.appending(path: "runs/\(runKey)", directoryHint: .isDirectory)
        let locations = DatabaseLocations(container: runRoot)
        let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
        let repository = CrosscurrentRepository(database: database, writerInstance: "qualification-\(UUID().uuidString.lowercased())")
        let blobs = CanonicalBlobStore(locations: locations, repository: repository)
        let http = ArchivingConnectorHTTPClient(repository: repository, blobStore: blobs)
        let registry = await ConnectorCatalog.production(browser: UnavailableBrowser(), http: http)
        let discovery = SourceDiscoveryService(repository: repository, connectors: registry, blobStore: blobs, http: http)
        let refresh = RefreshJobExecutor(repository: repository, connectors: registry, blobStore: blobs, http: http)

        var sourceRuns: [SourceRun] = []
        for source in manifest.sources {
            do {
                var preview = try await discovery.preview(.init(url: source.url), context: ConnectorContext())
                preview.result.recentCandidates = Array(preview.result.recentCandidates.prefix(max(1, min(source.maximumSamples, 50))))
                let action: SourceDiscoveryAction = preview.availableActions.contains(SourceDiscoveryAction.monitor) ? .monitor : .subscribe
                let committed = try await discovery.commit(preview, action: action)
                var importedItems = committed.importedItems
                if action != .importOnce {
                    for endpointID in committed.endpointIDs {
                        let payload = try JSONEncoder().encode(RefreshJobPayload(endpointID: endpointID, maximumPages: 1, maximumItems: source.maximumSamples))
                        let job = DurableJob(kind: CrosscurrentJobKind.refresh, inputHash: endpointID.description, idempotencyKey: "qualification-refresh:\(source.id):\(endpointID)", payload: payload)
                        _ = try await repository.enqueue(job)
                        if let (leased, lease) = try await repository.leaseJob(id: job.id, owner: "qualification", duration: 300) {
                            let checkpoint = try await refresh.execute(job: leased, lease: lease)
                            importedItems += checkpoint.itemRevisions
                            _ = try await repository.completeJob(lease, checkpoint: try JSONEncoder().encode(checkpoint))
                        }
                    }
                }
                sourceRuns.append(SourceRun(id: source.id, url: source.url, connector: preview.connectorKind, importedItems: importedItems, error: nil))
            } catch {
                sourceRuns.append(SourceRun(id: source.id, url: source.url, connector: nil, importedItems: 0, error: error.localizedDescription))
            }
        }

        _ = try await EvidenceEventMaintainer(repository: repository).run()
        _ = try await TodayCoordinator(repository: repository).update(trigger: .opening)
        let index = try DerivedIndexCoordinator(repository: repository, directory: locations.derivedSearch)
        _ = try await index.synchronize()

        let evidence = try await repository.qualificationEvidenceRecords()
        let result = QualificationResult(
            manifestVersion: manifest.version,
            frozenAt: .now,
            environment: environment(),
            sources: sourceRuns,
            evidence: evidence,
            casebookBindings: bindingStatuses(casebook.evidenceRevisionBindings, evidence: evidence)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let resultURL = runRoot.appending(path: "qualification-result.json")
        try encoder.encode(result).write(to: resultURL, options: .atomic)
        print(resultURL.path)
    }

    private static func bindingStatuses(_ bindings: [CasebookBinding], evidence: [QualificationEvidenceRecord]) -> [CasebookBindingStatus] {
        bindings.map { binding in
            let current = evidence.first { $0.canonicalURL == binding.url }
            let status: CasebookBindingStatus.Status
            if let current, current.itemRevisionID.description == binding.revisionID, current.contentHash == binding.contentHash {
                status = .exactFrozenRevision
            } else if current?.contentHash == binding.contentHash {
                status = .sameContentNewRevision
            } else if current != nil {
                status = .contentDiverged
            } else {
                status = .missing
            }
            return CasebookBindingStatus(
                id: binding.id,
                url: binding.url,
                expectedRevisionID: binding.revisionID,
                expectedContentHash: binding.contentHash,
                actualRevisionID: current?.itemRevisionID.description,
                actualContentHash: current?.contentHash,
                status: status
            )
        }
    }

    private static func argument(_ name: String) -> String? {
        let values = CommandLine.arguments
        guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
        return values[index + 1]
    }

    private static func repositoryRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appending(path: "AGENTS.md").path) { return current }
            current.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Run from inside the Crosscurrent repository or pass --manifest and --cache."])
    }

    private static func environment() -> QualificationEnvironment {
        QualificationEnvironment(
            hardwareModel: sysctl("hw.model"),
            processor: sysctl("machdep.cpu.brand_string"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard Darwin.sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard Darwin.sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
