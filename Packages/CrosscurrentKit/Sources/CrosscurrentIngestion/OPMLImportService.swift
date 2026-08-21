import CrosscurrentConnectors
import CrosscurrentStorage
import Foundation

public struct OPMLImportResult: Sendable {
    public var sourceCount: Int
    public var folderCount: Int
    public var failures: [String]

    public init(sourceCount: Int = 0, folderCount: Int = 0, failures: [String] = []) {
        self.sourceCount = sourceCount
        self.folderCount = folderCount
        self.failures = failures
    }
}

/// Imports subscriptions through the same discovery path as individual Sources while retaining
/// OPML hierarchy and non-secret extension attributes in canonical source-folder records.
public actor OPMLImportService {
    private let repository: CrosscurrentRepository
    private let discovery: SourceDiscoveryService

    public init(repository: CrosscurrentRepository, discovery: SourceDiscoveryService) {
        self.repository = repository
        self.discovery = discovery
    }

    public func importData(_ data: Data, context: ConnectorContext = ConnectorContext()) async throws -> OPMLImportResult {
        let outlines = try OPMLParser().parse(data: data)
        var result = OPMLImportResult()
        for (index, outline) in outlines.enumerated() {
            await importOutline(outline, parentID: nil, parentPath: "", sortOrder: index, context: context, result: &result)
        }
        return result
    }

    private func importOutline(_ outline: OPMLOutline, parentID: UUID?, parentPath: String, sortOrder: Int, context: ConnectorContext, result: inout OPMLImportResult) async {
        var effectiveParent = parentID
        let component = Self.pathComponent(outline.title)
        let path = parentPath.isEmpty ? component : "\(parentPath)/\(component)"

        if outline.feedURL == nil {
            do {
                effectiveParent = try await repository.ensureSourceFolder(
                    name: outline.title,
                    pathKey: path,
                    parentID: parentID,
                    attributes: Self.safeAttributes(outline.attributes),
                    sortOrder: sortOrder
                )
                result.folderCount += 1
            } catch {
                result.failures.append("\(outline.title): \(error.localizedDescription)")
            }
        }

        if let feedURL = outline.feedURL {
            do {
                let discovered = try await discovery.discover(.init(url: feedURL), context: context)
                if let effectiveParent {
                    _ = try await repository.assignSource(discovered.source.id, toFolder: effectiveParent, sortOrder: sortOrder)
                }
                result.sourceCount += 1
            } catch {
                result.failures.append("\(outline.title): \(error.localizedDescription)")
            }
        }

        for (index, child) in outline.children.enumerated() {
            await importOutline(child, parentID: effectiveParent, parentPath: path, sortOrder: index, context: context, result: &result)
        }
    }

    private static func pathComponent(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "∕")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeAttributes(_ attributes: [String: String]) -> [String: String] {
        let secretFragments = ["token", "secret", "password", "credential", "cookie", "authorization"]
        return attributes.filter { key, _ in
            !secretFragments.contains { key.lowercased().contains($0) }
        }
    }
}
