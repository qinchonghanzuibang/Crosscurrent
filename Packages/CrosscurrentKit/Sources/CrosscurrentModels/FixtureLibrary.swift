import CrosscurrentDomain
import CrosscurrentRanking
import Foundation

public struct EventCardModel: Identifiable, Hashable, Sendable {
    public var id: EventID
    public var revisionID: EventRevisionID
    public var revisionOrdinal: Int
    public var primaryItemRevisionID: ItemRevisionID
    public var primarySourceID: SourceID
    public var contentPrivacy: ContentPrivacy
    public var primarySegmentLineageID: SegmentLineageID
    public var membershipCount: Int
    public var title: String
    public var summary: String
    public var primarySource: String
    public var sourceCount: Int
    public var independentSourceCount: Int
    public var topics: [String]
    public var followedPeople: [String]
    public var date: Date
    public var readStatus: RevisionReadStatus
    public var score: Double
    public var reasons: [RankingReason]
    public var bodyHTML: String
    public var originalURL: URL?
    public var originalAccountID: ConnectorAccountID?

    public init(id: EventID = EventID(), revisionID: EventRevisionID = EventRevisionID(), revisionOrdinal: Int = 1, primaryItemRevisionID: ItemRevisionID = ItemRevisionID(), primarySourceID: SourceID = SourceID(), contentPrivacy: ContentPrivacy = .public, primarySegmentLineageID: SegmentLineageID = SegmentLineageID(), membershipCount: Int = 2, title: String, summary: String, primarySource: String, sourceCount: Int, independentSourceCount: Int, topics: [String], followedPeople: [String] = [], date: Date, readStatus: RevisionReadStatus, score: Double, reasons: [RankingReason], bodyHTML: String, originalURL: URL? = nil, originalAccountID: ConnectorAccountID? = nil) {
        self.id = id
        self.revisionID = revisionID
        self.revisionOrdinal = revisionOrdinal
        self.primaryItemRevisionID = primaryItemRevisionID
        self.primarySourceID = primarySourceID
        self.contentPrivacy = contentPrivacy
        self.primarySegmentLineageID = primarySegmentLineageID
        self.membershipCount = membershipCount
        self.title = title
        self.summary = summary
        self.primarySource = primarySource
        self.sourceCount = sourceCount
        self.independentSourceCount = independentSourceCount
        self.topics = topics
        self.followedPeople = followedPeople
        self.date = date
        self.readStatus = readStatus
        self.score = score
        self.reasons = reasons
        self.bodyHTML = bodyHTML
        self.originalURL = originalURL
        self.originalAccountID = originalAccountID
    }
}

public enum FixtureLibrary {
    public static let events: [EventCardModel] = [
        EventCardModel(id: EventID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!), title: "A new open model pushes efficient on-device reasoning", summary: "The release pairs a smaller architecture with reproducible evaluations, making local bilingual workflows practical on consumer hardware.", primarySource: "Model Lab", sourceCount: 14, independentSourceCount: 7, topics: ["AI", "Local models"], followedPeople: ["Mira Chen"], date: .now.addingTimeInterval(-1_800), readStatus: .updated, score: 0.94, reasons: [.followedPerson, .primarySource, .independentCoverage], bodyHTML: "<p>The research team published <a href=\"https://example.com/model-card\">weights and evaluation code</a>, plus a detailed technical report.</p><h2>Why it matters</h2><p>Independent replications show strong Chinese and English retrieval while keeping memory use low.</p>", originalURL: URL(string: "https://example.com/model-card")),
        EventCardModel(id: EventID(UUID(uuidString: "10000000-0000-0000-0000-000000000002")!), title: "上海发布面向独立开发者的新一轮算力支持计划 / New compute support for independent builders", summary: "新计划扩大了本地模型、无障碍技术和公共数据工具的支持范围，多家开发者社区已公布申请说明。", primarySource: "上海市经信委", sourceCount: 9, independentSourceCount: 5, topics: ["开发者", "产业政策"], date: .now.addingTimeInterval(-4_200), readStatus: .unread, score: 0.89, reasons: [.primarySource, .independentCoverage], bodyHTML: "<p>计划将于下月开放申请，重点关注可验证的公共价值与本地部署能力。</p><h2>申请范围</h2><p>个人开发者和小型团队均可提交材料。</p>", originalURL: URL(string: "https://example.com/shanghai-support")),
        EventCardModel(title: "WebKit adds stronger controls for isolated content processing", summary: "The changes improve separation between page scripts and app-owned extraction code, with new diagnostics for data-store ownership.", primarySource: "WebKit", sourceCount: 8, independentSourceCount: 4, topics: ["WebKit", "Security"], date: .now.addingTimeInterval(-7_200), readStatus: .read, score: 0.83, reasons: [.followedSource, .primarySource], bodyHTML: "<p>WebKit’s update clarifies how persistent profiles and isolated content worlds interact.</p>"),
        EventCardModel(title: "Researchers map how the same climate result travels across media ecosystems", summary: "Coverage converges on the measurements but diverges on policy framing; the comparison is backed by independent evidence groups on both sides.", primarySource: "Nature Climate", sourceCount: 22, independentSourceCount: 12, topics: ["Climate", "Media"], date: .now.addingTimeInterval(-10_800), readStatus: .unread, score: 0.81, reasons: [.chinaGlobalCoverage, .independentCoverage], bodyHTML: "<p>The underlying measurements are consistent across the cited research and official datasets.</p>"),
        EventCardModel(id: EventID(UUID(uuidString: "10000000-0000-0000-0000-000000000005")!), title: "A maintainer-led SQLite tool makes large local archives easier to inspect", summary: "The utility exposes migration size, WAL pressure, and index lag without uploading database contents.", primarySource: "GitHub", sourceCount: 6, independentSourceCount: 3, topics: ["SQLite", "Open source"], followedPeople: ["Alex Wu"], date: .now.addingTimeInterval(-14_000), readStatus: .read, score: 0.76, reasons: [.followedPerson, .savedRelationship], bodyHTML: "<p>The project is available under a permissive license and includes reproducible benchmarks.</p>"),
    ]
}
