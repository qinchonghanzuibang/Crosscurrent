import Foundation

public struct OPMLOutline: Codable, Hashable, Sendable {
    public var title: String
    public var feedURL: URL?
    public var htmlURL: URL?
    public var attributes: [String: String]
    public var children: [OPMLOutline]

    public init(title: String, feedURL: URL? = nil, htmlURL: URL? = nil, attributes: [String: String] = [:], children: [OPMLOutline] = []) {
        self.title = title
        self.feedURL = feedURL
        self.htmlURL = htmlURL
        self.attributes = attributes
        self.children = children
    }
}

public final class OPMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var roots: [OPMLOutline] = []
    private var stack: [OPMLOutline] = []

    public func parse(data: Data) throws -> [OPMLOutline] {
        roots = []; stack = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? ConnectorError.invalidResponse("invalid OPML") }
        return roots
    }

    public func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName.lowercased() == "outline" else { return }
        let title = attributeDict["title"] ?? attributeDict["text"] ?? "Untitled"
        stack.append(OPMLOutline(title: title, feedURL: attributeDict["xmlUrl"].flatMap(URL.init(string:)), htmlURL: attributeDict["htmlUrl"].flatMap(URL.init(string:)), attributes: attributeDict))
    }

    public func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        guard elementName.lowercased() == "outline", let finished = stack.popLast() else { return }
        if stack.isEmpty { roots.append(finished) }
        else { stack[stack.count - 1].children.append(finished) }
    }
}
