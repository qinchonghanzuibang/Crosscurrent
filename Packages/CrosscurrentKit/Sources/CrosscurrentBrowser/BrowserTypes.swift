import Foundation
import CrosscurrentConnectors
import CrosscurrentDomain

public struct BrowserProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var createdAt: Date

    public init(id: UUID = UUID(), displayName: String, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public struct BrowserNavigationRequest: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var url: URL
    public var presentsWindow: Bool

    public init(profileID: UUID, url: URL, presentsWindow: Bool = false) {
        self.profileID = profileID
        self.url = url
        self.presentsWindow = presentsWindow
    }
}

public struct BrowserPageSnapshot: Codable, Hashable, Sendable {
    public var finalURL: URL
    public var title: String
    public var sanitizedHTML: String
    public var plainText: String
    public var capturedAt: Date

    public init(finalURL: URL, title: String, sanitizedHTML: String, plainText: String, capturedAt: Date = .now) {
        self.finalURL = finalURL
        self.title = title
        self.sanitizedHTML = sanitizedHTML
        self.plainText = plainText
        self.capturedAt = capturedAt
    }
}

public enum BrowserPlatformCaptureKind: String, Codable, Sendable {
    case discovery, listing, detail, pagination, deletion, sessionExpiry, reconnect
}

public struct BrowserPlatformCaptureRequest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var platform: AuthenticatedCreatorPlatform
    public var accountID: ConnectorAccountID
    public var url: URL
    public var kind: BrowserPlatformCaptureKind

    public init(schemaVersion: Int = 1, platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID, url: URL, kind: BrowserPlatformCaptureKind) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.accountID = accountID
        self.url = url
        self.kind = kind
    }
}

public struct BrowserPlatformCaptureFixture: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var platform: AuthenticatedCreatorPlatform
    public var kind: BrowserPlatformCaptureKind
    public var finalURLWithoutQuery: URL
    public var title: String
    public var topLevelElementCounts: [String: Int]
    public var resourceOrigins: [String]
    public var capturedAt: Date

    public init(schemaVersion: Int, platform: AuthenticatedCreatorPlatform, kind: BrowserPlatformCaptureKind, finalURLWithoutQuery: URL, title: String, topLevelElementCounts: [String: Int], resourceOrigins: [String], capturedAt: Date = .now) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.kind = kind
        self.finalURLWithoutQuery = finalURLWithoutQuery
        self.title = title
        self.topLevelElementCounts = topLevelElementCounts
        self.resourceOrigins = resourceOrigins
        self.capturedAt = capturedAt
    }
}

public enum BrowserWorkerRequest: Codable, Hashable, Sendable {
    case navigate(BrowserNavigationRequest)
    case authenticate(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID, presentsWindow: Bool)
    case discover(BrowserCreatorDiscoveryRequest)
    case refresh(BrowserCreatorRefreshRequest)
    case capture(BrowserPlatformCaptureRequest)
    case health(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID?)
    case disconnect(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID)
}

public enum BrowserWorkerResponse: Codable, Hashable, Sendable {
    case page(BrowserPageSnapshot)
    case creatorIdentity(BrowserCreatorIdentity)
    case refreshPage(ConnectorRefreshPage)
    case captureFixture(BrowserPlatformCaptureFixture)
    case health(ConnectorHealth)
    case acknowledged
}

public struct BrowserDOMCursor: Codable, Hashable, Sendable {
    public var seenExternalIDs: Set<String>
    public var scrollCount: Int

    public init(seenExternalIDs: Set<String> = [], scrollCount: Int = 0) {
        self.seenExternalIDs = seenExternalIDs
        self.scrollCount = scrollCount
    }
}

public enum BrowserWorkerError: LocalizedError, Equatable {
    case navigationFailed(String)
    case extractionFailed(String)
    case invalidResult
    case profileUnavailable

    public var errorDescription: String? {
        switch self {
        case let .navigationFailed(message): "Browser navigation failed: \(message)"
        case let .extractionFailed(message): "Browser extraction failed: \(message)"
        case .invalidResult: "BrowserWorker returned an invalid result."
        case .profileUnavailable: "The browser profile is unavailable."
        }
    }
}
