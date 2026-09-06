import CrosscurrentDomain
import CrosscurrentIngestion
@testable import CrosscurrentStorage
import Foundation
import Testing

@Test func refreshPlannerRecoversTransientSourcesAndHonorsArchiveAndMirrorSuccess() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sourceID = SourceID()
    let revision = SourceRevision(sourceID: sourceID, displayName: "Following")
    let source = LogicalSource(id: sourceID, currentRevisionID: revision.id, kind: .publication)
    let transient = SourceEndpoint(sourceID: sourceID, connector: .rss, externalID: "recoverable", health: .temporarilyUnavailable)
    let credentials = SourceEndpoint(sourceID: sourceID, connector: .rss, externalID: "credentials", health: .authenticationRequired)
    let recent = SourceEndpoint(sourceID: sourceID, connector: .rss, externalID: "recent", lastSuccessfulSync: now.addingTimeInterval(-60))
    let primary = SourceEndpoint(sourceID: sourceID, connector: .weChatOfficialAccount, externalID: "primary", health: .error, weChatAcquisition: .init(providerID: "first", priority: 0))
    let mirror = SourceEndpoint(sourceID: sourceID, connector: .weChatOfficialAccount, externalID: "mirror", lastSuccessfulSync: now.addingTimeInterval(-60), weChatAcquisition: .init(providerID: "second", priority: 1))
    var snapshot = StoredSourceSnapshot(source: source, revision: revision, endpoints: [transient, credentials, recent, primary, mirror], aiClassification: nil, coverage: nil)
    #expect(SourceRefreshPlanner.dueEndpoints(in: [snapshot], now: now).map(\.id) == [transient.id])
    let afterInterval = SourceRefreshPlanner.dueEndpoints(in: [snapshot], now: now.addingTimeInterval(4 * 60 * 60))
    #expect(Set(afterInterval.map(\.id)) == [transient.id, recent.id, primary.id])
    #expect(afterInterval.filter { $0.connector == .weChatOfficialAccount }.count == 1)
    snapshot.source.isArchived = true
    #expect(SourceRefreshPlanner.dueEndpoints(in: [snapshot], now: now).isEmpty)
}
