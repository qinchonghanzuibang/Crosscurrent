import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public actor OPMLExportService {
    private let repository: CrosscurrentRepository

    public init(repository: CrosscurrentRepository) {
        self.repository = repository
    }

    public func exportData(createdAt: Date = .now) async throws -> Data {
        let sources = try await repository.sourceSnapshots()
        let folders = try await repository.sourceFolderSnapshots()
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.source.id, $0) })
        let assigned = Set(folders.flatMap(\.sourceIDs))
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<opml version=\"2.0\">",
            "  <head><title>Crosscurrent Sources</title><dateCreated>\(Self.dateString(createdAt))</dateCreated></head>",
            "  <body>"
        ]
        for folder in folders.filter({ $0.parentID == nil }).sorted(by: Self.folderOrder) {
            Self.append(folder: folder, allFolders: folders, sources: byID, indent: 2, to: &lines)
        }
        for source in sources.filter({ !assigned.contains($0.source.id) }) {
            Self.append(source: source, indent: 2, to: &lines)
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func append(folder: StoredSourceFolderSnapshot, allFolders: [StoredSourceFolderSnapshot], sources: [SourceID: StoredSourceSnapshot], indent: Int, to lines: inout [String]) {
        let padding = String(repeating: "  ", count: indent)
        let attributes = folder.attributes
            .filter { attribute in !Self.secretFragments.contains(where: { attribute.key.lowercased().contains($0) }) }
            .sorted { $0.key < $1.key }
            .map { " \(escape($0.key))=\"\(escape($0.value))\"" }
            .joined()
        lines.append("\(padding)<outline text=\"\(escape(folder.name))\" title=\"\(escape(folder.name))\"\(attributes)>")
        for sourceID in folder.sourceIDs {
            if let source = sources[sourceID] { append(source: source, indent: indent + 1, to: &lines) }
        }
        for child in allFolders.filter({ $0.parentID == folder.id }).sorted(by: folderOrder) {
            append(folder: child, allFolders: allFolders, sources: sources, indent: indent + 1, to: &lines)
        }
        lines.append("\(padding)</outline>")
    }

    private static func append(source: StoredSourceSnapshot, indent: Int, to lines: inout [String]) {
        let padding = String(repeating: "  ", count: indent)
        guard let endpoint = source.endpoints.first, let url = endpoint.canonicalURL else { return }
        let htmlURL = source.endpoints.first(where: { $0.connector.rawValue == "website" })?.canonicalURL
        var attributes = " text=\"\(escape(source.revision.displayName))\" title=\"\(escape(source.revision.displayName))\" type=\"rss\" xmlUrl=\"\(escape(url.absoluteString))\""
        if let htmlURL { attributes += " htmlUrl=\"\(escape(htmlURL.absoluteString))\"" }
        attributes += " crosscurrentConnector=\"\(escape(endpoint.connector.rawValue))\""
        lines.append("\(padding)<outline\(attributes) />")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func folderOrder(_ lhs: StoredSourceFolderSnapshot, _ rhs: StoredSourceFolderSnapshot) -> Bool {
        lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
    }

    private static let secretFragments = ["token", "secret", "password", "credential", "cookie", "authorization"]
    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
