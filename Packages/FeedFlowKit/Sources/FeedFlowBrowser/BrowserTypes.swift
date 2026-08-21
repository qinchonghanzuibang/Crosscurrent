import Foundation
import FeedFlowConnectors
import FeedFlowDomain

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

public enum BrowserWorkerRequest: Codable, Hashable, Sendable {
    case navigate(BrowserNavigationRequest)
    case authenticate(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID, presentsWindow: Bool)
    case discover(BrowserCreatorDiscoveryRequest)
    case refresh(BrowserCreatorRefreshRequest)
    case health(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID?)
    case disconnect(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID)
}

public enum BrowserWorkerResponse: Codable, Hashable, Sendable {
    case page(BrowserPageSnapshot)
    case creatorIdentity(BrowserCreatorIdentity)
    case refreshPage(ConnectorRefreshPage)
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
