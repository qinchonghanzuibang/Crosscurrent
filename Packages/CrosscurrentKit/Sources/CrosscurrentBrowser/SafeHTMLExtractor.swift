import AppKit
import Foundation
import Readability
import SwiftSoup

public struct SafeExtractionResult: Codable, Hashable, Sendable {
    public var title: String
    public var sanitizedHTML: String
    public var plainText: String

    public init(title: String, sanitizedHTML: String, plainText: String) {
        self.title = title
        self.sanitizedHTML = sanitizedHTML
        self.plainText = plainText
    }
}

public enum StaticHTMLPreprocessor {
    public static func inertDocument(from untrustedHTML: String, baseURL: URL?) throws -> String {
        let document = try SwiftSoup.parse(untrustedHTML, baseURL?.absoluteString ?? "")
        try document.select("script, iframe, frame, object, embed, base, link, meta[http-equiv=refresh]").remove()
        for element in try document.getAllElements() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                if key.hasPrefix("on") || key == "srcdoc" { try element.removeAttr(attribute.getKey()) }
            }
        }
        try document.head()?.prepend("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\">")
        return try document.outerHtml()
    }

    public static func conservativeSanitize(_ html: String) throws -> SafeExtractionResult {
        let document = try SwiftSoup.parseBodyFragment(html)
        try document.select("script, style, iframe, frame, object, embed, form, input, button, textarea, select, meta, link, foreignObject, animate, animateMotion, animateTransform, set, use").remove()
        let htmlTags = Set(["p", "div", "article", "section", "main", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "code", "em", "strong", "b", "i", "u", "s", "br", "hr", "a", "img", "figure", "figcaption", "table", "thead", "tbody", "tr", "th", "td", "span", "sup", "sub"])
        let svgTags = Set(["svg", "g", "path", "circle", "ellipse", "line", "polyline", "polygon", "rect", "text", "tspan", "title", "desc"])
        let mathMLTags = Set(["math", "mrow", "mi", "mn", "mo", "ms", "mtext", "mfrac", "msqrt", "mroot", "msup", "msub", "msubsup", "munder", "mover", "munderover", "mtable", "mtr", "mtd", "semantics", "annotation"])
        let allowed = htmlTags.union(svgTags).union(mathMLTags)
        let parserStructure = Set(["#root", "html", "head", "body"])
        for element in try document.getAllElements() where !parserStructure.contains(element.tagName()) && !allowed.contains(element.tagName()) {
            try element.unwrap()
        }
        for element in try document.getAllElements() {
            let name = element.tagName()
            let permittedAttributes: Set<String>
            if name == "a" {
                permittedAttributes = ["href", "title"]
            } else if name == "img" {
                permittedAttributes = ["src", "alt", "title", "width", "height"]
            } else if svgTags.contains(name) {
                permittedAttributes = ["viewbox", "preserveaspectratio", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "d", "points", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "transform", "role", "aria-label"]
            } else if mathMLTags.contains(name) {
                permittedAttributes = ["display", "mathvariant", "mathsize", "mathcolor", "columnalign", "rowalign", "encoding"]
            } else {
                permittedAttributes = []
            }
            for attribute in element.getAttributes()?.asList() ?? [] where !permittedAttributes.contains(attribute.getKey().lowercased()) {
                try element.removeAttr(attribute.getKey())
            }
            for attributeName in permittedAttributes {
                guard let value = try? element.attr(attributeName), !value.isEmpty else { continue }
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized.contains("javascript:") || normalized.contains("url(") || normalized.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) {
                    try element.removeAttr(attributeName)
                }
            }
            if name == "a", let value = try? element.attr("href"), !value.isEmpty,
               !isSafeLink(value) {
                try element.removeAttr("href")
            }
            if name == "img", let value = try? element.attr("src"), !value.isEmpty,
               !isSafeReaderAsset(value) {
                try element.removeAttr("src")
            }
        }
        return SafeExtractionResult(title: try document.title(), sanitizedHTML: try document.body()?.html() ?? "", plainText: try document.text())
    }

    private static func isSafeLink(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//")
        }
        return ["http", "https", "mailto"].contains(scheme)
    }

    private static func isSafeReaderAsset(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("data:image/") || normalized.hasPrefix("blob:") || normalized.hasPrefix("app-asset:")
    }
}

@MainActor
public final class SafeHTMLExtractor: NSObject {
    public override init() {
        // WKWebView requires an application connection even when extraction is exercised by
        // a command-line test host or the background BrowserWorker.
        _ = NSApplication.shared
        super.init()
    }

    public func extract(untrustedHTML: String, baseURL: URL?) async throws -> SafeExtractionResult {
        let inert = try StaticHTMLPreprocessor.inertDocument(from: untrustedHTML, baseURL: baseURL)
        // The dependency bundles pinned Mozilla Readability and DOMPurify. Only the inert, deny-all-CSP
        // document reaches its JavaScript runtime: source scripts/handlers/frames/navigation were removed
        // before load and external resources are forbidden. DOMPurify runs before Readability, and the
        // native allowlist below is an independent post-extraction boundary before persistence.
        let options = Readability.Options(maxElemsToParse: 100_000, shouldSanitize: true)
        let article = try await Readability().parse(html: inert, options: options, baseURL: baseURL)
        var sanitized = try StaticHTMLPreprocessor.conservativeSanitize(article.content)
        if !article.title.isEmpty { sanitized.title = article.title }
        return sanitized
    }
}
