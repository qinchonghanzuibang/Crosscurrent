import AppKit
import FeedFlowBrowser
import FeedFlowConnectors
import FeedFlowDiagnostics
import FeedFlowDomain
import FeedFlowIngestion
import FeedFlowIntelligence
import FeedFlowIPC
import FeedFlowRanking
import FeedFlowSearch
import FeedFlowStorage
import Foundation
import UserNotifications

@main
enum FeedFlowAgentMain {
    static func main() {
        let runtime = AgentRuntime()
        runtime.start()
        RunLoop.main.run()
    }
}

final class AgentRuntime: NSObject, @unchecked Sendable {
    private var repository: FeedFlowRepository?
    private var listener: NSXPCListener?
    private var listenerDelegate: SecureXPCListenerDelegate?
    private var jobTask: Task<Void, Never>?

    func start() {
        do {
            let locations = try DatabaseLocations.appGroup()
            let database = try FeedFlowDatabase.open(at: locations, role: .agent)
            let repository = FeedFlowRepository(database: database, writerInstance: "agent-\(UUID().uuidString.lowercased())")
            self.repository = repository
            startListener(repository: repository)
            let teamID = Bundle.main.object(forInfoDictionaryKey: "FeedFlowTeamIdentifier") as? String ?? "TEAMID_REQUIRED"
            jobTask = Task {
                do {
                    let browser = BrowserCreatorSessionXPCClient(teamID: teamID, signingMode: FFSigningEnvironment.currentMode)
                    let blobStore = CanonicalBlobStore(locations: locations, repository: repository)
                    let http = ArchivingConnectorHTTPClient(repository: repository, blobStore: blobStore)
                    let registry = await ConnectorCatalog.production(browser: browser, http: http)
                    let refreshExecutor = RefreshJobExecutor(repository: repository, connectors: registry, blobStore: blobStore)
                    let shareImporter = ShareInboxImporter(locations: locations, repository: repository, leaseOwner: "agent-share-import")
                    let maintainer = EvidenceEventMaintainer(repository: repository)
                    let today = TodayCoordinator(repository: repository)
                    let index = try DerivedIndexCoordinator(repository: repository, directory: locations.derivedSearch)
                    let garbageCollector = BlobGarbageCollector(database: database)
                    await workLoop(repository: repository, registry: registry, refreshExecutor: refreshExecutor, shareImporter: shareImporter, maintainer: maintainer, today: today, index: index, garbageCollector: garbageCollector)
                } catch {
                    FeedFlowLog.app.error("Agent initialization failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            FeedFlowLog.app.info("FeedFlowAgent started")
        } catch {
            FeedFlowLog.app.error("FeedFlowAgent waiting: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.start() }
        }
    }

    private func startListener(repository: FeedFlowRepository) {
        let teamID = Bundle.main.object(forInfoDictionaryKey: "FeedFlowTeamIdentifier") as? String ?? "TEAMID_REQUIRED"
        let expected = FFCodeSigningIdentity(teamID: teamID, bundleID: "com.chonghanqin.feedflow", signingMode: FFSigningEnvironment.currentMode)
        let delegate = SecureXPCListenerDelegate(expectedPeer: expected) { AgentControlService(repository: repository) }
        let listener = NSXPCListener(machServiceName: "com.chonghanqin.feedflow.agent.control")
        listener.delegate = delegate
        listener.resume()
        self.listenerDelegate = delegate
        self.listener = listener
    }

    private func workLoop(repository: FeedFlowRepository, registry: ConnectorRegistry, refreshExecutor: RefreshJobExecutor, shareImporter: ShareInboxImporter, maintainer: EvidenceEventMaintainer, today: TodayCoordinator, index: DerivedIndexCoordinator, garbageCollector: BlobGarbageCollector) async {
        var lastMaintenanceDay: Date?
        var lastRefreshScheduling = Date.distantPast
        while !Task.isCancelled {
            do {
                _ = try await shareImporter.importAvailable()
                let schedule = try await briefingSchedule(repository: repository)
                let now = Date.now
                if now.timeIntervalSince(lastRefreshScheduling) >= 60 {
                    try await enqueueDueRefreshes(repository: repository, registry: registry, now: now)
                    lastRefreshScheduling = now
                }
                let todayStart = Calendar.autoupdatingCurrent.startOfDay(for: now)
                if lastMaintenanceDay != todayStart {
                    let policy = try await rawRetentionPolicy(repository: repository)
                    _ = try await repository.expireRawFetches(now: now, policy: policy)
                    _ = try await garbageCollector.run(now: now)
                    lastMaintenanceDay = todayStart
                }
                let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now)
                let currentTime = BriefingTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                if currentTime == schedule.dailyTime || schedule.additionalTimes.contains(currentTime) {
                    _ = try await today.update(trigger: .scheduled(currentTime), schedule: schedule, now: now)
                }
                let eligible: Set<String> = [FeedFlowJobKind.refresh, FeedFlowJobKind.importInbox, FeedFlowJobKind.index, FeedFlowJobKind.rank, FeedFlowJobKind.today, FeedFlowJobKind.notify]
                if let (job, lease) = try await repository.leaseNextJob(owner: "agent", eligibleKinds: eligible, duration: 120) {
                    do {
                        let checkpoint: Data?
                        switch job.kind {
                        case FeedFlowJobKind.notify:
                            try await deliverNotification(job.payload)
                            checkpoint = nil
                        case FeedFlowJobKind.refresh:
                            let refresh = try await refreshExecutor.execute(job: job, lease: lease)
                            let maintenance = try await maintainer.run()
                            _ = try await index.synchronize()
                            if maintenance.eventsCreated > 0 {
                                let update = try await today.update(trigger: .eventChanged(EventChangeMateriality(isNewEvent: true, changeKind: .initial, importance: 0.8)), schedule: schedule)
                                try await enqueueNotificationIfNeeded(update, repository: repository)
                            } else if maintenance.eventRevisionsCreated > 0 {
                                let update = try await today.update(trigger: .eventChanged(EventChangeMateriality(changeKind: .majorUpdate, importance: 0.8, evidenceGrowth: maintenance.eventRevisionsCreated)), schedule: schedule)
                                try await enqueueNotificationIfNeeded(update, repository: repository)
                            }
                            checkpoint = try JSONEncoder().encode(refresh)
                        case FeedFlowJobKind.importInbox:
                            checkpoint = try JSONEncoder().encode(await shareImporter.importAvailable())
                        case FeedFlowJobKind.index:
                            checkpoint = try JSONEncoder().encode(await index.synchronize(force: true))
                        case FeedFlowJobKind.rank:
                            checkpoint = try JSONEncoder().encode(await maintainer.run())
                        case FeedFlowJobKind.today:
                            let trigger = (try? JSONDecoder().decode(TodayTrigger.self, from: job.payload)) ?? .opening
                            checkpoint = try JSONEncoder().encode(await today.update(trigger: trigger, schedule: schedule))
                        default:
                            throw JobExecutionError.unsupportedKind(job.kind)
                        }
                        _ = try await repository.completeJob(lease, checkpoint: checkpoint)
                    } catch {
                        let retry = JobRetryClassifier.classify(error, attempt: job.attemptCount)
                        _ = try? await repository.failJob(lease, retryClass: retry.name, retryAt: retry.retryAt)
                    }
                } else {
                    try await Task.sleep(for: .seconds(5))
                }
            } catch {
                FeedFlowLog.app.error("Agent job loop: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func enqueueDueRefreshes(repository: FeedFlowRepository, registry: ConnectorRegistry, now: Date) async throws {
        let bucket = Int(now.timeIntervalSince1970 / (30 * 60))
        let snapshots = try await repository.sourceSnapshots()
        for snapshot in snapshots where !snapshot.source.isArchived {
            for endpoint in snapshot.endpoints {
                guard endpoint.lastSuccessfulSync.map({ now.timeIntervalSince($0) >= 30 * 60 }) ?? true,
                      await registry.connector(for: endpoint.connector) != nil
                else { continue }
                let payload = try JSONEncoder().encode(RefreshJobPayload(endpointID: endpoint.id))
                _ = try await repository.enqueue(DurableJob(
                    kind: FeedFlowJobKind.refresh,
                    inputHash: endpoint.id.description,
                    idempotencyKey: "scheduled-refresh:\(endpoint.id):\(bucket)",
                    payload: payload
                ))
            }
        }
    }

    private func briefingSchedule(repository: FeedFlowRepository) async throws -> BriefingSchedule {
        guard let data = try await repository.preferenceData(forKey: "today.briefing-schedule.v1") else { return BriefingSchedule() }
        return (try? JSONDecoder().decode(BriefingSchedule.self, from: data)) ?? BriefingSchedule()
    }

    private func rawRetentionPolicy(repository: FeedFlowRepository) async throws -> RawRetentionPolicy {
        guard let data = try await repository.preferenceData(forKey: "retention.raw-policy.v1") else { return RawRetentionPolicy() }
        return (try? JSONDecoder().decode(RawRetentionPolicy.self, from: data)) ?? RawRetentionPolicy()
    }

    private func enqueueNotificationIfNeeded(_ update: TodayUpdate?, repository: FeedFlowRepository) async throws {
        guard let update, update.created, update.revision.reason == .materialEvent || update.revision.reason == .majorUpdate else { return }
        let payload = AgentNotificationPayload(
            title: update.revision.reason == .materialEvent ? "New material Event" : "Major Event update",
            body: "Today has a reader-visible update backed by newly committed evidence.",
            deepLink: "feedflow://digest/\(update.revision.id)"
        )
        let data = try JSONEncoder().encode(payload)
        _ = try await repository.enqueue(DurableJob(kind: FeedFlowJobKind.notify, inputHash: update.revision.id.description, idempotencyKey: "notify:digest:\(update.revision.id)", payload: data))
    }

    private func deliverNotification(_ payload: Data) async throws {
        let value = try JSONDecoder().decode(AgentNotificationPayload.self, from: payload)
        let content = UNMutableNotificationContent()
        content.title = value.title
        content.body = value.body
        content.userInfo = ["deepLink": value.deepLink]
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

private struct AgentNotificationPayload: Codable {
    var title: String
    var body: String
    var deepLink: String
}

final class AgentControlService: NSObject, FeedFlowXPCService, @unchecked Sendable {
    private let repository: FeedFlowRepository
    init(repository: FeedFlowRepository) { self.repository = repository }

    func handle(_ envelope: FFIPCEnvelope, withReply reply: @escaping (FFIPCEnvelope?, NSError?) -> Void) {
        let replyBox = AgentReply(invoke: reply)
        Task {
            do {
                switch envelope.type {
                case .health:
                    let generations = try await repository.generations().mapValues(\.generation)
                    let data = try FFIPCPayloadCodec.encode(generations)
                    replyBox.invoke(try FFIPCEnvelope(messageType: .health, requestID: envelope.requestID, traceID: envelope.traceID, idempotencyKey: envelope.idempotencyKey, payload: data), nil)
                case .enqueueJob:
                    let job = try FFIPCPayloadCodec.decode(DurableJob.self, from: envelope.payload)
                    _ = try await repository.enqueue(job)
                    replyBox.invoke(try FFIPCEnvelope(messageType: .enqueueJob, requestID: envelope.requestID, traceID: envelope.traceID, idempotencyKey: envelope.idempotencyKey, payload: Data()), nil)
                default:
                    throw FFIPCError.invalidPayload
                }
            } catch { replyBox.invoke(nil, error as NSError) }
        }
    }
}

private struct AgentReply: @unchecked Sendable {
    var invoke: (FFIPCEnvelope?, NSError?) -> Void
}
