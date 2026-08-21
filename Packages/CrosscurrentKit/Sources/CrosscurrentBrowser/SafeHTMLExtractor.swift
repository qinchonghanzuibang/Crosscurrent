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
        // Preserve declarative TeX payloads before executable source scripts are removed. Reader
        // rendering converts only these owned text delimiters; source-page JavaScript never runs.
        for script in try document.select("script[type^=math/tex]") {
            let type = (try? script.attr("type").lowercased()) ?? ""
            let tex = script.data().trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = Element(try Tag.valueOf(type.contains("mode=display") ? "div" : "span"), baseURL?.absoluteString ?? "")
            try replacement.text(type.contains("mode=display") ? "\\[\(tex)\\]" : "\\(\(tex)\\)")
            try script.replaceWith(replacement)
        }
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

    public static func conservativeSanitize(_ html: String, baseURL: URL? = nil) throws -> SafeExtractionResult {
        let document = try SwiftSoup.parseBodyFragment(html, baseURL?.absoluteString ?? "")
        try document.select("script, style, iframe, frame, object, embed, form, input, button, textarea, select, meta, link, foreignObject, animate, animateMotion, animateTransform, set, use").remove()
        let htmlTags = Set(["p", "div", "article", "section", "main", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "code", "em", "strong", "b", "i", "u", "s", "br", "hr", "a", "img", "figure", "figcaption", "table", "thead", "tbody", "tr", "th", "td", "span", "sup", "sub"])
        let svgTags = Set(["svg", "g", "path", "circle", "ellipse", "line", "polyline", "polygon", "rect", "text", "tspan", "title", "desc"])
        let mathMLTags = Set(["math", "mrow", "mi", "mn", "mo", "ms", "mtext", "mfrac", "msqrt", "mroot", "msup", "msub", "msubsup", "munder", "mover", "munderover", "mtable", "mtr", "mtd", "mstyle", "mpadded", "mspace", "mphantom", "mfenced", "menclose", "mmultiscripts", "mprescripts", "none", "semantics", "annotation"])
        let allowed = htmlTags.union(svgTags).union(mathMLTags)
        let parserStructure = Set(["#root", "html", "head", "body"])
        for element in try document.getAllElements() where !parserStructure.contains(element.tagName()) && !allowed.contains(element.tagName()) {
            try element.unwrap()
        }
        for element in try document.getAllElements() {
            let name = element.tagName()
            if name == "a", let href = firstNonemptyAttribute(in: element, names: ["href"]),
               let resolved = resolvedURLString(href, baseURL: baseURL) {
                try element.attr("href", resolved)
            }
            if name == "img" {
                let candidate = firstNonemptyAttribute(
                    in: element,
                    names: ["data-src", "data-original", "data-lazy-src", "data-actualsrc", "src"]
                ) ?? bestSourceSetCandidate(firstNonemptyAttribute(in: element, names: ["data-srcset", "srcset"]))
                if let candidate, let resolved = resolvedURLString(candidate, baseURL: baseURL), isSafeReaderAsset(resolved) {
                    try element.attr("src", resolved)
                } else {
                    try element.removeAttr("src")
                }
                normalizeImageDimensions(element)
            }
            let permittedAttributes: Set<String>
            if name == "a" {
                permittedAttributes = ["href", "title"]
            } else if name == "img" {
                permittedAttributes = ["src", "alt", "title", "width", "height"]
            } else if svgTags.contains(name) {
                permittedAttributes = ["viewbox", "preserveaspectratio", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "d", "points", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "transform", "role", "aria-label"]
            } else if mathMLTags.contains(name) {
                permittedAttributes = ["display", "mathvariant", "mathsize", "mathcolor", "columnalign", "rowalign", "encoding", "accent", "accentunder", "align", "columnspacing", "columnlines", "columnwidth", "rowspacing", "rowlines", "linethickness", "stretchy", "symmetric", "largeop", "movablelimits", "form", "fence", "separator", "lspace", "rspace", "maxsize", "minsize", "notation", "scriptsizemultiplier", "scriptminsize", "displaystyle", "scriptlevel", "width", "height", "depth", "voffset"]
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
        if normalized.hasPrefix("data:image/") || normalized.hasPrefix("blob:") || normalized.hasPrefix("app-asset:") { return true }
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local")
        else { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 10 || octets[0] == 127 || (octets[0] == 169 && octets[1] == 254) { return false }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return false }
            if octets[0] == 192 && octets[1] == 168 { return false }
        }
        return true
    }

    private static func firstNonemptyAttribute(in element: Element, names: [String]) -> String? {
        for name in names {
            if let value = try? element.attr(name).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func bestSourceSetCandidate(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.split(separator: ",").compactMap { component -> (String, Double)? in
            let parts = component.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
            guard let url = parts.first.map(String.init), !url.isEmpty else { return nil }
            let descriptor = parts.dropFirst().first.map(String.init) ?? "1x"
            let score = Double(descriptor.dropLast()) ?? 1
            return (url, score)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    private static func resolvedURLString(_ value: String, baseURL: URL?) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
        if trimmed.hasPrefix("#") {
            return baseURL.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL.absoluteString } ?? trimmed
        }
        if let components = URLComponents(string: trimmed), components.scheme != nil { return trimmed }
        return baseURL.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL.absoluteString } ?? trimmed
    }

    private static func normalizeImageDimensions(_ element: Element) {
        guard let style = try? element.attr("style"), !style.isEmpty else { return }
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard parts.count == 2, parts[0] == "width" || parts[0] == "height" else { continue }
            let value = parts[1]
            let allowed = value.allSatisfy { $0.isNumber || $0 == "." || $0 == "%" || $0 == "p" || $0 == "x" }
            if allowed { _ = try? element.attr(parts[0], value) }
        }
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
        var sanitized = try StaticHTMLPreprocessor.conservativeSanitize(article.content, baseURL: baseURL)
        if !article.title.isEmpty { sanitized.title = article.title }
        return sanitized
    }
}
