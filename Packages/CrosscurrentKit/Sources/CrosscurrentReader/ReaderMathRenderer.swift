import CrosscurrentBrowser
import Foundation
import MathJaxSwift
import SwiftSoup

public enum ReaderHTMLPreparer {
    public static func prepare(_ html: String) async -> String {
        await ReaderMathRenderer.shared.render(html: html)
    }
}

/// Converts inert TeX text into native MathML using bundled MathJax. Source-page scripts never
/// execute, and generated markup crosses the same native allowlist as persisted article HTML.
actor ReaderMathRenderer {
    static let shared = ReaderMathRenderer()

    private var mathJax: MathJax?
    private var cache: [CacheKey: String] = [:]

    func render(html: String) -> String {
        guard html.contains("$") || html.contains("\\(") || html.contains("\\[") else { return html }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            let textNodes = try document.getAllElements().flatMap { element in
                if ["code", "pre", "math", "svg"].contains(element.tagName()) { return [TextNode]() }
                return element.getChildNodes().compactMap { $0 as? TextNode }
            }
            for node in textNodes {
                let pieces = Self.mathPieces(in: node.getWholeText())
                guard pieces.contains(where: { if case .math = $0 { true } else { false } }) else { continue }
                for piece in pieces {
                    switch piece {
                    case let .text(value):
                        try node.before(TextNode(value, ""))
                    case let .math(tex, display, original):
                        do {
                            let mathML = try render(tex: tex, display: display)
                            try node.before(mathML)
                        } catch {
                            try node.before(TextNode(original, ""))
                        }
                    }
                }
                try node.remove()
            }
            return try document.body()?.html() ?? html
        } catch {
            return html
        }
    }

    private func render(tex: String, display: Bool) throws -> String {
        let key = CacheKey(tex: tex, display: display)
        if let cached = cache[key] { return cached }
        let renderer: MathJax
        if let mathJax {
            renderer = mathJax
        } else {
            renderer = try MathJax(preferredOutputFormat: .mml)
            mathJax = renderer
        }
        let options = ConversionOptions(display: display)
        let converted: String
        do {
            converted = try renderer.tex2mml(tex, conversionOptions: options)
        } catch {
            let compatibleTex = Self.compatibleScriptGroups(in: tex)
            guard compatibleTex != tex else { throw error }
            converted = try renderer.tex2mml(compatibleTex, conversionOptions: options)
        }
        let sanitized = try StaticHTMLPreprocessor.conservativeSanitize(converted).sanitizedHTML
        cache[key] = sanitized
        return sanitized
    }

    /// MathJaxSwift 3.5 rejects some otherwise-valid multi-token braced scripts such as
    /// `r_{n-1}`. Wrapping only simple script groups in `\mathord` preserves their semantics and
    /// leaves complex TeX untouched; the original form remains the first conversion attempt.
    private static func compatibleScriptGroups(in tex: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"([_^])\{([A-Za-z0-9+\- ]{2,})\}"#) else {
            return tex
        }
        let range = NSRange(tex.startIndex..<tex.endIndex, in: tex)
        return expression.stringByReplacingMatches(in: tex, range: range, withTemplate: "$1\\\\mathord{$2}")
    }

    private struct CacheKey: Hashable {
        var tex: String
        var display: Bool
    }

    private enum Piece {
        case text(String)
        case math(tex: String, display: Bool, original: String)
    }

    /// Delimiter recognition is intentionally conservative: code/pre nodes are excluded, escaped
    /// dollar signs stay text, and inline delimiters cannot start or end on whitespace.
    private static func mathPieces(in source: String) -> [Piece] {
        var pieces: [Piece] = []
        var textStart = source.startIndex
        var cursor = source.startIndex

        func isEscaped(_ index: String.Index) -> Bool {
            var slashCount = 0
            var current = index
            while current > source.startIndex {
                current = source.index(before: current)
                if source[current] == "\\" { slashCount += 1 } else { break }
            }
            return slashCount.isMultiple(of: 2) == false
        }

        func appendMath(openStart: String.Index, contentStart: String.Index, close: String, display: Bool) -> String.Index? {
            guard let closeRange = source.range(of: close, range: contentStart..<source.endIndex) else { return nil }
            let content = String(source[contentStart..<closeRange.lowerBound])
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if close == "$", (content.last?.isWhitespace == true || isEscaped(closeRange.lowerBound)) { return nil }
            if textStart < openStart { pieces.append(.text(String(source[textStart..<openStart]))) }
            pieces.append(.math(
                tex: content,
                display: display,
                original: String(source[openStart..<closeRange.upperBound])
            ))
            return closeRange.upperBound
        }

        while cursor < source.endIndex {
            if source[cursor] == "\\", !isEscaped(cursor) {
                let next = source.index(after: cursor)
                if next < source.endIndex, source[next] == "(" || source[next] == "[" {
                    let display = source[next] == "["
                    let contentStart = source.index(after: next)
                    if let end = appendMath(openStart: cursor, contentStart: contentStart, close: display ? "\\]" : "\\)", display: display) {
                        cursor = end
                        textStart = end
                        continue
                    }
                }
            }
            if source[cursor] == "$", !isEscaped(cursor) {
                let next = source.index(after: cursor)
                let isDouble = next < source.endIndex && source[next] == "$"
                let contentStart = isDouble ? source.index(after: next) : next
                if contentStart < source.endIndex, isDouble || source[contentStart].isWhitespace == false,
                   let end = appendMath(openStart: cursor, contentStart: contentStart, close: isDouble ? "$$" : "$", display: isDouble) {
                    cursor = end
                    textStart = end
                    continue
                }
            }
            cursor = source.index(after: cursor)
        }
        if textStart < source.endIndex { pieces.append(.text(String(source[textStart...]))) }
        return pieces
    }
}
