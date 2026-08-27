import CrosscurrentBrowser
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
        let meaningfulText = try content.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard meaningfulText.count >= 80 else { throw WeChatHTMLPreprocessorError.missingBody }
        var result = try StaticHTMLPreprocessor.conservativeSanitize(try content.outerHtml(), baseURL: baseURL)
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
