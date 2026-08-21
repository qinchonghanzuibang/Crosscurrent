import Foundation

public enum ReaderSelectionAction: String, Codable, CaseIterable, Sendable {
    case explain, translate, summarize, askAI
}

public enum ReaderArticleAction: String, Codable, CaseIterable, Sendable {
    case summary, keyPoints, askArticle, relatedEvents, relatedSavedContent, openOriginal
}

public struct ReaderSelectionContext: Codable, Hashable, Sendable {
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID?
    public var span: TextSpan
    public var selectedText: String

    public init(itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID? = nil, span: TextSpan, selectedText: String) {
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.span = span
        self.selectedText = selectedText
    }
}

public struct LinkPreview: Codable, Hashable, Sendable {
    public var url: URL
    public var title: String
    public var summary: String?
    public var imageURL: URL?
    public var fetchedWithoutAuthentication: Bool

    public init(url: URL, title: String, summary: String? = nil, imageURL: URL? = nil, fetchedWithoutAuthentication: Bool = true) {
        self.url = url
        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.fetchedWithoutAuthentication = fetchedWithoutAuthentication
    }
}

public struct ShareInboxRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String?
    public var selectedText: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), url: URL, title: String? = nil, selectedText: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.selectedText = selectedText
        self.createdAt = createdAt
    }
}
