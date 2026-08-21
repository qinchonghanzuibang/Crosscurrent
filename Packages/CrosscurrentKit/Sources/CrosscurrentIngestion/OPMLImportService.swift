import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct OPMLImportResult: Sendable {
    public var sourceCount: Int
    public var folderCount: Int
    public var failures: [String]
    public var entries: [OPMLImportEntryResult]

    public init(sourceCount: Int = 0, folderCount: Int = 0, failures: [String] = [], entries: [OPMLImportEntryResult] = []) {
        self.sourceCount = sourceCount
        self.folderCount = folderCount
        self.failures = failures
        self.entries = entries
    }
}

public struct OPMLImportEntryResult: Sendable {
    public var title: String
    public var feedURL: URL
    public var message: String
    public var succeeded: Bool
    public var endpointIDs: [SourceEndpointID]
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
                let wasExisting = try await Self.sourceExists(feedURL: feedURL, repository: repository)
                var preview = try await discovery.preview(.init(url: feedURL), context: context)
                preview.result.sourceRevision.displayName = outline.title
                guard preview.availableActions.contains(.subscribe) else { throw ConnectorError.unsupportedInput }
                let committed = try await discovery.commit(preview, action: .subscribe)
                if let effectiveParent {
                    _ = try await repository.assignSource(committed.sourceID, toFolder: effectiveParent, sortOrder: sortOrder)
                }
                result.sourceCount += 1
                result.entries.append(OPMLImportEntryResult(
                    title: outline.title,
                    feedURL: feedURL,
                    message: wasExisting ? "Already subscribed" : "Imported",
                    succeeded: true,
                    endpointIDs: committed.endpointIDs
                ))
            } catch {
                let message = "\(outline.title): \(error.localizedDescription)"
                result.failures.append(message)
                result.entries.append(OPMLImportEntryResult(title: outline.title, feedURL: feedURL, message: error.localizedDescription, succeeded: false, endpointIDs: []))
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
        let structural = Set(["text", "title", "type", "xmlurl", "htmlurl"])
        return attributes.filter { key, _ in
            let normalized = key.lowercased()
            return !structural.contains(normalized) && !secretFragments.contains { normalized.contains($0) }
        }
    }

    private static func sourceExists(feedURL: URL, repository: CrosscurrentRepository) async throws -> Bool {
        let canonical = URLNormalizer.canonicalize(feedURL).absoluteString
        return try await repository.sourceSnapshots().contains { snapshot in
            snapshot.endpoints.contains { endpoint in
                endpoint.canonicalURL.map(URLNormalizer.canonicalize)?.absoluteString == canonical
            }
        }
    }
}
