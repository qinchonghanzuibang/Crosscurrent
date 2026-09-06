import CrosscurrentBrowser
import CrosscurrentConnectors
import Foundation
import SwiftSoup

public enum WeChatHTMLPreprocessor {
    public static func articleContent(from html: String, baseURL: URL?) throws -> SafeExtractionResult {
        let document = try SwiftSoup.parse(html, baseURL?.absoluteString ?? "")
        let normalized = html.lowercased()
        let rejected = ["请输入验证码", "环境异常", "访问过于频繁", "captcha", "waf_captcha"]
        guard !rejected.contains(where: normalized.contains) else {
            throw WeChatHTMLPreprocessorError.rejectedResponse
        }
        let content = try document.select("#js_content, .rich_media_content, article").first() ?? document.body()
        guard let content else { throw WeChatHTMLPreprocessorError.missingBody }
        for image in try content.select("img") {
            for attribute in ["src", "data-src", "data-original", "data-lazy-src", "data-actualsrc"] {
                if let url = URL(string: try image.attr(attribute)), let original = WeChatPublicFeedContent.originalMediaURL(url) {
                    try image.attr(attribute, original.absoluteString)
                }
            }
        }
        for link in try content.select("a[href]") {
            if let url = URL(string: try link.attr("href")), let original = WeChatPublicFeedContent.originalArticleURL(url) {
                try link.attr("href", original.absoluteString)
            }
        }
        let meaningfulText = try content.text().trimmingCharacters(in: .whitespacesAndNewlines)
        var result = try StaticHTMLPreprocessor.conservativeSanitize(try content.outerHtml(), baseURL: baseURL)
        guard meaningfulText.count >= 80 || result.sanitizedHTML.contains("<img ") else { throw WeChatHTMLPreprocessorError.missingBody }
        let titleSelectors = ["#activity-name", ".rich_media_title", "meta[property=og:title]", "title"]
        for selector in titleSelectors {
            guard let element = try document.select(selector).first() else { continue }
            let value = element.tagName() == "meta" ? try element.attr("content") : try element.text()
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.title = trimmed; break }
        }
        return result
    }
}

public enum WeChatHTMLPreprocessorError: LocalizedError, Equatable {
    case rejectedResponse
    case missingBody

    public var errorDescription: String? {
        switch self {
        case .rejectedResponse: "WeChat returned a verification or abnormal page."
        case .missingBody: "The WeChat article body was missing or empty."
        }
    }
}
