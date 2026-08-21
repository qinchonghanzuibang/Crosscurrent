import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation
import WebKit

@MainActor
public enum BrowserCreatorDOMExtractor {
    public static func discover(platform: AuthenticatedCreatorPlatform, in webView: WKWebView) async throws -> BrowserCreatorIdentity {
        let snapshot = try await snapshot(platform: platform, in: webView)
        guard !snapshot.creatorID.isEmpty, !snapshot.displayName.isEmpty, !snapshot.loginRequired else {
            throw ConnectorError.authenticationRequired
        }
        let page = try page(from: snapshot, prior: BrowserDOMCursor())
        return BrowserCreatorIdentity(
            stableCreatorID: snapshot.creatorID,
            displayName: snapshot.displayName,
            profileURL: URL(string: snapshot.profileURL) ?? webView.url ?? URL(string: "about:blank")!,
            biography: snapshot.biography,
            entityKind: platform == .weChatOfficialAccount ? .organization : .person,
            recentItems: page.candidates,
            nextCursor: page.nextCursor
        )
    }

    public static func refresh(platform: AuthenticatedCreatorPlatform, cursor: ConnectorCursor?, in webView: WKWebView) async throws -> ConnectorRefreshPage {
        let prior = (try? cursor?.decode(BrowserDOMCursor.self)) ?? BrowserDOMCursor()
        _ = try await webView.callAsyncJavaScript("window.scrollTo({top: document.documentElement.scrollHeight, behavior: 'instant'}); return true", arguments: [:], in: nil, contentWorld: .world(name: "CrosscurrentCreator"))
        try await Task.sleep(for: .milliseconds(700))
        let snapshot = try await snapshot(platform: platform, in: webView)
        guard !snapshot.loginRequired else { throw ConnectorError.authenticationRequired }
        return try page(from: snapshot, prior: prior)
    }

    public static func loginURL(for platform: AuthenticatedCreatorPlatform) -> URL {
        switch platform {
        case .weChatOfficialAccount: URL(string: "https://mp.weixin.qq.com/")!
        case .xiaohongshu: URL(string: "https://www.xiaohongshu.com/explore")!
        case .x: URL(string: "https://x.com/login")!
        case .weibo: URL(string: "https://weibo.com/")!
        case .zhihu: URL(string: "https://www.zhihu.com/signin")!
        }
    }

    private static func page(from snapshot: DOMSnapshot, prior: BrowserDOMCursor) throws -> ConnectorRefreshPage {
        var seen = prior.seenExternalIDs
        let fresh = snapshot.items.filter { seen.insert($0.externalID).inserted }.map { item in
            ConnectorItemCandidate(
                externalID: item.externalID,
                canonicalURL: URL(string: item.url),
                title: item.title,
                author: item.author ?? snapshot.displayName,
                publishedAt: item.publishedAt.flatMap(Self.date),
                summary: item.summary,
                contentText: item.summary,
                metricSnapshots: item.metrics.compactMap { key, value in
                    Self.metricKind(key).map { ConnectorMetric(kind: $0, value: value, connectorKey: key) }
                }
            )
        }
        if seen.count > 2_000 { seen = Set(seen.sorted().suffix(2_000)) }
        let next = BrowserDOMCursor(seenExternalIDs: seen, scrollCount: prior.scrollCount + 1)
        return ConnectorRefreshPage(
            candidates: fresh,
            nextCursor: try ConnectorCursor(family: "browser-dom-v1", value: next),
            reachedEnd: fresh.isEmpty && prior.scrollCount > 0
        )
    }

    private static func snapshot(platform: AuthenticatedCreatorPlatform, in webView: WKWebView) async throws -> DOMSnapshot {
        let script = Self.script
        let value = try await webView.callAsyncJavaScript("return (\(script))(platform)", arguments: ["platform": platform.rawValue], in: nil, contentWorld: .world(name: "CrosscurrentCreator"))
        guard let json = value as? String, let data = json.data(using: .utf8) else { throw BrowserWorkerError.invalidResult }
        do { return try JSONDecoder().decode(DOMSnapshot.self, from: data) }
        catch { throw BrowserWorkerError.extractionFailed(error.localizedDescription) }
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func metricKind(_ value: String) -> MetricKind? {
        switch value {
        case "likes": .likes
        case "reposts": .reposts
        case "replies": .replies
        case "comments": .comments
        case "saves": .saves
        case "views": .views
        default: nil
        }
    }

    private struct DOMSnapshot: Decodable {
        struct Item: Decodable {
            var externalID: String
            var url: String
            var title: String
            var author: String?
            var publishedAt: String?
            var summary: String?
            var metrics: [String: Double]
        }
        var creatorID: String
        var displayName: String
        var profileURL: String
        var biography: String?
        var loginRequired: Bool
        var items: [Item]
    }

    private static let script = #"""
    function(platform) {
      const text = (node) => (node?.textContent || '').replace(/\s+/g, ' ').trim();
      const meta = (name) => document.querySelector(`meta[property="${name}"],meta[name="${name}"]`)?.content || '';
      const absolute = (value) => { try { return new URL(value, location.href).href; } catch (_) { return ''; } };
      const number = (value) => {
        const raw = String(value || '').replace(/,/g, '').trim();
        const match = raw.match(/([0-9]+(?:\.[0-9]+)?)\s*([万千kKmM]?)/);
        if (!match) return null;
        const scale = ['万'].includes(match[2]) ? 10000 : ['千','k','K'].includes(match[2]) ? 1000 : ['m','M'].includes(match[2]) ? 1000000 : 1;
        return Number(match[1]) * scale;
      };
      const pathParts = location.pathname.split('/').filter(Boolean);
      let creatorID = '';
      let displayName = meta('og:site_name') || meta('author') || text(document.querySelector('h1')) || document.title.split(/[|｜-]/)[0].trim();
      let biography = meta('description') || text(document.querySelector('[class*=bio], [class*=desc], #js_profile_desc')) || null;
      let profileURL = location.href;
      let patterns = [];
      if (platform === 'weChatOfficialAccount') {
        const params = new URL(location.href).searchParams;
        creatorID = params.get('__biz') || document.querySelector('[data-biz]')?.dataset.biz || meta('account_id') || displayName;
        displayName = text(document.querySelector('#js_name, .profile_nickname, .account_nickname')) || meta('author') || displayName;
        const profile = document.querySelector('a[href*="mp.weixin.qq.com/mp/profile_ext"], a[href*="profile"]');
        if (profile) profileURL = absolute(profile.href);
        patterns = ['a[href*="mp.weixin.qq.com/s"]', 'a[href*="/s?"]', '.weui_media_title[href]'];
      } else if (platform === 'xiaohongshu') {
        const profileIndex = pathParts.indexOf('profile');
        creatorID = profileIndex >= 0 ? (pathParts[profileIndex + 1] || '') : meta('xhs:creator_id');
        displayName = text(document.querySelector('.user-name, [class*=user-name], [class*=nickname]')) || displayName;
        patterns = ['a[href*="/explore/"]', 'a[href*="/discovery/item/"]'];
      } else if (platform === 'x') {
        creatorID = pathParts[0] || '';
        displayName = text(document.querySelector('[data-testid="UserName"]')) || displayName;
        patterns = ['a[href*="/status/"]'];
      } else if (platform === 'weibo') {
        creatorID = pathParts[0] || meta('weibo:uid');
        patterns = ['a[href*="/status/"]', 'a[href*="/detail/"]'];
      } else {
        const peopleIndex = pathParts.indexOf('people');
        creatorID = peopleIndex >= 0 ? (pathParts[peopleIndex + 1] || '') : pathParts[0] || '';
        patterns = ['a[href*="/p/"]', 'a[href*="/question/"][href*="answer"]'];
      }

      const loginText = text(document.body).slice(0, 5000).toLowerCase();
      const loginRequired = /login|sign in|登录|登入|扫码登录/.test(loginText) && document.querySelectorAll(patterns.join(',')).length === 0;
      const items = [];
      const seen = new Set();
      for (const anchor of document.querySelectorAll(patterns.join(','))) {
        const url = absolute(anchor.href);
        if (!url) continue;
        const parsed = new URL(url);
        let externalID = parsed.pathname.split('/').filter(Boolean).pop() || parsed.searchParams.get('sn') || url;
        if (platform === 'weChatOfficialAccount') externalID = [parsed.searchParams.get('__biz'), parsed.searchParams.get('mid'), parsed.searchParams.get('idx'), parsed.searchParams.get('sn')].filter(Boolean).join(':') || externalID;
        if (seen.has(externalID)) continue;
        seen.add(externalID);
        const card = anchor.closest('article, [data-testid="tweet"], section, li, [class*=note], [class*=feed], [class*=card]') || anchor.parentElement;
        const title = text(anchor).slice(0, 500) || text(card?.querySelector('h1,h2,h3,[class*=title]')).slice(0, 500);
        if (!title) continue;
        const time = card?.querySelector('time')?.dateTime || card?.querySelector('time')?.getAttribute('datetime') || null;
        const cardText = text(card).slice(0, 4000);
        const metrics = {};
        for (const [key, expression] of Object.entries({likes:/([0-9.,万千kKmM]+)\s*(赞|likes?)/i,reposts:/([0-9.,万千kKmM]+)\s*(转发|reposts?)/i,replies:/([0-9.,万千kKmM]+)\s*(回复|replies?)/i,comments:/([0-9.,万千kKmM]+)\s*(评论|comments?)/i,saves:/([0-9.,万千kKmM]+)\s*(收藏|saves?)/i})) {
          const match = cardText.match(expression); const parsedNumber = number(match?.[1]); if (parsedNumber != null) metrics[key] = parsedNumber;
        }
        items.push({externalID, url, title, author: displayName || null, publishedAt: time, summary: cardText || null, metrics});
      }
      if (!items.length && /\/s(?:\?|$)/.test(location.pathname + location.search)) {
        const externalID = [new URL(location.href).searchParams.get('__biz'), new URL(location.href).searchParams.get('mid'), new URL(location.href).searchParams.get('idx'), new URL(location.href).searchParams.get('sn')].filter(Boolean).join(':') || location.href;
        items.push({externalID, url: location.href, title: meta('og:title') || document.title, author: displayName || null, publishedAt: null, summary: text(document.querySelector('#js_content, article, main')).slice(0, 4000), metrics:{}});
      }
      return JSON.stringify({creatorID, displayName, profileURL, biography, loginRequired, items});
    }
    """#
}
