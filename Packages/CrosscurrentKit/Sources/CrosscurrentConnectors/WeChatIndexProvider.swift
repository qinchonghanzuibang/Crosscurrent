import Foundation

public struct WeChatProviderProvenance: Codable, Hashable, Sendable {
    public var providerID: String
    public var providerRecordID: String?

    public init(providerID: String, providerRecordID: String? = nil) {
        self.providerID = providerID
        self.providerRecordID = providerRecordID
    }
}

public struct WeChatAccountIdentity: Codable, Hashable, Sendable {
    public var displayName: String
    public var ghid: String?
    public var wxid: String?
    public var biz: String?
    public var avatarURL: URL?
    public var description: String?
    public var owner: String?
    public var verification: String?
    public var historyURL: URL?
    public var provenance: WeChatProviderProvenance

    public init(
        displayName: String,
        ghid: String? = nil,
        wxid: String? = nil,
        biz: String? = nil,
        avatarURL: URL? = nil,
        description: String? = nil,
        owner: String? = nil,
        verification: String? = nil,
        historyURL: URL? = nil,
        provenance: WeChatProviderProvenance
    ) {
        self.displayName = displayName
        self.ghid = ghid
        self.wxid = wxid
        self.biz = biz
        self.avatarURL = avatarURL
        self.description = description
        self.owner = owner
        self.verification = verification
        self.historyURL = historyURL
        self.provenance = provenance
    }

    public var stableExternalID: String? {
        if let ghid = Self.nonempty(ghid) { return "wechat-account:\(ghid.lowercased())" }
        if let wxid = Self.nonempty(wxid) { return "wechat-account-wxid:\(wxid.lowercased())" }
        if let biz = Self.nonempty(biz) { return "wechat-account-biz:\(biz)" }
        return nil
    }

    /// Durable provider-independent aliases; a name or feed address is never an account identity.
    public var accountAliases: [String] {
        [Self.nonempty(ghid).map { "wechat-account:\($0.lowercased())" },
         Self.nonempty(wxid).map { "wechat-account-wxid:\($0.lowercased())" },
         Self.nonempty(biz).map { "wechat-account-biz:\($0)" }].compactMap { $0 }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public struct WeChatPostCandidate: Codable, Hashable, Sendable {
    public var title: String
    public var digest: String?
    public var articleURL: URL
    public var coverURL: URL?
    public var publishedAt: Date?
    public var appmsgid: String?
    public var position: Int?
    public var sn: String?
    public var originalFlag: Int?
    public var itemShowType: Int?
    public var provenance: WeChatProviderProvenance

    public init(title: String, digest: String? = nil, articleURL: URL, coverURL: URL? = nil, publishedAt: Date? = nil, appmsgid: String? = nil, position: Int? = nil, sn: String? = nil, originalFlag: Int? = nil, itemShowType: Int? = nil, provenance: WeChatProviderProvenance) {
        self.title = title
        self.digest = digest
        self.articleURL = articleURL
        self.coverURL = coverURL
        self.publishedAt = publishedAt
        self.appmsgid = appmsgid
        self.position = position
        self.sn = sn
        self.originalFlag = originalFlag
        self.itemShowType = itemShowType
        self.provenance = provenance
    }
}

public struct WeChatHistoryCursor: Codable, Hashable, Sendable {
    public var offset: String

    public init(offset: String) { self.offset = offset }
}

public struct WeChatHistoryPage: Codable, Hashable, Sendable {
    public var posts: [WeChatPostCandidate]
    public var nextCursor: WeChatHistoryCursor?
    public var reachedEnd: Bool

    public init(posts: [WeChatPostCandidate], nextCursor: WeChatHistoryCursor? = nil, reachedEnd: Bool) {
        self.posts = posts
        self.nextCursor = nextCursor
        self.reachedEnd = reachedEnd
    }
}

public struct WeChatProviderArticle: Codable, Hashable, Sendable {
    public var html: String
    public var title: String?
    public var canonicalURL: URL?
    public var provenance: WeChatProviderProvenance

    public init(html: String, title: String? = nil, canonicalURL: URL? = nil, provenance: WeChatProviderProvenance) {
        self.html = html
        self.title = title
        self.canonicalURL = canonicalURL
        self.provenance = provenance
    }
}

public enum WeChatProviderHealth: Codable, Hashable, Sendable {
    case configured
    case missingConfiguration
    case quotaExhausted
    case temporarilyUnavailable
}

public protocol WeChatIndexProvider: Sendable {
    func searchAccounts(query: String) async throws -> [WeChatAccountIdentity]
    func resolveAccount(articleURL: URL) async throws -> WeChatAccountIdentity
    func fetchDailyPosts(account: WeChatAccountIdentity) async throws -> [WeChatPostCandidate]
    func fetchHistory(account: WeChatAccountIdentity, cursor: WeChatHistoryCursor?, limit: Int) async throws -> WeChatHistoryPage
    func fetchArticleHTML(articleURL: URL) async throws -> WeChatProviderArticle?
    func healthCheck() async -> WeChatProviderHealth
}

public struct WeChatProviderCredentials: Equatable, Sendable {
    public var apiKey: String
    public var verificationCode: String?

    public init(apiKey: String, verificationCode: String? = nil) {
        self.apiKey = apiKey
        self.verificationCode = verificationCode
    }
}

public struct WeChatProviderRequest: Sendable {
    public var url: URL
    public var body: Data

    public init(url: URL, body: Data) {
        self.url = url
        self.body = body
    }
}

public struct WeChatProviderHTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol WeChatProviderTransport: Sendable {
    func send(_ request: WeChatProviderRequest) async throws -> WeChatProviderHTTPResponse
}

public actor URLSessionWeChatProviderTransport: WeChatProviderTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: WeChatProviderRequest) async throws -> WeChatProviderHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Crosscurrent/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse("not an HTTP response") }
        guard data.count <= 20 * 1_024 * 1_024 else { throw ConnectorError.invalidResponse("provider response exceeded size limit") }
        return WeChatProviderHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

public actor JizhilaWeChatIndexProvider: WeChatIndexProvider {
    public static let baseURL = URL(string: "https://www.dajiala.com")!

    private struct CachedSearch: Sendable {
        var accounts: [WeChatAccountIdentity]
        var expiresAt: Date
    }

    fileprivate enum Operation {
        case search, articleInfo, daily, history, articleHTML
    }

    private let credentials: @Sendable () async throws -> WeChatProviderCredentials?
    private let transport: any WeChatProviderTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let searchCacheTTL: TimeInterval
    private let minimumRequestInterval: TimeInterval
    private var searchCache: [String: CachedSearch] = [:]
    private var lastRequestAt: Date?

    public init(
        credentials: @escaping @Sendable () async throws -> WeChatProviderCredentials?,
        transport: any WeChatProviderTransport = URLSessionWeChatProviderTransport(),
        searchCacheTTL: TimeInterval = 10 * 60,
        minimumRequestInterval: TimeInterval = 0.6,
        now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.25) }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.searchCacheTTL = max(1, searchCacheTTL)
        self.minimumRequestInterval = max(0, minimumRequestInterval)
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
    }

    public func searchAccounts(query: String) async throws -> [WeChatAccountIdentity] {
        let key = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        if let cached = searchCache[key], cached.expiresAt > now() { return cached.accounts }
        try Task.checkCancellation()
        let data = try await perform(
            path: "/fbmain/monitor/v3/web_search",
            body: [
                "mode": 2, "keyword": query, "BusinessType": 1, "Sub_search_type": 1,
                "offset": 0, "currentPage": 1, "cookies_buffer": "",
            ],
            operation: .search
        )
        try Task.checkCancellation()
        let accounts = try JizhilaWeChatResponseDecoder.searchAccounts(from: data)
        searchCache[key] = CachedSearch(accounts: accounts, expiresAt: now().addingTimeInterval(searchCacheTTL))
        return accounts
    }

    public func resolveAccount(articleURL: URL) async throws -> WeChatAccountIdentity {
        let data = try await perform(
            path: "/fbmain/monitor/v3/article_info",
            body: ["url": articleURL.absoluteString],
            operation: .articleInfo
        )
        return try JizhilaWeChatResponseDecoder.articleAccount(from: data, articleURL: articleURL)
    }

    public func fetchDailyPosts(account: WeChatAccountIdentity) async throws -> [WeChatPostCandidate] {
        var body: [String: Any] = ["page": 1]
        if let biz = account.biz, !biz.isEmpty { body["biz"] = biz }
        else if let ghid = account.ghid, !ghid.isEmpty { body["name"] = ghid }
        else { body["name"] = account.displayName }
        let data = try await perform(path: "/fbmain/monitor/v3/post_condition", body: body, operation: .daily)
        return try JizhilaWeChatResponseDecoder.posts(from: data)
    }

    public func fetchHistory(account: WeChatAccountIdentity, cursor: WeChatHistoryCursor?, limit: Int) async throws -> WeChatHistoryPage {
        let ghid = account.ghid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let historyURL = account.historyURL?.absoluteString ?? ""
        guard !ghid.isEmpty || !historyURL.isEmpty else { throw ConnectorError.accountUnavailable }
        let data = try await perform(
            path: "/fbmain/monitor/v3/post_history",
            body: ["ghid": ghid, "url": ghid.isEmpty ? historyURL : "", "offset": cursor?.offset ?? ""],
            operation: .history
        )
        return try JizhilaWeChatResponseDecoder.historyPage(from: data, limit: max(1, limit))
    }

    public func fetchArticleHTML(articleURL: URL) async throws -> WeChatProviderArticle? {
        let data = try await perform(
            path: "/fbmain/monitor/v3/article_html",
            body: ["url": articleURL.absoluteString],
            operation: .articleHTML
        )
        return try JizhilaWeChatResponseDecoder.article(from: data)
    }

    public func healthCheck() async -> WeChatProviderHealth {
        do {
            guard let value = try await credentials(), !value.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missingConfiguration
            }
            return .configured
        } catch {
            return .temporarilyUnavailable
        }
    }

    private func perform(path: String, body: [String: Any], operation: Operation) async throws -> Data {
        guard let credential = try await credentials(), !credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorError.configurationRequired("Configure the WeChat Index API key in Settings.")
        }
        var requestBody = body
        requestBody["key"] = credential.apiKey
        requestBody["verifycode"] = credential.verificationCode ?? ""
        let encoded = try JSONSerialization.data(withJSONObject: requestBody, options: [.sortedKeys])
        let url = Self.baseURL.appending(path: path)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                try await waitForRateSlot()
                let response = try await transport.send(.init(url: url, body: encoded))
                try JizhilaWeChatResponseDecoder.validate(response: response, operation: operation.decoderOperation)
                return response.data
            } catch {
                guard attempt < 3, Self.isTransient(error) else { throw error }
                let retryAfter: TimeInterval? = if case let ConnectorError.rateLimited(value) = error { value } else { nil }
                let base = retryAfter.map { max(0.5, min(30, $0)) } ?? min(5.0, pow(2, Double(attempt - 1)) * 0.5)
                let seconds = base + max(0, min(0.25, jitter()))
                try await sleep(.milliseconds(Int64(seconds * 1_000)))
            }
        }
    }

    private func waitForRateSlot() async throws {
        if let lastRequestAt {
            let remaining = minimumRequestInterval - now().timeIntervalSince(lastRequestAt)
            if remaining > 0 { try await sleep(.milliseconds(Int64(remaining * 1_000))) }
        }
        lastRequestAt = now()
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case ConnectorError.rateLimited = error { return true }
        if case ConnectorError.transientHTTP = error { return true }
        if case ConnectorError.temporarilyUnavailable = error { return true }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
        }
        return false
    }
}

private extension JizhilaWeChatIndexProvider.Operation {
    var decoderOperation: JizhilaWeChatResponseDecoder.Operation {
        switch self {
        case .search: .search
        case .articleInfo: .articleInfo
        case .daily: .daily
        case .history: .history
        case .articleHTML: .articleHTML
        }
    }
}

public enum JizhilaWeChatResponseDecoder {
    public enum Operation: Sendable { case search, articleInfo, daily, history, articleHTML }

    public static func validate(response: WeChatProviderHTTPResponse, operation: Operation) throws {
        if response.statusCode == 429 { throw ConnectorError.rateLimited(retryAfter: 5) }
        if (500...599).contains(response.statusCode) {
            throw ConnectorError.transientHTTP(statusCode: response.statusCode, retryAfter: nil)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.invalidResponse("provider HTTP \(response.statusCode)")
        }
        guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let code = integer(root["code"])
        else { return }
        guard code != 0 else { return }
        switch code {
        case -1:
            throw ConnectorError.rateLimited(retryAfter: 5)
        case 10002:
            throw ConnectorError.configurationRequired("The WeChat Index API key or verification code is invalid.")
        case 20001:
            throw ConnectorError.quotaExhausted
        case 2003, 2005, 50000:
            throw ConnectorError.temporarilyUnavailable
        default:
            break
        }
        switch operation {
        case .history where [101, 104, 30001].contains(code):
            throw ConnectorError.accountUnavailable
        case .articleInfo where [105, 106, 107].contains(code):
            throw ConnectorError.articleUnavailable(definitive: true)
        case .articleInfo where [103, 104].contains(code):
            throw ConnectorError.rateLimited(retryAfter: 2)
        case .articleHTML where [101].contains(code):
            throw ConnectorError.articleUnavailable(definitive: true)
        case .articleHTML where [105, 106, 107].contains(code):
            throw ConnectorError.temporarilyUnavailable
        default:
            throw ConnectorError.invalidResponse("provider code \(code)")
        }
    }

    public static func searchAccounts(from data: Data) throws -> [WeChatAccountIdentity] {
        let root = try JSONSerialization.jsonObject(with: data)
        var values: [WeChatAccountIdentity] = []
        walk(root) { dictionary in
            guard let jump = dictionary["jumpInfo"] as? [String: Any],
                  let displayName = string(jump, keys: ["nickName", "nickname"]),
                  !displayName.isEmpty
            else { return }
            let ghid = string(jump, keys: ["userName", "username"])
            let wxid = string(jump, keys: ["aliasName", "alias"])
            let rawBiz = scalarString(jump["bizuin"])
            let source = dictionary["source"] as? [String: Any]
            let owner = source.flatMap { string($0, keys: ["title"]) }
            let external = string(jump, keys: ["externalInfo"])
            let avatar = safeURL(string(jump, keys: ["headHDImgUrl", "headImgUrl"]) ?? string(dictionary, keys: ["iconUrl"]))
            values.append(
                WeChatAccountIdentity(
                    displayName: displayName,
                    ghid: ghid,
                    wxid: wxid,
                    biz: normalizedBiz(rawBiz),
                    avatarURL: avatar,
                    description: string(dictionary, keys: ["desc", "description"]),
                    owner: owner,
                    verification: external,
                    provenance: .init(providerID: "jizhila", providerRecordID: ghid)
                )
            )
        }
        var seen = Set<String>()
        return values.filter { value in
            guard let stable = value.stableExternalID else { return false }
            return seen.insert(stable).inserted
        }
    }

    public static func articleAccount(from data: Data, articleURL: URL) throws -> WeChatAccountIdentity {
        let root = try dictionary(from: data)
        guard let entry = (root["data"] as? [[String: Any]])?.first,
              let name = string(entry, keys: ["wx_name", "nickname"]),
              let ghid = string(entry, keys: ["ghid", "gh_id"])
        else { throw ConnectorError.invalidResponse("article_info omitted account identity") }
        let biz = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "__biz" })?.value
        return WeChatAccountIdentity(
            displayName: name,
            ghid: ghid,
            wxid: string(entry, keys: ["wxid"]),
            biz: biz,
            avatarURL: safeURL(string(entry, keys: ["wx_head_img", "mp_head_img"])),
            description: string(entry, keys: ["summary", "signature"]),
            provenance: .init(providerID: "jizhila", providerRecordID: ghid)
        )
    }

    public static func posts(from data: Data) throws -> [WeChatPostCandidate] {
        let root = try dictionary(from: data)
        guard let rows = root["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap(post(from:))
    }

    public static func historyPage(from data: Data, limit: Int) throws -> WeChatHistoryPage {
        let root = try dictionary(from: data)
        let all = (root["data"] as? [[String: Any]] ?? []).compactMap(post(from:))
        let posts = Array(all.prefix(max(1, limit)))
        let isEnd = integer(root["is_end"]).map { $0 != 0 } ?? false
        let offset = string(root, keys: ["offset"])
        let reachedEnd = isEnd || posts.count >= limit || offset?.isEmpty != false
        return WeChatHistoryPage(
            posts: posts,
            nextCursor: reachedEnd ? nil : offset.map(WeChatHistoryCursor.init(offset:)),
            reachedEnd: reachedEnd
        )
    }

    public static func article(from data: Data) throws -> WeChatProviderArticle? {
        let root = try dictionary(from: data)
        guard let payload = root["data"] as? [String: Any],
              let html = string(payload, keys: ["html"]),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return WeChatProviderArticle(
            html: html,
            title: string(payload, keys: ["title"]),
            canonicalURL: safeURL(string(payload, keys: ["article_url"])),
            provenance: .init(providerID: "jizhila", providerRecordID: string(payload, keys: ["sn"]))
        )
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.invalidResponse("provider response was not an object")
        }
        return root
    }

    private static func post(from row: [String: Any]) -> WeChatPostCandidate? {
        guard let title = string(row, keys: ["title"]),
              let rawURL = string(row, keys: ["url", "article_url"]),
              let articleURL = safeURL(rawURL.replacingOccurrences(of: "&amp;", with: "&"))
        else { return nil }
        let appmsgid = scalarString(row["appmsgid"])
        let sn = string(row, keys: ["sn"])
        return WeChatPostCandidate(
            title: title,
            digest: string(row, keys: ["digest", "summary"]),
            articleURL: articleURL,
            coverURL: safeURL(string(row, keys: ["cover_url", "cover"])),
            publishedAt: integer(row["post_time"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            appmsgid: appmsgid,
            position: integer(row["position"] ?? row["idx"]),
            sn: sn,
            originalFlag: integer(row["original"] ?? row["copyright_stat"]),
            itemShowType: integer(row["item_show_type"] ?? row["type"]),
            provenance: .init(providerID: "jizhila", providerRecordID: appmsgid ?? sn)
        )
    }

    private static func walk(_ value: Any, visit: ([String: Any]) -> Void) {
        if let dictionary = value as? [String: Any] {
            visit(dictionary)
            for child in dictionary.values { walk(child, visit: visit) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, visit: visit) }
        }
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func normalizedBiz(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.allSatisfy(\.isNumber) { return Data(value.utf8).base64EncodedString() }
        return value
    }

    private static func safeURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let normalized = value.hasPrefix("http://") ? "https://" + value.dropFirst("http://".count) : value
        guard let url = URL(string: String(normalized)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
