import CrosscurrentDomain
import Foundation

public actor GitHubConnector: Connector {
    public nonisolated let kind: ConnectorKind = .github
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .pagination, .fullContent, .engagementMetrics, .backgroundRefresh]
    private let http: any ConnectorHTTPClient

    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) { self.http = http }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        guard input.url.host?.lowercased() == "github.com" else { throw ConnectorError.unsupportedInput }
        let parts = input.url.pathComponents.filter { $0 != "/" }
        guard let owner = parts.first else { throw ConnectorError.unsupportedInput }
        if parts.count >= 2 {
            let repositoryName = parts[1].replacingOccurrences(of: ".git", with: "")
            let response = try await http.get(URL(string: "https://api.github.com/repos/\(owner)/\(repositoryName)")!, headers: Self.headers)
            let value = try Self.decoder.decode(Repository.self, from: response.data)
            return makeDiscovery(name: value.fullName, summary: value.description, avatarURL: value.owner.avatarURL.flatMap(URL.init(string:)), externalID: value.fullName.lowercased(), canonicalURL: URL(string: value.htmlURL), sourceKind: .repository, entityKind: .organization, accountID: input.accountID)
        }

        let response = try await http.get(URL(string: "https://api.github.com/users/\(owner)")!, headers: Self.headers)
        let value = try Self.decoder.decode(User.self, from: response.data)
        let displayName = value.name?.isEmpty == false ? value.name! : value.login
        return makeDiscovery(name: displayName, summary: value.bio, avatarURL: value.avatarURL.flatMap(URL.init(string:)), externalID: value.login.lowercased(), canonicalURL: URL(string: value.htmlURL), sourceKind: value.type == "Organization" ? .organization : .person, entityKind: value.type == "Organization" ? .organization : .person, accountID: input.accountID)
    }

    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}

    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage {
        let page = max(1, (try? cursor?.decode(Int.self)) ?? 1)
        let endpointParts = endpoint.externalID.split(separator: "#", maxSplits: 1).map(String.init)
        let identity = endpointParts[0]
        let mode = endpointParts.count == 2 ? endpointParts[1] : "activity"
        let parts = identity.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 2, mode == "releases" {
            let url = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases?per_page=20&page=\(page)")!
            let response = try await http.get(url, headers: Self.headers)
            let releases = try Self.decoder.decode([Release].self, from: response.data)
            let candidates = releases.map { release in
                ConnectorItemCandidate(
                    externalID: "release:\(release.id)",
                    canonicalURL: URL(string: release.htmlURL),
                    title: release.name?.isEmpty == false ? release.name! : release.tagName,
                    author: release.author?.login,
                    publishedAt: release.publishedAt ?? release.createdAt,
                    modifiedAt: release.updatedAt,
                    summary: release.body,
                    contentText: release.body,
                    topicNames: ["release", release.tagName]
                )
            }
            return ConnectorRefreshPage(candidates: candidates, nextCursor: try ConnectorCursor(family: "github-release-page-v1", value: page + 1), reachedEnd: releases.count < 20)
        }
        let url: URL
        if parts.count == 2 {
            url = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/events?per_page=50&page=\(page)")!
        } else {
            url = URL(string: "https://api.github.com/users/\(identity)/events/public?per_page=50&page=\(page)")!
        }
        let response = try await http.get(url, headers: Self.headers)
        let events = try Self.decoder.decode([Event].self, from: response.data)
        let candidates = events.compactMap { event -> ConnectorItemCandidate? in
            let repository = event.repo?.name ?? endpoint.externalID
            let title = Self.title(for: event, repository: repository)
            guard !title.isEmpty else { return nil }
            let targetURL = URL(string: "https://github.com/\(repository)")
            return ConnectorItemCandidate(
                externalID: event.id,
                canonicalURL: targetURL,
                title: title,
                author: event.actor?.displayLogin ?? event.actor?.login,
                publishedAt: event.createdAt,
                summary: event.type.replacingOccurrences(of: "Event", with: ""),
                contentText: event.payload?.commits?.compactMap(\.message).joined(separator: "\n"),
                metricSnapshots: event.payload?.size.map { [.init(kind: .score, value: Double($0), connectorKey: "commit_count", capturedAt: context.now())] } ?? []
            )
        }
        return ConnectorRefreshPage(candidates: candidates, nextCursor: try ConnectorCursor(family: "github-page-v1", value: page + 1), reachedEnd: events.count < 50)
    }

    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}

    private func makeDiscovery(name: String, summary: String?, avatarURL: URL?, externalID: String, canonicalURL: URL?, sourceKind: SourceKind, entityKind: EntityKind, accountID: ConnectorAccountID?) -> ConnectorDiscoveryResult {
        let revisionID = SourceRevisionID()
        let source = LogicalSource(currentRevisionID: revisionID, kind: sourceKind)
        let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: name, summary: summary, avatarURL: avatarURL)
        let entity = Entity(kind: entityKind, displayName: name)
        let endpoints: [SourceEndpoint]
        if sourceKind == .repository {
            endpoints = [
                SourceEndpoint(sourceID: source.id, connector: .github, accountID: accountID, externalID: "\(externalID)#releases", canonicalURL: canonicalURL?.appending(path: "releases"), accessRequirement: .anonymous, contentPrivacy: .public),
                SourceEndpoint(sourceID: source.id, connector: .github, accountID: accountID, externalID: "\(externalID)#activity", canonicalURL: canonicalURL, accessRequirement: .anonymous, contentPrivacy: .public),
            ]
        } else {
            endpoints = [SourceEndpoint(sourceID: source.id, connector: .github, accountID: accountID, externalID: externalID, canonicalURL: canonicalURL, accessRequirement: .anonymous, contentPrivacy: .public)]
        }
        return ConnectorDiscoveryResult(
            source: source,
            sourceRevision: revision,
            endpoints: endpoints,
            entityCandidates: [entity],
            sourceEntityRelationships: [.init(sourceID: source.id, entityID: entity.id, role: .represents, provenance: .connector, confidence: .certain)],
            aiClassification: .init(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain),
            coverageCandidate: .init(sourceID: source.id, ecosystem: .globalFocused, provenance: .connector, confidence: Confidence(0.6))
        )
    }

    private static let headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func title(for event: Event, repository: String) -> String {
        switch event.type {
        case "PushEvent":
            let message = event.payload?.commits?.first?.message?.split(separator: "\n").first.map(String.init)
            return message.map { "\($0) — \(repository)" } ?? "New commits in \(repository)"
        case "ReleaseEvent": return "New release in \(repository)"
        case "IssuesEvent": return "Issue updated in \(repository)"
        case "PullRequestEvent": return "Pull request updated in \(repository)"
        case "CreateEvent": return "Created \(event.payload?.refType ?? "ref") in \(repository)"
        default: return event.type.isEmpty ? "" : "\(event.type.replacingOccurrences(of: "Event", with: "")) in \(repository)"
        }
    }

    private struct Repository: Decodable {
        struct Owner: Decodable { var avatarURL: String?; enum CodingKeys: String, CodingKey { case avatarURL = "avatar_url" } }
        var fullName: String; var description: String?; var htmlURL: String; var owner: Owner
        enum CodingKeys: String, CodingKey { case fullName = "full_name"; case description; case htmlURL = "html_url"; case owner }
    }
    private struct User: Decodable {
        var login: String; var name: String?; var bio: String?; var avatarURL: String?; var htmlURL: String; var type: String
        enum CodingKeys: String, CodingKey { case login, name, bio, type; case avatarURL = "avatar_url"; case htmlURL = "html_url" }
    }
    private struct Release: Decodable {
        struct Author: Decodable { var login: String? }
        var id: Int
        var name: String?
        var tagName: String
        var body: String?
        var htmlURL: String
        var createdAt: Date?
        var publishedAt: Date?
        var updatedAt: Date?
        var author: Author?
        enum CodingKeys: String, CodingKey {
            case id, name, body, author
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case createdAt = "created_at"
            case publishedAt = "published_at"
            case updatedAt = "updated_at"
        }
    }
    private struct Event: Decodable {
        struct Actor: Decodable { var login: String?; var displayLogin: String?; enum CodingKeys: String, CodingKey { case login; case displayLogin = "display_login" } }
        struct Repository: Decodable { var name: String }
        struct Payload: Decodable {
            struct Commit: Decodable { var message: String? }
            var size: Int?; var commits: [Commit]?; var refType: String?
            enum CodingKeys: String, CodingKey { case size, commits; case refType = "ref_type" }
        }
        var id: String; var type: String; var actor: Actor?; var repo: Repository?; var payload: Payload?; var createdAt: Date?
        enum CodingKeys: String, CodingKey { case id, type, actor, repo, payload; case createdAt = "created_at" }
    }
}

public actor RedditConnector: Connector {
    public nonisolated let kind: ConnectorKind = .reddit
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .pagination, .fullContent, .deletionSignals, .engagementMetrics, .backgroundRefresh]
    private let http: any ConnectorHTTPClient
    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) { self.http = http }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        guard input.url.host?.lowercased().hasSuffix("reddit.com") == true else { throw ConnectorError.unsupportedInput }
        let parts = input.url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "r" else { throw ConnectorError.unsupportedInput }
        let subreddit = parts[1]
        let revisionID = SourceRevisionID(); let source = LogicalSource(currentRevisionID: revisionID, kind: .community)
        let endpointURL = URL(string: "https://www.reddit.com/r/\(subreddit)/new.json")!
        let endpoint = SourceEndpoint(sourceID: source.id, connector: .reddit, externalID: subreddit.lowercased(), canonicalURL: endpointURL, contentPrivacy: .public)
        return ConnectorDiscoveryResult(source: source, sourceRevision: .init(id: revisionID, sourceID: source.id, displayName: "r/\(subreddit)"), endpoints: [endpoint], aiClassification: .init(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain), coverageCandidate: .init(sourceID: source.id, ecosystem: .globalFocused, provenance: .connector, confidence: Confidence(0.5)))
    }
    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}
    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage {
        let after = try? cursor?.decode(String?.self)
        var components = URLComponents(string: "https://www.reddit.com/r/\(endpoint.externalID)/new.json")!
        components.queryItems = [.init(name: "limit", value: "50")] + ((after ?? nil).map { [.init(name: "after", value: $0)] } ?? [])
        let response = try await http.get(components.url!, headers: ["Accept": "application/json"])
        let listing = try JSONDecoder().decode(Listing.self, from: response.data)
        let candidates = listing.data.children.map { wrapper in
            let post = wrapper.data
            return ConnectorItemCandidate(
                externalID: post.name,
                canonicalURL: URL(string: "https://www.reddit.com\(post.permalink)"),
                title: post.title,
                author: post.author,
                publishedAt: Date(timeIntervalSince1970: post.createdUTC),
                summary: post.selftext,
                contentText: post.selftext,
                metricSnapshots: [
                    .init(kind: .score, value: Double(post.score), capturedAt: context.now()),
                    .init(kind: .comments, value: Double(post.numComments), capturedAt: context.now()),
                ],
                deletionState: post.removedByCategory == nil ? .available : .deleted
            )
        }
        return ConnectorRefreshPage(candidates: candidates, nextCursor: try ConnectorCursor(family: "reddit-after-v1", value: listing.data.after), reachedEnd: listing.data.after == nil)
    }
    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}

    private struct Listing: Decodable {
        struct DataValue: Decodable {
            struct Child: Decodable {
                struct Post: Decodable {
                    var name: String; var title: String; var author: String?; var createdUTC: TimeInterval; var selftext: String?; var permalink: String; var score: Int; var numComments: Int; var removedByCategory: String?
                    enum CodingKeys: String, CodingKey { case name, title, author, selftext, permalink, score; case createdUTC = "created_utc"; case numComments = "num_comments"; case removedByCategory = "removed_by_category" }
                }
                var data: Post
            }
            var children: [Child]; var after: String?
        }
        var data: DataValue
    }
}

public actor BlueskyConnector: Connector {
    public nonisolated let kind: ConnectorKind = .bluesky
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .pagination, .fullContent, .engagementMetrics, .backgroundRefresh]
    private let http: any ConnectorHTTPClient
    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) { self.http = http }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        guard input.url.host?.lowercased() == "bsky.app" else { throw ConnectorError.unsupportedInput }
        let parts = input.url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "profile" else { throw ConnectorError.unsupportedInput }
        let actor = parts[1]
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile")!
        components.queryItems = [.init(name: "actor", value: actor)]
        let response = try await http.get(components.url!, headers: [:])
        let profile = try Self.decoder.decode(Profile.self, from: response.data)
        let displayName = profile.displayName?.isEmpty == false ? profile.displayName! : profile.handle
        let revisionID = SourceRevisionID(); let source = LogicalSource(currentRevisionID: revisionID, kind: .person)
        let entity = Entity(kind: .person, displayName: displayName)
        let endpointURL = URL(string: "https://bsky.app/profile/\(profile.did)")!
        let endpoint = SourceEndpoint(sourceID: source.id, connector: .bluesky, externalID: profile.did, canonicalURL: endpointURL, contentPrivacy: .public)
        return ConnectorDiscoveryResult(source: source, sourceRevision: .init(id: revisionID, sourceID: source.id, displayName: displayName, summary: profile.description, avatarURL: profile.avatar.flatMap(URL.init(string:))), endpoints: [endpoint], entityCandidates: [entity], sourceEntityRelationships: [.init(sourceID: source.id, entityID: entity.id, role: .represents, provenance: .connector, confidence: .certain)], aiClassification: .init(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain), coverageCandidate: .init(sourceID: source.id, ecosystem: .globalFocused, provenance: .connector, confidence: Confidence(0.5)))
    }
    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}
    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage {
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed")!
        var query: [URLQueryItem] = [.init(name: "actor", value: endpoint.externalID), .init(name: "limit", value: "50"), .init(name: "filter", value: "posts_and_author_threads")]
        if let cursorValue = try? cursor?.decode(String.self) { query.append(.init(name: "cursor", value: cursorValue)) }
        components.queryItems = query
        let response = try await http.get(components.url!, headers: [:])
        let page = try Self.decoder.decode(FeedPage.self, from: response.data)
        let candidates = page.feed.map { entry in
            let post = entry.post
            let rkey = post.uri.split(separator: "/").last.map(String.init) ?? post.cid
            return ConnectorItemCandidate(
                externalID: post.uri,
                canonicalURL: URL(string: "https://bsky.app/profile/\(post.author.did)/post/\(rkey)"),
                title: post.record.text.split(separator: "\n").first.map(String.init) ?? post.record.text,
                author: post.author.displayName ?? post.author.handle,
                publishedAt: post.record.createdAt,
                contentText: post.record.text,
                languageCode: post.record.langs?.first,
                metricSnapshots: [
                    .init(kind: .likes, value: Double(post.likeCount ?? 0), capturedAt: context.now()),
                    .init(kind: .reposts, value: Double(post.repostCount ?? 0), capturedAt: context.now()),
                    .init(kind: .replies, value: Double(post.replyCount ?? 0), capturedAt: context.now()),
                ]
            )
        }
        return ConnectorRefreshPage(candidates: candidates, nextCursor: try page.cursor.map { try ConnectorCursor(family: "atproto-cursor-v1", value: $0) }, reachedEnd: page.cursor == nil)
    }
    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct Profile: Decodable { var did: String; var handle: String; var displayName: String?; var description: String?; var avatar: String? }
    private struct FeedPage: Decodable {
        struct Entry: Decodable {
            struct Post: Decodable {
                struct Author: Decodable { var did: String; var handle: String; var displayName: String? }
                struct Record: Decodable { var text: String; var createdAt: Date; var langs: [String]? }
                var uri: String; var cid: String; var author: Author; var record: Record; var likeCount: Int?; var repostCount: Int?; var replyCount: Int?
            }
            var post: Post
        }
        var feed: [Entry]; var cursor: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            feed = try container.decode([Entry].self, forKey: .feed)
            cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        }
        private enum CodingKeys: String, CodingKey { case feed, cursor }
    }
}
