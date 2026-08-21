import Foundation
import FeedFlowDomain

public enum RepositoryRole: String, Codable, Sendable {
    case mainApp
    case agent
}

public enum ChangeDomain: String, Codable, CaseIterable, Sendable {
    case sources, endpoints, entities, items, metrics, events, constraints, topics
    case readState, digests, prompts, jobs, searchInputs, blobs, accounts, library
}

public enum FeedFlowStorageError: LocalizedError, Equatable {
    case incompatibleSchema(found: Int, required: Int)
    case migrationRequiresMainApp
    case jobLeaseUnavailable
    case invalidStagedData
    case databaseNotInitialized
    case integrityFailure(String)
    case corruptRecord(String)

    public var errorDescription: String? {
        switch self {
        case let .incompatibleSchema(found, required):
            "Waiting for FeedFlow to migrate/update (database schema \(found), required \(required))."
        case .migrationRequiresMainApp:
            "Only FeedFlow may migrate the canonical database."
        case .jobLeaseUnavailable:
            "The job is currently leased by another writer."
        case .invalidStagedData:
            "Staged data failed validation."
        case .databaseNotInitialized:
            "Waiting for FeedFlow to create the canonical database."
        case let .integrityFailure(message):
            "Canonical database integrity check failed: \(message)"
        case let .corruptRecord(record):
            "The canonical database contains an invalid \(record) record."
        }
    }
}

public struct ChangeGeneration: Codable, Hashable, Sendable {
    public var domain: ChangeDomain
    public var generation: Int64
    public var committedAt: Date
    public var writerInstance: String

    public init(domain: ChangeDomain, generation: Int64, committedAt: Date, writerInstance: String) {
        self.domain = domain
        self.generation = generation
        self.committedAt = committedAt
        self.writerInstance = writerInstance
    }
}

public enum JobState: String, Codable, CaseIterable, Sendable {
    case pending, leased, completed, failed, cancelled
}

public struct DurableJob: Identifiable, Codable, Hashable, Sendable {
    public var id: JobID
    public var kind: String
    public var inputHash: String
    public var idempotencyKey: String
    public var payload: Data
    public var state: JobState
    public var attemptCount: Int
    public var checkpoint: Data?
    public var nextAttemptAt: Date

    public init(id: JobID = JobID(), kind: String, inputHash: String, idempotencyKey: String, payload: Data = Data(), state: JobState = .pending, attemptCount: Int = 0, checkpoint: Data? = nil, nextAttemptAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.inputHash = inputHash
        self.idempotencyKey = idempotencyKey
        self.payload = payload
        self.state = state
        self.attemptCount = attemptCount
        self.checkpoint = checkpoint
        self.nextAttemptAt = nextAttemptAt
    }
}

public struct JobLease: Codable, Hashable, Sendable {
    public var jobID: JobID
    public var owner: String
    public var token: UUID
    public var acquiredAt: Date
    public var expiresAt: Date

    public init(jobID: JobID, owner: String, token: UUID = UUID(), acquiredAt: Date = .now, expiresAt: Date) {
        self.jobID = jobID
        self.owner = owner
        self.token = token
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }
}

public enum BlobRetentionClass: String, Codable, CaseIterable, Sendable {
    case publicRaw30Days
    case privateRaw7Days
    case failedExtraction30Days
    case publicDiagnostic30Days
    case privateDiagnostic7Days
    case cache30Days
    case durableEvidence
    case savedOffline
}

/// User-configurable expiry windows for rebuildable raw and diagnostic artifacts.
/// Canonical normalized revisions and evidence blobs are deliberately not governed by
/// these values.
public struct RawRetentionPolicy: Codable, Hashable, Sendable {
    public var publicDays: Int
    public var privateDays: Int
    public var failedExtractionDays: Int
    public var diagnosticDays: Int

    public init(publicDays: Int = 30, privateDays: Int = 7, failedExtractionDays: Int = 30, diagnosticDays: Int = 30) {
        self.publicDays = max(1, publicDays)
        self.privateDays = max(1, privateDays)
        self.failedExtractionDays = max(1, failedExtractionDays)
        self.diagnosticDays = max(1, diagnosticDays)
    }
}

public enum DeletionKind: String, Codable, CaseIterable, Sendable {
    case remoteDeletion
    case userTrash
    case userPurge
    case legalPolicyPurge
    case connectorMandatedPurge
}

public struct StoredBlob: Identifiable, Codable, Hashable, Sendable {
    public var id: BlobID
    public var sha256: String
    public var relativePath: String
    public var byteCount: Int
    public var mediaType: String?
    public var retentionClass: BlobRetentionClass
    public var createdAt: Date

    public init(id: BlobID = BlobID(), sha256: String, relativePath: String, byteCount: Int, mediaType: String? = nil, retentionClass: BlobRetentionClass, createdAt: Date = .now) {
        self.id = id
        self.sha256 = sha256
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.retentionClass = retentionClass
        self.createdAt = createdAt
    }
}

public struct RawFetchReceipt: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var endpointID: SourceEndpointID?
    public var safeURL: URL
    public var statusCode: Int?
    public var responseSHA256: String?
    public var blobID: BlobID?
    public var fetchedAt: Date
    public var retentionClass: BlobRetentionClass
    public var extractionOutcome: String?

    public init(id: UUID = UUID(), endpointID: SourceEndpointID? = nil, safeURL: URL, statusCode: Int? = nil, responseSHA256: String? = nil, blobID: BlobID? = nil, fetchedAt: Date = .now, retentionClass: BlobRetentionClass, extractionOutcome: String? = nil) {
        self.id = id
        self.endpointID = endpointID
        self.safeURL = safeURL
        self.statusCode = statusCode
        self.responseSHA256 = responseSHA256
        self.blobID = blobID
        self.fetchedAt = fetchedAt
        self.retentionClass = retentionClass
        self.extractionOutcome = extractionOutcome
    }
}

public struct StoredItemState: Codable, Hashable, Sendable {
    public var itemID: ItemID
    public var currentRevisionID: ItemRevisionID
    public var currentOrdinal: Int
    public var currentContentHash: String

    public init(itemID: ItemID, currentRevisionID: ItemRevisionID, currentOrdinal: Int, currentContentHash: String) {
        self.itemID = itemID
        self.currentRevisionID = currentRevisionID
        self.currentOrdinal = currentOrdinal
        self.currentContentHash = currentContentHash
    }
}

public struct ActivePrompt: Codable, Hashable, Sendable {
    public var template: PromptTemplate
    public var revision: PromptRevision

    public init(template: PromptTemplate, revision: PromptRevision) {
        self.template = template
        self.revision = revision
    }
}

public struct StoredAICompletion: Codable, Hashable, Sendable {
    public var text: String
    public var providerRequestID: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(text: String, providerRequestID: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.providerRequestID = providerRequestID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct StoredSyncCursor: Codable, Hashable, Sendable {
    public var family: String
    public var data: Data

    public init(family: String, data: Data) {
        self.family = family
        self.data = data
    }
}

/// Exact current evidence waiting for deterministic/embedding clustering. The revision and
/// segment IDs are never replaced by mutable Item identities in downstream provenance.
public struct PendingEvidenceSegment: Codable, Hashable, Sendable {
    public var itemID: ItemID
    public var itemRevision: ItemRevision
    public var segment: ItemSegment
    public var sourceID: SourceID
    public var sourceName: String
    public var canonicalURL: URL?
    public var accountID: ConnectorAccountID?

    public init(itemID: ItemID, itemRevision: ItemRevision, segment: ItemSegment, sourceID: SourceID, sourceName: String, canonicalURL: URL?, accountID: ConnectorAccountID?) {
        self.itemID = itemID
        self.itemRevision = itemRevision
        self.segment = segment
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.canonicalURL = canonicalURL
        self.accountID = accountID
    }
}

public struct StoredEventAggregate: Codable, Hashable, Sendable {
    public var event: Event
    public var revision: EventRevision
    public var memberships: [EventMembershipAssertion]

    public init(event: Event, revision: EventRevision, memberships: [EventMembershipAssertion]) {
        self.event = event
        self.revision = revision
        self.memberships = memberships
    }
}

/// Process-neutral projection consumed by the app shell. It keeps reader state and the exact
/// primary ItemRevision while avoiding a dependency from storage onto presentation modules.
public struct StoredEventSnapshot: Codable, Hashable, Sendable {
    public var aggregate: StoredEventAggregate
    public var primaryItemRevisionID: ItemRevisionID
    public var primarySourceID: SourceID
    public var contentPrivacy: ContentPrivacy
    public var primarySourceName: String
    public var sourceCount: Int
    public var independentSourceCount: Int
    public var topics: [String]
    public var followedPeople: [String]
    public var readerText: String
    public var readerHTML: String?
    public var originalURL: URL?
    public var originalAccountID: ConnectorAccountID?
    public var chinaGlobalCoverageSufficient: Bool
    public var readStatus: RevisionReadStatus

    public init(aggregate: StoredEventAggregate, primaryItemRevisionID: ItemRevisionID, primarySourceID: SourceID, contentPrivacy: ContentPrivacy, primarySourceName: String, sourceCount: Int, independentSourceCount: Int, topics: [String], followedPeople: [String], readerText: String, readerHTML: String? = nil, originalURL: URL?, originalAccountID: ConnectorAccountID?, chinaGlobalCoverageSufficient: Bool, readStatus: RevisionReadStatus) {
        self.aggregate = aggregate
        self.primaryItemRevisionID = primaryItemRevisionID
        self.primarySourceID = primarySourceID
        self.contentPrivacy = contentPrivacy
        self.primarySourceName = primarySourceName
        self.sourceCount = sourceCount
        self.independentSourceCount = independentSourceCount
        self.topics = topics
        self.followedPeople = followedPeople
        self.readerText = readerText
        self.readerHTML = readerHTML
        self.originalURL = originalURL
        self.originalAccountID = originalAccountID
        self.chinaGlobalCoverageSufficient = chinaGlobalCoverageSufficient
        self.readStatus = readStatus
    }
}

public struct StoredDigestState: Codable, Hashable, Sendable {
    public var digest: Digest
    public var initialRevisionID: DigestRevisionID
    public var latestRevision: DigestRevision
    public var completedAdditionalBriefingKeys: Set<String>

    public init(digest: Digest, initialRevisionID: DigestRevisionID, latestRevision: DigestRevision, completedAdditionalBriefingKeys: Set<String> = []) {
        self.digest = digest
        self.initialRevisionID = initialRevisionID
        self.latestRevision = latestRevision
        self.completedAdditionalBriefingKeys = completedAdditionalBriefingKeys
    }
}

public struct StoredSearchDocument: Codable, Hashable, Sendable {
    public var stableID: String
    public var kind: String
    public var revisionID: String?
    public var languageCode: String?
    public var title: String
    public var body: String
    public var isHistorical: Bool

    public init(stableID: String, kind: String, revisionID: String?, languageCode: String?, title: String, body: String, isHistorical: Bool) {
        self.stableID = stableID
        self.kind = kind
        self.revisionID = revisionID
        self.languageCode = languageCode
        self.title = title
        self.body = body
        self.isHistorical = isHistorical
    }
}

public struct ProviderConfigurationRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var displayName: String
    public var keychainReference: Data?
    public var enabled: Bool
    public var configuration: Data

    public init(id: String, kind: String, displayName: String, keychainReference: Data?, enabled: Bool = true, configuration: Data) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.keychainReference = keychainReference
        self.enabled = enabled
        self.configuration = configuration
    }
}

public struct StoredSourceSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: SourceID { source.id }
    public var source: LogicalSource
    public var revision: SourceRevision
    public var endpoints: [SourceEndpoint]
    public var aiClassification: SourceAIClassification?
    public var coverage: SourceCoverageAssertion?
}

public struct StoredEntitySnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID { entity.id }
    public var entity: Entity
    public var revision: EntityRevision
    public var aliases: [EntityAlias]
    public var sourceNames: [String]
}

public struct StoredTopicSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: TopicID { topic.id }
    public var topic: Topic
    public var revision: TopicRevision
    public var eventCount: Int
}

public struct StoredEventEvidence: Identifiable, Codable, Hashable, Sendable {
    public var id: MembershipAssertionID
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID
    public var sourceName: String
    public var title: String
    public var excerpt: String
    public var span: TextSpan
    public var role: MembershipRole
    public var decision: MembershipDecision
    public var confidence: Confidence
    public var publishedAt: Date?
    public var isPrimary: Bool

    public init(id: MembershipAssertionID, itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID, sourceName: String, title: String, excerpt: String, span: TextSpan, role: MembershipRole, decision: MembershipDecision, confidence: Confidence, publishedAt: Date?, isPrimary: Bool) {
        self.id = id
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.sourceName = sourceName
        self.title = title
        self.excerpt = excerpt
        self.span = span
        self.role = role
        self.decision = decision
        self.confidence = confidence
        self.publishedAt = publishedAt
        self.isPrimary = isPrimary
    }
}

public struct StoredEventRevisionSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: EventRevisionID
    public var ordinal: Int
    public var title: String
    public var changeKind: RevisionChangeKind
    public var createdAt: Date
    public var evidenceCount: Int

    public init(id: EventRevisionID, ordinal: Int, title: String, changeKind: RevisionChangeKind, createdAt: Date, evidenceCount: Int) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.changeKind = changeKind
        self.createdAt = createdAt
        self.evidenceCount = evidenceCount
    }
}

public struct DatabaseLocations: Sendable {
    public var container: URL
    public var canonicalDatabase: URL { container.appending(path: "Canonical/FeedFlow.sqlite") }
    public var derivedSearch: URL { container.appending(path: "Derived/Search", directoryHint: .isDirectory) }
    public var blobs: URL { container.appending(path: "Blobs", directoryHint: .isDirectory) }
    public var shareInbox: URL { container.appending(path: "Inbox", directoryHint: .isDirectory) }
    public var backups: URL { container.appending(path: "Backups", directoryHint: .isDirectory) }
    public var migrationLock: URL { container.appending(path: "Canonical/migration.lock") }

    public init(container: URL) { self.container = container }

    public static func appGroup(identifier: String = "group.com.chonghanqin.feedflow") throws -> Self {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "App Group container is unavailable: \(identifier)"])
        }
        return Self(container: url)
    }

    public func prepare() throws {
        let manager = FileManager.default
        for directory in [canonicalDatabase.deletingLastPathComponent(), derivedSearch, blobs, shareInbox, backups] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
