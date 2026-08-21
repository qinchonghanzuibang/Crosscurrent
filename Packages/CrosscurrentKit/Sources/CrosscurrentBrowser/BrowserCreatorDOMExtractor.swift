import CrosscurrentConnectors
import Foundation
import WebKit

/// Authenticated extraction stays deliberately unavailable until a real-account
/// capture establishes a versioned platform contract. No guessed selectors,
/// listing rules, cursors, or deletion behavior live behind this boundary.
@MainActor
public enum BrowserCreatorDOMExtractor {
    public static func discover(
        platform: AuthenticatedCreatorPlatform,
        in _: WKWebView
    ) async throws -> BrowserCreatorIdentity {
        throw unqualified(platform)
    }

    public static func refresh(
        platform: AuthenticatedCreatorPlatform,
        cursor _: ConnectorCursor?,
        in _: WKWebView
    ) async throws -> ConnectorRefreshPage {
        throw unqualified(platform)
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

    private static func unqualified(_ platform: AuthenticatedCreatorPlatform) -> ConnectorError {
        .platformChanged(
            "\(platform.rawValue) has no live-account-qualified extraction contract. "
                + "Capture a bounded, user-authorized diagnostic fixture before implementing selectors or pagination."
        )
    }
}
