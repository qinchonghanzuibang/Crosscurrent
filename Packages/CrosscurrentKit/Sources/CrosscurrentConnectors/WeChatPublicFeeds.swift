import CrosscurrentDomain
import Foundation
import SwiftSoup

public enum WeChatPublicFeedContent {
    public static func originalArticleURL(_ url: URL) -> URL? {
        if WeChatArticleValidator.isAllowedArticleURL(url) { return WeChatArticleIdentity.canonicalize(url) }
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              WeChatCatalogID.allCases.contains(where: { $0.feedHost == url.host?.lowercased() }),
              ["/link-proxy", "/link-proxy/"].contains(url.path),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let original = components.queryItems?.first(where: { ["u", "url"].contains($0.name) })?.value,
              let result = URL(string: original), WeChatArticleValidator.isAllowedArticleURL(result)
        else { return nil }
        return WeChatArticleIdentity.canonicalize(result)
    }

    public static func isComplete(_ html: String) -> Bool {
        guard case .article = WeChatArticleValidator.assessProviderHTML(html),
              let document = try? SwiftSoup.parse(html),
              let body = document.body(), let text = try? body.text() else { return false }
        let hasImages = (try? body.select("img[src], img[data-src]").contains { image in
            let value = (try? image.attr("data-src")).flatMap { $0.isEmpty ? nil : $0 } ?? ((try? image.attr("src")) ?? "")
            guard let url = URL(string: value) else { return false }
            return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
        }) ?? false
        return hasImages || (text.count >= 80 && ((try? body.select("p, article, section, div, pre, table").count) ?? 0) > 0)
    }

    /// Recover only official media from known public proxy wrappers; never reuse their signing query.
    public static func originalMediaURL(_ url: URL) -> URL? {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              WeChatCatalogID.allCases.contains(where: { $0.feedHost == url.host?.lowercased() }),
              ["/img-proxy", "/img-proxy/"].contains(url.path),
              let original = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value,
              var result = URLComponents(string: original), result.user == nil, result.password == nil, result.port == nil,
              ["http", "https"].contains(result.scheme ?? ""),
              ["mmbiz.qpic.cn", "mmbiz.qlogo.cn", "wx.qlogo.cn"].contains(result.host?.lowercased() ?? "")
        else { return nil }
        result.scheme = "https"
        return result.url
    }
}

struct WeChatQualifiedPublicFeed: Sendable {
    var candidate: WeChatPublicFeedCandidate
    var account: WeChatAccountIdentity
    var aliases: [String]
    var qualifiedAt: Date
}

public struct WeChatSourceRefreshResult: Sendable {
    public var candidates: [ConnectorItemCandidate]
    public var endpoints: [SourceEndpoint]
    public var performedRemoteRequest: Bool
    public var succeeded: Bool

    public init(candidates: [ConnectorItemCandidate], endpoints: [SourceEndpoint], performedRemoteRequest: Bool, succeeded: Bool) {
        self.candidates = candidates
        self.endpoints = endpoints
        self.performedRemoteRequest = performedRemoteRequest
        self.succeeded = succeeded
    }
}

extension WeChatConnector {
    func publicFeedDiscovery(url: URL, catalog: WeChatCatalogID, context: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let response = try await publicHTTP.get(url, headers: ["Accept": "application/rss+xml,application/atom+xml"])
        guard response.statusCode == 200, catalog.accepts(feedURL: response.finalURL) else { throw ConnectorError.temporarilyUnavailable }
        let metadata = try FeedConnector.metadata(data: response.data)
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 512 else { throw ConnectorError.invalidResponse("Public feed has no valid publisher name") }
        let candidate = WeChatPublicFeedCandidate(displayName: title, feedURL: response.finalURL, catalog: catalog, description: metadata.summary)
        let qualified = try await qualify(candidate, now: context.now(), prefetched: response)
        guard var discovery = try Self.discoveryResult(for: qualified.account) else { throw ConnectorError.unsupportedInput }
        discovery.sourceRevision.summary = metadata.summary
        discovery.endpoints = [Self.publicEndpoint(qualified, sourceID: discovery.source.id)]
        discovery.display = .init(category: "WeChat Official Account")
        return discovery
    }

    func searchPublicCatalogs(query: String, context: ConnectorContext) async throws -> [ConnectorDiscoveryResult] {
        var matches: [WeChatPublicFeedCandidate] = []
        for catalog in catalogs {
            try? await catalog.refreshIfNeeded()
            matches += await catalog.search(query: query)
        }
        // Name grouping bounds discovery traffic; only verified aliases merge persistent endpoints.
        let groups = Dictionary(grouping: matches, by: { Self.normalizedName($0.displayName) })
        let orderedNames = groups.keys.sorted {
            let l = Self.matchRank($0, query: query), r = Self.matchRank($1, query: query)
            return l == r ? $0 < $1 : l < r
        }
        var results: [ConnectorDiscoveryResult] = []
        for name in orderedNames.prefix(8) {
            for candidate in (groups[name] ?? []).sorted(by: { $0.catalog.priority < $1.catalog.priority }) {
                guard let qualified = try? await qualify(candidate, now: context.now()),
                      var discovery = try Self.discoveryResult(for: qualified.account) else { continue }
                let overlap = results.firstIndex { result in
                    result.endpoints.contains { !Set($0.weChatAcquisition?.accountAliases ?? []).isDisjoint(with: qualified.aliases) }
                }
                if let overlap {
                    let endpoint = Self.publicEndpoint(qualified, sourceID: results[overlap].source.id)
                    if !results[overlap].endpoints.contains(where: { $0.canonicalURL == endpoint.canonicalURL }) {
                        results[overlap].endpoints.append(endpoint)
                    }
                } else {
                    discovery.endpoints = [Self.publicEndpoint(qualified, sourceID: discovery.source.id)]
                    discovery.display = .init(category: "WeChat Official Account")
                    results.append(discovery)
                }
            }
        }
        return results
    }

    public func qualifyFreeEndpoints(for endpoints: [SourceEndpoint], displayName: String) async -> [SourceEndpoint] {
        guard let first = endpoints.first else { return endpoints }
        let now = Date.now
        if endpoints.compactMap({ $0.weChatAcquisition?.lastCatalogCheck }).max().map({ now.timeIntervalSince($0) < 24 * 60 * 60 }) == true {
            return endpoints
        }
        var output = endpoints
        let aliases = Set(endpoints.flatMap { Self.account(from: $0).accountAliases + ($0.weChatAcquisition?.accountAliases ?? []) })
        for catalog in catalogs {
            try? await catalog.refreshIfNeeded()
            for candidate in (await catalog.search(query: displayName)).prefix(8) {
                guard !output.contains(where: { $0.canonicalURL == candidate.feedURL }),
                      let qualified = try? await qualify(candidate, now: now),
                      !aliases.isDisjoint(with: qualified.aliases) else { continue }
                output.append(Self.publicEndpoint(qualified, sourceID: first.sourceID))
            }
        }
        // Persist retrofit-attempt timing even on network failure to avoid launch-time fan-out.
        for index in output.indices {
            if output[index].weChatAcquisition == nil {
                output[index].weChatAcquisition = .init(providerID: "jizhila", priority: 2,
                    accountAliases: Self.account(from: output[index]).accountAliases, displayName: displayName)
            }
            output[index].weChatAcquisition?.lastCatalogCheck = now
        }
        return output
    }

    private func qualify(_ candidate: WeChatPublicFeedCandidate, now: Date, prefetched: ConnectorHTTPResponse? = nil) async throws -> WeChatQualifiedPublicFeed {
        if prefetched == nil, let cached = qualifiedFeeds[candidate.feedURL], now.timeIntervalSince(cached.qualifiedAt) < 30 * 60 { return cached }
        guard candidate.catalog.accepts(feedURL: candidate.feedURL) else { throw ConnectorError.unsupportedInput }
        let response: ConnectorHTTPResponse
        if let prefetched { response = prefetched }
        else { response = try await publicHTTP.get(candidate.feedURL, headers: ["Accept": "application/rss+xml,application/atom+xml"]) }
        guard response.statusCode == 200, candidate.catalog.accepts(feedURL: response.finalURL) else { throw ConnectorError.temporarilyUnavailable }
        let items = try FeedConnector.parseItems(data: response.data)
        var aliases: Set<String> = []
        var identities: [String: Int] = [:]
        var account: WeChatAccountIdentity?
        for item in items.prefix(25) {
            guard let raw = item.canonicalURL, let url = WeChatPublicFeedContent.originalArticleURL(raw) else { continue }
            if let biz = Self.queryValue("__biz", url: url), !biz.isEmpty {
                identities[biz, default: 0] += 1
            }
        }
        // A syndicated article in a feed must not establish publisher equivalence.
        if let primary = identities.max(by: { $0.value < $1.value }), primary.value * 2 > identities.values.reduce(0, +) {
            aliases.insert("wechat-account-biz:\(primary.key)")
            account = .init(displayName: candidate.displayName, biz: primary.key, provenance: .init(providerID: candidate.catalog.rawValue))
        }
        if account == nil, identities.isEmpty {
            // Short official URLs require public metadata. Bound this to three articles per feed.
            for item in items.prefix(3) {
                guard let raw = item.canonicalURL, let url = WeChatPublicFeedContent.originalArticleURL(raw),
                      let response = try? await official.fetch(url),
                      case let .article(html) = WeChatArticleValidator.assess(response),
                      var resolved = Self.publicIdentity(from: html, articleURL: response.finalURL), resolved.stableExternalID != nil else { continue }
                resolved.displayName = candidate.displayName
                account = resolved
                aliases.formUnion(resolved.accountAliases)
                break
            }
        }
        guard let account, !aliases.isEmpty else { throw ConnectorError.invalidResponse("Public feed account identity is unavailable") }
        let qualified = WeChatQualifiedPublicFeed(candidate: candidate, account: account, aliases: aliases.sorted(), qualifiedAt: now)
        qualifiedFeeds[candidate.feedURL] = qualified
        return qualified
    }

    private static func publicEndpoint(_ qualified: WeChatQualifiedPublicFeed, sourceID: SourceID) -> SourceEndpoint {
        SourceEndpoint(sourceID: sourceID, connector: .weChatOfficialAccount,
            externalID: qualified.account.stableExternalID! + ":feed:" + qualified.candidate.catalog.rawValue,
            canonicalURL: qualified.candidate.feedURL, accessRequirement: .anonymous, contentPrivacy: .public,
            weChatAcquisition: .init(providerID: qualified.candidate.catalog.rawValue, priority: qualified.candidate.catalog.priority,
                accountAliases: qualified.aliases, currentBiz: qualified.account.biz, displayName: qualified.account.displayName))
    }

    public func refreshSource(endpoints: [SourceEndpoint], context: ConnectorContext, manual: Bool) async -> WeChatSourceRefreshResult {
        let now = context.now()
        var output = endpoints
        var candidates: [ConnectorItemCandidate] = []
        var didRequest = false
        var succeeded = false
        var migratedAliases: Set<String> = []
        var migratedBiz: String?
        let freeIndices = output.indices.filter { output[$0].weChatAcquisition.flatMap { WeChatCatalogID(rawValue: $0.providerID) } != nil }
            .sorted { (output[$0].weChatAcquisition?.priority ?? 99) < (output[$1].weChatAcquisition?.priority ?? 99) }
        for index in freeIndices {
            var endpoint = output[index]
            guard let metadata = endpoint.weChatAcquisition, let catalog = WeChatCatalogID(rawValue: metadata.providerID),
                  let url = endpoint.canonicalURL, catalog.accepts(feedURL: url) else { continue }
            let auditDue = endpoint.lastSuccessfulSync.map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
            if succeeded && !auditDue { continue }
            if metadata.retryAfter.map({ $0 > now }) == true { continue }
            if !manual, !succeeded, endpoint.health == .healthy,
               endpoint.lastSuccessfulSync.map({ now.timeIntervalSince($0) < refreshTTL }) == true {
                succeeded = true
                continue
            }
            var headers = ["Accept": "application/rss+xml,application/atom+xml,application/feed+json"]
            if let etag = metadata.etag { headers["If-None-Match"] = etag }
            if let lastModified = metadata.lastModified { headers["If-Modified-Since"] = lastModified }
            endpoint.weChatAcquisition?.lastAttempt = now
            didRequest = true
            do {
                let response = try await publicHTTP.get(url, headers: headers)
                guard catalog.accepts(feedURL: response.finalURL), [200, 304].contains(response.statusCode) else { throw ConnectorError.temporarilyUnavailable }
                if response.statusCode == 200 {
                    let parsed = try FeedConnector.parseItems(data: response.data)
                    let acquired = await publicCandidates(parsed, account: Self.account(from: endpoint), aliases: metadata.accountAliases, catalog: catalog)
                    let resolved = acquired.candidates
                    guard parsed.isEmpty || !resolved.isEmpty else { throw ConnectorError.invalidResponse("Feed has no allowed WeChat articles") }
                    candidates += Array(resolved.prefix(initialBackfillLimit))
                    endpoint.weChatAcquisition?.accountAliases = Array(Set(metadata.accountAliases).union(acquired.verifiedAliases)).sorted()
                    if let currentBiz = acquired.currentBiz { endpoint.weChatAcquisition?.currentBiz = currentBiz }
                    if !acquired.verifiedAliases.isEmpty {
                        migratedAliases.formUnion(acquired.verifiedAliases)
                        migratedBiz = acquired.currentBiz
                    }
                    endpoint.weChatAcquisition?.etag = Self.header("ETag", response: response)
                    endpoint.weChatAcquisition?.lastModified = Self.header("Last-Modified", response: response)
                } else if endpoint.lastSuccessfulSync == nil {
                    throw ConnectorError.invalidResponse("Uncached feed returned 304")
                }
                endpoint.health = .healthy
                endpoint.lastSuccessfulSync = now
                endpoint.weChatAcquisition?.retryAfter = nil
                if index != freeIndices.first { endpoint.weChatAcquisition?.lastAudit = now }
                succeeded = true
            } catch {
                endpoint.health = .temporarilyUnavailable
                let retry: TimeInterval
                if case let ConnectorError.rateLimited(after) = error { retry = max(15 * 60, after ?? 0) }
                else { retry = 30 * 60 }
                endpoint.weChatAcquisition?.retryAfter = now.addingTimeInterval(retry)
            }
            output[index] = endpoint
        }
        if !migratedAliases.isEmpty {
            for index in output.indices where output[index].weChatAcquisition != nil {
                let aliases = Set(output[index].weChatAcquisition?.accountAliases ?? []).union(migratedAliases)
                output[index].weChatAcquisition?.accountAliases = Array(aliases).sorted()
                output[index].weChatAcquisition?.currentBiz = migratedBiz
            }
        }
        if !succeeded, !freeIndices.isEmpty,
           !output.contains(where: { $0.weChatAcquisition?.providerID == "jizhila" || $0.weChatAcquisition == nil }),
           await provider.healthCheck() == .configured, let first = output.first {
            let account = Self.account(from: first)
            if let identity = account.stableExternalID {
                output.append(SourceEndpoint(sourceID: first.sourceID, connector: .weChatOfficialAccount,
                    externalID: identity, contentPrivacy: .public,
                    weChatAcquisition: .init(providerID: "jizhila", priority: 2, accountAliases: account.accountAliases, displayName: account.displayName)))
            }
        }
        if !succeeded, let index = output.indices.first(where: { output[$0].weChatAcquisition?.providerID == "jizhila" || output[$0].weChatAcquisition == nil }) {
            var endpoint = output[index]
            if endpoint.weChatAcquisition == nil {
                endpoint.weChatAcquisition = .init(providerID: "jizhila", priority: 2, accountAliases: Self.account(from: endpoint).accountAliases)
            }
            if endpoint.weChatAcquisition?.retryAfter.map({ $0 > now }) != true {
                if await provider.healthCheck() == .configured {
                    do {
                        var cursor: ConnectorCursor?
                        var acquired = 0
                        var remote = false
                        var paidPages = 0
                        repeat {
                            paidPages += 1
                            let page: ConnectorRefreshPage
                            let account = Self.account(from: endpoint)
                            if account.ghid == nil, account.historyURL == nil, account.biz != nil, endpoint.lastSuccessfulSync == nil {
                                let posts = try await provider.fetchDailyPosts(account: account)
                                page = .init(candidates: posts.map { Self.connectorCandidate($0, account: account) }, reachedEnd: true)
                            } else { page = try await refresh(endpoint: endpoint, cursor: cursor, context: context) }
                            let bounded = Array(page.candidates.prefix(initialBackfillLimit - acquired))
                            candidates += bounded
                            acquired += bounded.count
                            remote = remote || page.performedRemoteRequest
                            cursor = page.reachedEnd || page.candidates.isEmpty ? nil : page.nextCursor
                        } while cursor != nil && acquired < initialBackfillLimit && paidPages < 10
                        didRequest = didRequest || remote
                        endpoint.health = .healthy
                        if remote { endpoint.lastSuccessfulSync = now; endpoint.weChatAcquisition?.lastAttempt = now }
                        endpoint.weChatAcquisition?.retryAfter = nil
                        succeeded = true
                    } catch {
                        didRequest = true
                        endpoint.health = .temporarilyUnavailable
                        endpoint.weChatAcquisition?.lastAttempt = now
                        endpoint.weChatAcquisition?.retryAfter = now.addingTimeInterval(refreshTTL)
                    }
                } else { endpoint.health = .configurationRequired }
            }
            output[index] = endpoint
        }
        var union: [ConnectorItemCandidate] = []
        var positions: [String: Int] = [:]
        for candidate in candidates {
            if let position = positions[candidate.externalID] {
                if let html = candidate.contentHTML, WeChatPublicFeedContent.isComplete(html),
                   html.count > (union[position].contentHTML?.count ?? 0) {
                    union[position].contentHTML = html
                    union[position].acquisitionProvenance = candidate.acquisitionProvenance
                }
            } else {
                positions[candidate.externalID] = union.count
                union.append(candidate)
            }
        }
        if endpoints.allSatisfy({ $0.lastSuccessfulSync == nil }) {
            for index in union.indices { union[index].isInitialBackfill = true }
        }
        return .init(candidates: union, endpoints: output, performedRemoteRequest: didRequest, succeeded: succeeded)
    }

    private func publicCandidates(_ entries: [ConnectorItemCandidate], account: WeChatAccountIdentity, aliases: [String], catalog: WeChatCatalogID) async -> (candidates: [ConnectorItemCandidate], verifiedAliases: Set<String>, currentBiz: String?) {
        var output: [ConnectorItemCandidate] = []
        var verifiedAliases: Set<String> = []
        var currentBiz: String?
        for var entry in entries.prefix(initialBackfillLimit) {
            guard let raw = entry.canonicalURL, var url = WeChatPublicFeedContent.originalArticleURL(raw) else { continue }
            entry.weChatOriginalURL = url
            var html: String?
            if Self.queryValue("__biz", url: url) == nil,
               let response = try? await official.fetch(url), case let .article(body) = WeChatArticleValidator.assess(response) {
                url = WeChatArticleIdentity.canonicalize(response.finalURL)
                html = body
                if Self.queryValue("mid", url: url) == nil,
                   let biz = Self.scriptValue(named: "biz", in: body),
                   let mid = Self.scriptValue(named: "mid", in: body),
                   let idx = Self.scriptValue(named: "idx", in: body) {
                    var canonical = URLComponents(string: "https://mp.weixin.qq.com/s")!
                    canonical.queryItems = [.init(name: "__biz", value: biz), .init(name: "mid", value: mid), .init(name: "idx", value: idx)]
                    if let sn = Self.scriptValue(named: "sn", in: body) { canonical.queryItems?.append(.init(name: "sn", value: sn)) }
                    url = canonical.url!
                }
            }
            var identity = account
            identity.biz = Self.queryValue("__biz", url: url) ?? identity.biz
            if let biz = identity.biz, !aliases.contains("wechat-account-biz:\(biz)") {
                // Only a stable official ghid corroborates a changed biz; a mixed feed alone does not.
                guard let ghid = account.ghid, let response = try? await official.fetch(url),
                      case let .article(body) = WeChatArticleValidator.assess(response),
                      Self.publicIdentity(from: body, articleURL: response.finalURL)?.ghid == ghid else { continue }
                verifiedAliases.insert("wechat-account-biz:\(biz)")
            }
            if output.isEmpty { currentBiz = identity.biz }
            let post = WeChatPostCandidate(title: entry.title, articleURL: url,
                appmsgid: Self.queryValue("mid", url: url) ?? Self.queryValue("appmsgid", url: url),
                position: (Self.queryValue("idx", url: url) ?? Self.queryValue("position", url: url)).flatMap(Int.init),
                sn: Self.queryValue("sn", url: url), provenance: .init(providerID: catalog.rawValue))
            entry.externalID = WeChatArticleIdentity.externalID(account: identity, post: post)
            entry.canonicalURL = url
            entry.author = account.displayName
            entry.languageCode = "zh-Hans"
            entry.contentHTML = html ?? entry.contentHTML ?? entry.summary.flatMap { $0.count >= 800 && WeChatPublicFeedContent.isComplete($0) ? $0 : nil }
            entry.acquisitionProvenance = html == nil ? (catalog == .wechat2rss ? .wechat2rssPublicFeed : .bestBlogsWechat2RSS) : .officialHTTP
            output.append(entry)
        }
        return (output, verifiedAliases, currentBiz)
    }

    private static func queryValue(_ name: String, url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func header(_ name: String, response: ConnectorHTTPResponse) -> String? {
        response.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
    }

    private static func matchRank(_ name: String, query: String) -> Int {
        let query = normalizedName(query)
        return name == query ? 0 : (name.hasPrefix(query) ? 1 : 2)
    }
}
