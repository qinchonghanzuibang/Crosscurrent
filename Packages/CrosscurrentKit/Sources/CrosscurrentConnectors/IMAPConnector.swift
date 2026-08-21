import Foundation
import CrosscurrentDomain

public struct IMAPAccountConfiguration: Codable, Hashable, Sendable {
    public enum Authentication: String, Codable, Sendable { case password, appPassword, xoauth2 }
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    public var useTLS: Bool

    public init(host: String, port: Int = 993, username: String, authentication: Authentication, useTLS: Bool = true) {
        self.host = host; self.port = port; self.username = username; self.authentication = authentication; self.useTLS = useTLS
    }
}

public struct IMAPMessage: Codable, Hashable, Sendable {
    public var uidValidity: UInt64
    public var uid: UInt64
    public var messageID: String?
    public var subject: String
    public var from: String?
    public var date: Date?
    public var plainText: String?
    public var html: String?

    public init(uidValidity: UInt64, uid: UInt64, messageID: String? = nil, subject: String, from: String? = nil, date: Date? = nil, plainText: String? = nil, html: String? = nil) {
        self.uidValidity = uidValidity; self.uid = uid; self.messageID = messageID; self.subject = subject; self.from = from; self.date = date; self.plainText = plainText; self.html = html
    }
}

public struct IMAPPage: Codable, Hashable, Sendable {
    public var messages: [IMAPMessage]
    public var nextUID: UInt64?
    public var reachedEnd: Bool
}

public protocol IMAPSessionTransport: Sendable {
    var implementationID: String { get }
    func authenticate(accountID: ConnectorAccountID) async throws
    func fetch(folder: String, afterUID: UInt64?, limit: Int) async throws -> IMAPPage
    func idle(folder: String) async throws -> AsyncStream<Void>
    func health() async -> ConnectorHealth
    func disconnect() async
}

public actor IMAPConnector: Connector {
    public nonisolated let kind: ConnectorKind
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .authentication, .deltaSync, .pagination, .fullContent, .backgroundRefresh]
    private let transport: any IMAPSessionTransport

    public init(kind: ConnectorKind = .imap, transport: any IMAPSessionTransport) {
        precondition(kind == .imap || kind == .gmail)
        self.kind = kind
        self.transport = transport
    }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let scheme = input.url.scheme?.lowercased()
        guard scheme == "imap" || scheme == "imaps" || (kind == .gmail && scheme == "gmail") else { throw ConnectorError.unsupportedInput }
        let revisionID = SourceRevisionID(); let source = LogicalSource(currentRevisionID: revisionID, kind: .newsletter)
        let name = input.url.host ?? "Mail newsletters"
        let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: name)
        let endpoint = SourceEndpoint(sourceID: source.id, connector: kind, accountID: input.accountID, externalID: input.url.absoluteString, canonicalURL: input.url, accessRequirement: .authenticated, contentPrivacy: .private)
        return ConnectorDiscoveryResult(source: source, sourceRevision: revision, endpoints: [endpoint], aiClassification: SourceAIClassification(sourceID: source.id, accessRequirement: .authenticated, contentPrivacy: .private, provenance: .connector, confidence: .certain), coverageCandidate: SourceCoverageAssertion(sourceID: source.id, ecosystem: .unknown, provenance: .connector, confidence: .unknown))
    }
    public func authenticate(accountID: ConnectorAccountID, context _: ConnectorContext) async throws { try await transport.authenticate(accountID: accountID) }
    public func refresh(endpoint _: SourceEndpoint, cursor: ConnectorCursor?, context _: ConnectorContext) async throws -> ConnectorRefreshPage {
        let afterUID = try? cursor?.decode(UInt64.self)
        let page = try await transport.fetch(folder: "INBOX", afterUID: afterUID ?? nil, limit: 100)
        let candidates = page.messages.map { message in
            ConnectorItemCandidate(externalID: message.messageID ?? "\(message.uidValidity):\(message.uid)", title: message.subject, author: message.from, publishedAt: message.date, contentHTML: message.html, contentText: message.plainText)
        }
        return ConnectorRefreshPage(candidates: candidates, nextCursor: try page.nextUID.map { try ConnectorCursor(family: "imap-uid-v1", value: $0) }, reachedEnd: page.reachedEnd)
    }
    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { await transport.health() }
    public func disconnect(accountID _: ConnectorAccountID) async throws { await transport.disconnect() }
}

public struct IMAPFeasibilityResult: Codable, Hashable, Sendable {
    public var implementationID: String
    public var server: String
    public var tls: Bool
    public var authentication: Bool
    public var uidValidity: Bool
    public var pagination: Bool
    public var idleOrPolling: Bool
    public var reconnect: Bool
    public var mime: Bool
    public var concurrencyAndCancellation: Bool

    public var passed: Bool { tls && authentication && uidValidity && pagination && idleOrPolling && reconnect && mime && concurrencyAndCancellation }
}
