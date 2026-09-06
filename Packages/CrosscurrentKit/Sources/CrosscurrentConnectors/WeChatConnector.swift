import CryptoKit
import CrosscurrentDomain
import Foundation
import SwiftSoup

public enum WeChatArticleIdentity {
    public static func externalID(account: WeChatAccountIdentity, post: WeChatPostCandidate) -> String {
        let accountID = account.biz ?? account.ghid?.lowercased() ?? account.wxid?.lowercased() ?? "unknown"
        if let appmsgid = nonempty(post.appmsgid), let position = post.position {
            return "wechat-article:\(accountID):\(appmsgid):\(position)"
        }
        if let sn = nonempty(post.sn) {
            return "wechat-article:\(accountID):sn:\(sn.lowercased())"
        }
        let canonical = canonicalize(post.articleURL).absoluteString
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "wechat-article:\(accountID):url:\(hash)"
    }

    public static func canonicalize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        let volatile: Set<String> = [
            "chksm", "scene", "sessionid", "subscene", "clicktime", "enterid", "ascene", "devicetype",
            "version", "nettype", "lang", "exportkey", "pass_ticket", "wx_header", "mpshare", "from",
            "isappinstalled", "sharer_shareinfo", "sharer_shareinfo_first", "source", "timestamp",
            "token", "access_token", "api_key", "apikey", "password", "secret", "authorization", "rss_token",
        ]
        components.queryItems = components.queryItems?
            .filter { !volatile.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
            .sorted { lhs, rhs in lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public struct WeChatOfficialArticleResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var finalURL: URL

    public init(data: Data, statusCode: Int, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public protocol WeChatOfficialArticleLoading: Sendable {
    func fetch(_ url: URL) async throws -> WeChatOfficialArticleResponse
}

private final class WeChatRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(WeChatArticleValidator.isAllowedArticleURL) == true ? request : nil)
    }
}

public actor URLSessionWeChatOfficialArticleLoader: WeChatOfficialArticleLoading {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: WeChatRedirectDelegate(), delegateQueue: nil)
    }

    public func fetch(_ url: URL) async throws -> WeChatOfficialArticleResponse {
        guard WeChatArticleValidator.isAllowedArticleURL(url) else { throw ConnectorError.unsupportedInput }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        request.setValue("text/html,application/xhtml+xml;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("Crosscurrent/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw ConnectorError.invalidResponse("not an HTTP response")
        }
        guard data.count <= 20 * 1_024 * 1_024 else { throw ConnectorError.invalidResponse("article exceeded size limit") }
        return WeChatOfficialArticleResponse(data: data, statusCode: http.statusCode, finalURL: finalURL)
    }
}

public enum WeChatArticleAssessment: Equatable, Sendable {
    case article(String)
    case definitelyUnavailable
    case abnormal
}

public enum WeChatArticleValidator {
    public static func isAllowedArticleURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "mp.weixin.qq.com" && (url.port == nil || url.port == 443 || url.port == 80)
            && (url.path == "/s" || url.path.hasPrefix("/s/"))
    }

    public static func assess(_ response: WeChatOfficialArticleResponse) -> WeChatArticleAssessment {
        guard (200..<300).contains(response.statusCode), isAllowedArticleURL(response.finalURL) else {
            return [404, 410].contains(response.statusCode) ? .definitelyUnavailable : .abnormal
        }
        return assessHTML(String(decoding: response.data, as: UTF8.self), requiresOfficialBody: true)
    }

    public static func assessProviderHTML(_ html: String) -> WeChatArticleAssessment {
        assessHTML(html, requiresOfficialBody: false)
    }

    private static func assessHTML(_ html: String, requiresOfficialBody: Bool) -> WeChatArticleAssessment {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= 120 else { return .abnormal }
        let normalized = trimmed.lowercased()
        let unavailableMarkers = [
            "该内容已被发布者删除", "此内容因违规无法查看", "已停止访问该网页", "公众号已迁移",
            "the content has been deleted", "content is unavailable",
        ]
        if unavailableMarkers.contains(where: normalized.contains) { return .definitelyUnavailable }
        let verificationMarkers = [
            "请输入验证码", "环境异常", "访问过于频繁", "verify you are human", "captcha", "waf_captcha",
        ]
        if verificationMarkers.contains(where: normalized.contains) { return .abnormal }
        if requiresOfficialBody,
           !normalized.contains("id=\"js_content\"") && !normalized.contains("id='js_content'") && !normalized.contains("rich_media_content") {
            return .abnormal
        }
        return .article(trimmed)
    }
}

public actor WeChatArticleFetcher {
    private let official: any WeChatOfficialArticleLoading
    private let provider: any WeChatIndexProvider

    public init(official: any WeChatOfficialArticleLoading, provider: any WeChatIndexProvider) {
        self.official = official
        self.provider = provider
    }

    public func enrich(_ candidate: ConnectorItemCandidate) async throws -> ConnectorItemCandidate {
        try Task.checkCancellation()
        guard let url = candidate.canonicalURL else { return candidate }
        var definitiveUnavailable = false
        do {
            switch WeChatArticleValidator.assess(try await official.fetch(url)) {
            case let .article(html):
                var output = candidate
                output.contentHTML = html
                output.acquisitionProvenance = .officialHTTP
                return output
            case .definitelyUnavailable:
                definitiveUnavailable = true
            case .abnormal:
                break
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // Public HTTP failure falls through to the provider; it never requests browser authentication.
        }

        if [.wechat2rssPublicFeed, .bestBlogsWechat2RSS].contains(candidate.acquisitionProvenance),
           let html = candidate.contentHTML, WeChatPublicFeedContent.isComplete(html) {
            return candidate
        }

        do {
            if let article = try await provider.fetchArticleHTML(articleURL: url) {
                switch WeChatArticleValidator.assessProviderHTML(article.html) {
                case let .article(html):
                    var output = candidate
                    output.contentHTML = html
                    output.acquisitionProvenance = .providerFallback
                    if let title = article.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { output.title = title }
                    return output
                case .definitelyUnavailable:
                    definitiveUnavailable = true
                case .abnormal:
                    break
                }
            }
        } catch ConnectorError.articleUnavailable(definitive: true) {
            definitiveUnavailable = true
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // Metadata remains valid evidence when both content routes are temporarily unavailable.
        }

        var output = candidate
        if definitiveUnavailable { output.deletionState = .unavailable }
        return output
    }
}

public actor WeChatConnector: QueryDiscoveringConnector {
    public nonisolated let kind: ConnectorKind = .weChatOfficialAccount
    public nonisolated let capabilities: ConnectorCapabilities = [
        .discovery, .queryDiscovery, .deltaSync, .pagination, .fullContent, .backgroundRefresh,
    ]

    private struct InitialHistoryCursor: Codable, Hashable, Sendable {
        var providerCursor: WeChatHistoryCursor
        var accumulated: Int
    }

    let provider: any WeChatIndexProvider
    let official: any WeChatOfficialArticleLoading
    private let articleFetcher: WeChatArticleFetcher
    let refreshTTL: TimeInterval
    let initialBackfillLimit: Int
    let catalogs: [any WeChatPublicFeedCatalog]
    let publicHTTP: any ConnectorHTTPClient
    var qualifiedFeeds: [URL: WeChatQualifiedPublicFeed] = [:]

    public init(
        provider: any WeChatIndexProvider,
        official: any WeChatOfficialArticleLoading = URLSessionWeChatOfficialArticleLoader(),
        catalogs: [any WeChatPublicFeedCatalog] = [],
        publicHTTP: any ConnectorHTTPClient = AnonymousPublicWeChatHTTPClient(),
        refreshTTL: TimeInterval = 4 * 60 * 60,
        initialBackfillLimit: Int = 25
    ) {
        self.provider = provider
        self.official = official
        self.catalogs = catalogs
        self.publicHTTP = publicHTTP
        articleFetcher = WeChatArticleFetcher(official: official, provider: provider)
        self.refreshTTL = max(5 * 60, refreshTTL)
        self.initialBackfillLimit = max(20, min(30, initialBackfillLimit))
    }

    public func search(query: String, context: ConnectorContext) async throws -> [ConnectorDiscoveryResult] {
        try await searchPublicCatalogs(query: query, context: context)
    }

    public func searchMore(query: String, context _: ConnectorContext) async throws -> [ConnectorDiscoveryResult] {
        try await provider.searchAccounts(query: query).compactMap { try Self.discoveryResult(for: $0) }
    }

    public func discover(input: ConnectorDiscoveryInput, context: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        if let catalog = WeChatCatalogID.allCases.first(where: { $0.accepts(feedURL: input.url) }) {
            return try await publicFeedDiscovery(url: input.url, catalog: catalog, context: context)
        }
        guard WeChatArticleValidator.isAllowedArticleURL(input.url) else { throw ConnectorError.unsupportedInput }
        var resolved: WeChatAccountIdentity?
        if let response = try? await official.fetch(input.url),
           case let .article(html) = WeChatArticleValidator.assess(response) {
            resolved = Self.publicIdentity(from: html, articleURL: response.finalURL)
        }
        if resolved?.stableExternalID == nil {
            let providerIdentity = try await provider.resolveAccount(articleURL: input.url)
            resolved = Self.merging(resolved, with: providerIdentity)
        }
        guard let resolved, let result = try Self.discoveryResult(for: resolved) else {
            throw ConnectorError.invalidResponse("Official Account identity was incomplete")
        }
        return result
    }

    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {
        throw ConnectorError.unsupportedInput
    }

    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage {
        if endpoint.weChatAcquisition?.providerID != nil,
           WeChatCatalogID(rawValue: endpoint.weChatAcquisition!.providerID) != nil {
            let result = await refreshSource(endpoints: [endpoint], context: context, manual: false)
            guard result.succeeded else { throw ConnectorError.temporarilyUnavailable }
            return ConnectorRefreshPage(candidates: result.candidates, reachedEnd: true, performedRemoteRequest: result.performedRemoteRequest)
        }
        var account = Self.account(from: endpoint)
        if endpoint.lastSuccessfulSync == nil || cursor?.family == "wechat-initial-history-v1" {
            let state = try cursor?.decode(InitialHistoryCursor.self)
            let accumulated = state?.accumulated ?? 0
            let remaining = max(0, initialBackfillLimit - accumulated)
            guard remaining > 0 else { return ConnectorRefreshPage(candidates: [], reachedEnd: true) }
            let page = try await provider.fetchHistory(account: account, cursor: state?.providerCursor, limit: remaining)
            let candidates = page.posts.map { Self.connectorCandidate($0, account: account) }
            let total = accumulated + candidates.count
            let completed = total >= initialBackfillLimit || page.reachedEnd || page.nextCursor == nil
            let next = try completed ? nil : page.nextCursor.map {
                try ConnectorCursor(family: "wechat-initial-history-v1", value: InitialHistoryCursor(providerCursor: $0, accumulated: total))
            }
            return ConnectorRefreshPage(candidates: candidates, nextCursor: next, reachedEnd: completed)
        }

        if let last = endpoint.lastSuccessfulSync, context.now().timeIntervalSince(last) < refreshTTL {
            return ConnectorRefreshPage(candidates: [], reachedEnd: true, performedRemoteRequest: false)
        }
        if account.biz == nil, account.ghid == nil, let historyURL = account.historyURL {
            account = try await provider.resolveAccount(articleURL: historyURL)
        }
        let posts = try await provider.fetchDailyPosts(account: account)
        return ConnectorRefreshPage(candidates: posts.map { Self.connectorCandidate($0, account: account) }, reachedEnd: true)
    }

    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate {
        try await articleFetcher.enrich(candidate)
    }

    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth {
        if !catalogs.isEmpty { return .healthy }
        return switch await provider.healthCheck() {
        case .configured: .healthy
        case .missingConfiguration: .configurationRequired
        case .quotaExhausted: .configurationRequired
        case .temporarilyUnavailable: .temporarilyUnavailable
        }
    }

    public func disconnect(accountID _: ConnectorAccountID) async throws {}

    static func discoveryResult(for account: WeChatAccountIdentity) throws -> ConnectorDiscoveryResult? {
        guard let externalID = account.stableExternalID else { return nil }
        let revisionID = SourceRevisionID()
        let source = LogicalSource(currentRevisionID: revisionID, kind: .organization)
        let revision = SourceRevision(
            id: revisionID,
            sourceID: source.id,
            displayName: account.displayName,
            summary: account.description,
            avatarURL: account.avatarURL
        )
        let entityRevisionID = EntityRevisionID()
        let entity = Entity(currentRevisionID: entityRevisionID, kind: .organization, displayName: account.displayName, isFollowed: false)
        let endpoint = SourceEndpoint(
            sourceID: source.id,
            connector: .weChatOfficialAccount,
            externalID: externalID,
            canonicalURL: profileURL(biz: account.biz),
            accessRequirement: .anonymous,
            contentPrivacy: .public,
            weChatAcquisition: .init(providerID: "jizhila", priority: 2, accountAliases: account.accountAliases, displayName: account.displayName)
        )
        let detail = [account.verification, account.owner, account.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return ConnectorDiscoveryResult(
            source: source,
            sourceRevision: revision,
            endpoints: [endpoint],
            entityCandidates: [entity],
            sourceEntityRelationships: [
                SourceEntityRelationship(sourceID: source.id, entityID: entity.id, role: .represents, provenance: .connector, confidence: .certain),
            ],
            aiClassification: SourceAIClassification(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain),
            coverageCandidate: SourceCoverageAssertion(sourceID: source.id, ecosystem: .chinaFocused, provenance: .connector, confidence: Confidence(0.9)),
            display: ConnectorDiscoveryDisplay(category: "WeChat Official Account", identity: account.wxid, detail: detail)
        )
    }

    static func connectorCandidate(_ post: WeChatPostCandidate, account: WeChatAccountIdentity) -> ConnectorItemCandidate {
        ConnectorItemCandidate(
            externalID: WeChatArticleIdentity.externalID(account: account, post: post),
            canonicalURL: WeChatArticleIdentity.canonicalize(post.articleURL),
            title: post.title,
            author: account.displayName,
            publishedAt: post.publishedAt,
            summary: post.digest,
            languageCode: "zh-Hans"
        )
    }

    public static func account(from endpoint: SourceEndpoint) -> WeChatAccountIdentity {
        if let metadata = endpoint.weChatAcquisition, !metadata.accountAliases.isEmpty {
            func value(_ prefix: String) -> String? {
                metadata.accountAliases.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }
            return WeChatAccountIdentity(displayName: metadata.displayName ?? "WeChat Official Account",
                ghid: value("wechat-account:"), wxid: value("wechat-account-wxid:"), biz: metadata.currentBiz ?? value("wechat-account-biz:"),
                provenance: .init(providerID: metadata.providerID))
        }
        let ghid: String?
        let wxid: String?
        let externalID = endpoint.externalID
        if externalID.hasPrefix("wechat-account:") {
            ghid = String(externalID.dropFirst("wechat-account:".count))
            wxid = nil
        } else if externalID.hasPrefix("wechat-account-wxid:") {
            ghid = nil
            wxid = String(externalID.dropFirst("wechat-account-wxid:".count))
        } else if externalID.hasPrefix("gh_") {
            ghid = externalID
            wxid = nil
        } else {
            ghid = nil
            let digest = SHA256.hash(data: Data(externalID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            wxid = "legacy-\(digest)"
        }
        let biz = endpoint.canonicalURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "__biz" })?.value
        }
        let historyURL = endpoint.canonicalURL.flatMap { url in
            let path = url.path.lowercased()
            return WeChatArticleValidator.isAllowedArticleURL(url) && (path == "/s" || path.hasPrefix("/s/")) ? url : nil
        }
        return WeChatAccountIdentity(
            displayName: ghid ?? wxid ?? "WeChat Official Account",
            ghid: ghid,
            wxid: wxid,
            biz: biz,
            historyURL: historyURL,
            provenance: .init(providerID: "persisted")
        )
    }

    private static func profileURL(biz: String?) -> URL? {
        guard let biz, !biz.isEmpty else { return nil }
        var components = URLComponents(string: "https://mp.weixin.qq.com/mp/profile_ext")
        components?.queryItems = [URLQueryItem(name: "__biz", value: biz), URLQueryItem(name: "scene", value: "124")]
        return components?.url
    }

    static func publicIdentity(from html: String, articleURL: URL) -> WeChatAccountIdentity? {
        let document = try? SwiftSoup.parse(html, articleURL.absoluteString)
        let displayName = firstText(document, selectors: ["#js_name", ".rich_media_meta_nickname", "meta[property=og:article:author]"])
            ?? scriptValue(named: "nickname", in: html)
        let ghid = scriptValue(named: "user_name", in: html) ?? scriptValue(named: "userName", in: html)
        let queryBiz = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "__biz" })?.value
        let biz = scriptValue(named: "biz", in: html) ?? queryBiz
        guard let displayName, !displayName.isEmpty else { return nil }
        return WeChatAccountIdentity(
            displayName: displayName,
            ghid: ghid,
            biz: biz,
            description: firstText(document, selectors: ["meta[name=description]", "meta[property=og:description]"]),
            provenance: .init(providerID: "official-public-http")
        )
    }

    private static func firstText(_ document: Document?, selectors: [String]) -> String? {
        for selector in selectors {
            guard let element = try? document?.select(selector).first() else { continue }
            let value: String
            if element.tagName() == "meta" { value = (try? element.attr("content")) ?? "" }
            else { value = (try? element.text()) ?? "" }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func scriptValue(named name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:var\\s+)?\(escaped)\\s*[:=]\\s*[\\\"']([^\\\"']+)[\\\"']"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range]).replacingOccurrences(of: "\\x26", with: "&")
    }

    private static func merging(_ publicValue: WeChatAccountIdentity?, with providerValue: WeChatAccountIdentity) -> WeChatAccountIdentity {
        WeChatAccountIdentity(
            displayName: publicValue?.displayName ?? providerValue.displayName,
            ghid: publicValue?.ghid ?? providerValue.ghid,
            wxid: publicValue?.wxid ?? providerValue.wxid,
            biz: publicValue?.biz ?? providerValue.biz,
            avatarURL: publicValue?.avatarURL ?? providerValue.avatarURL,
            description: publicValue?.description ?? providerValue.description,
            owner: publicValue?.owner ?? providerValue.owner,
            verification: publicValue?.verification ?? providerValue.verification,
            historyURL: publicValue?.historyURL ?? providerValue.historyURL,
            provenance: providerValue.provenance
        )
    }
}
