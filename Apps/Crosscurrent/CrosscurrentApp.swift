import CrosscurrentBrowser
import CrosscurrentConnectors
import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentIntelligence
import CrosscurrentIPC
import CrosscurrentModels
import CrosscurrentRanking
import CrosscurrentSearch
import CrosscurrentStorage
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications

@main
struct CrosscurrentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(Self.fixtureColorScheme)
                .frame(minWidth: 900, minHeight: 620)
                .tint(CrosscurrentColor.accent)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.reconcileGenerations() } }
                }
                .onOpenURL { model.handleDeepLink($0) }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Today") { model.manualRefreshToday() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 720, height: 540)
        }
    }

    private static var fixtureColorScheme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--fixture-appearance"), arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1].lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarDestination? = .today
    @Published var selectedEventID: EventID?
    @Published var events: [EventCardModel] = []
    @Published var digestSections: [DigestSection: [EventCardModel]] = [:]
    @Published var sourcePreview: SourceDiscoveryPreview?
    @Published var sourceDiscoveryInProgress = false
    @Published var digestRevisionReason: DigestRevisionReason = .initialDaily
    @Published var digestUpdatedAt = Date.now
    @Published var providerConfigured = false
    @Published var publicCloudConsent = false
    @Published var backgroundState = String(localized: "Checking…")
    @Published var browserWorkerState = String(localized: "Checking…")
    @Published var startupError: String?
    @Published var canonicalGeneration: Int64 = 0
    @Published var updateStatus = String(localized: "Release feed not configured")
    @Published var dailyBriefing = Calendar.autoupdatingCurrent.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @Published var additionalBriefings: [Date] = []
    @Published var sources: [StoredSourceSnapshot] = []
    @Published var people: [StoredEntitySnapshot] = []
    @Published var topics: [StoredTopicSnapshot] = []
    @Published var savedEventIDs: Set<EventID> = []
    @Published var rawRetentionPolicy = RawRetentionPolicy()

    private(set) var repository: CrosscurrentRepository?
    private let updaterController: SPUStandardUpdaterController
    private var refreshExecutor: RefreshJobExecutor?
    private var eventMaintainer: EvidenceEventMaintainer?
    private var correctionService: ManualEventCorrectionService?
    private var todayCoordinator: TodayCoordinator?
    private var indexCoordinator: DerivedIndexCoordinator?
    private var searchStore: DerivedSearchStore?
    private var discoveryService: SourceDiscoveryService?
    private var browserClient: BrowserCreatorSessionXPCClient?
    private var observationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var observedGenerations: [ChangeDomain: Int64] = [:]
    private let keychain = KeychainSecretStore()
    private var providerConfigurations: [ProviderConfigurationRecord] = []
    private var pendingBrowserAccounts: [AuthenticatedCreatorPlatform: ConnectorAccountID] = [:]

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let configured = URL(string: feed)?.scheme == "https" && !key.isEmpty
        updaterController = SPUStandardUpdaterController(startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: nil)
        updateStatus = configured ? String(localized: "Automatic signed updates enabled") : String(localized: "Release feed not configured")
        #if DEBUG
        if Self.fixtureState != "off" { events = FixtureLibrary.events }
        #endif
    }

    func start() async {
        guard repository == nil else { return }
        do {
            let locations: DatabaseLocations
            let teamID = Bundle.main.object(forInfoDictionaryKey: "CrosscurrentTeamIdentifier") as? String ?? ""
            if !teamID.isEmpty, let group = try? DatabaseLocations.appGroup() {
                locations = group
            } else {
                // Unsigned screenshot/test builds cannot prove App Group membership and
                // macOS container protection may prompt when they touch shared Library
                // locations. Production-signed builds always take the App Group branch.
                #if DEBUG
                let developmentContainer = Self.fixtureContainer ?? FileManager.default.temporaryDirectory
                    .appending(path: "Crosscurrent-Development", directoryHint: .isDirectory)
                #else
                let developmentContainer = FileManager.default.temporaryDirectory
                    .appending(path: "Crosscurrent-Development", directoryHint: .isDirectory)
                #endif
                locations = DatabaseLocations(container: developmentContainer)
            }
            let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
            let repository = CrosscurrentRepository(database: database, writerInstance: "main-\(UUID().uuidString.lowercased())")
            self.repository = repository
            let blobStore = CanonicalBlobStore(locations: locations, repository: repository)
            let http = ArchivingConnectorHTTPClient(repository: repository, blobStore: blobStore)
            let browser = BrowserCreatorSessionXPCClient(teamID: teamID.isEmpty ? "TEAMID_REQUIRED" : teamID, signingMode: CCSigningEnvironment.currentMode)
            browserClient = browser
            let connectors = await ConnectorCatalog.production(browser: browser, http: http)
            refreshExecutor = RefreshJobExecutor(repository: repository, connectors: connectors, blobStore: blobStore, http: http)
            discoveryService = SourceDiscoveryService(repository: repository, connectors: connectors, blobStore: blobStore, http: http)
            let maintainer = EvidenceEventMaintainer(repository: repository)
            eventMaintainer = maintainer
            correctionService = ManualEventCorrectionService(repository: repository)
            let today = TodayCoordinator(repository: repository)
            todayCoordinator = today
            let index = try DerivedIndexCoordinator(repository: repository, directory: locations.derivedSearch)
            indexCoordinator = index
            searchStore = await index.store
            let shareImporter = ShareInboxImporter(locations: locations, repository: repository, leaseOwner: "main-share-import")
            _ = try await shareImporter.importAvailable()
            #if DEBUG
            if Self.fixtureState != "off" { try await seedDevelopmentLibrary(repository) }
            #endif
            for prompt in BundledPromptCatalog.all {
                _ = try await repository.savePrompt(template: prompt.template, revision: prompt.revision, makeActive: true, idempotencyKey: "bundled-prompt:\(prompt.revision.id)")
            }
            providerConfigurations = try await repository.providerConfigurations()
            providerConfigured = providerConfigurations.contains(where: \.enabled)
            if let policyData = try await repository.preferenceData(forKey: Self.aiPolicyKey),
               let policy = try? JSONDecoder().decode(AIContentPolicy.self, from: policyData) {
                publicCloudConsent = !policy.publicCloudProviders.isEmpty
            }
            if let saved = try await repository.preferenceData(forKey: Self.briefingScheduleKey),
               let schedule = try? JSONDecoder().decode(BriefingSchedule.self, from: saved) {
                dailyBriefing = Calendar.autoupdatingCurrent.date(bySettingHour: schedule.dailyTime.hour, minute: schedule.dailyTime.minute, second: 0, of: .now) ?? dailyBriefing
                additionalBriefings = schedule.additionalTimes.compactMap {
                    Calendar.autoupdatingCurrent.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: .now)
                }
            }
            if let data = try await repository.preferenceData(forKey: Self.rawRetentionPolicyKey),
               let policy = try? JSONDecoder().decode(RawRetentionPolicy.self, from: data) {
                rawRetentionPolicy = policy
            }
            _ = try await maintainer.run()
            if let update = try await today.update(trigger: .opening, schedule: briefingSchedule) {
                digestRevisionReason = update.revision.reason
                digestUpdatedAt = update.revision.createdAt
            }
            _ = try await index.synchronize()
            try await reloadCanonicalEvents()
            try await reloadCanonicalLibrary()
            backgroundState = CrosscurrentServices.agent.status.displayName
            browserWorkerState = CrosscurrentServices.browser.status.displayName
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await reconcileGenerations()
            observationTask = Task { [weak self, repository] in
                for await _ in await repository.wakeHints() {
                    guard !Task.isCancelled else { break }
                    await self?.reconcileGenerations()
                }
            }
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await self?.reconcileGenerations()
                }
            }
        } catch {
            startupError = error.localizedDescription
            backgroundState = String(localized: "Foreground only")
        }
    }

    func open(_ event: EventCardModel) {
        selectedEventID = event.id
        selection = .eventDetail
        Task { [repository] in
            _ = try? await repository?.recordHistory(targetKind: "event", targetID: event.id.description, revisionID: event.revisionID.description)
        }
    }

    func handleDeepLink(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "event", let value = parts.first, let uuid = UUID(uuidString: value), let event = events.first(where: { $0.id == EventID(uuid) }) {
            open(event)
        } else if url.host == "digest" {
            selection = .today
        }
    }

    func manualRefreshToday() {
        Task {
            do {
                guard let update = try await todayCoordinator?.update(trigger: .manualRefresh, schedule: briefingSchedule) else { return }
                digestRevisionReason = update.revision.reason
                digestUpdatedAt = update.revision.createdAt
                try await reloadCanonicalEvents()
            } catch { startupError = error.localizedDescription }
        }
    }

    func reconcileGenerations() async {
        guard let repository else { return }
        do {
            let current = try await repository.generations().mapValues(\.generation)
            guard current != observedGenerations else { return }
            let previous = observedGenerations
            observedGenerations = current
            canonicalGeneration = current.values.max() ?? 0
            if current[.events] != previous[.events] || current[.readState] != previous[.readState] || current[.topics] != previous[.topics] || current[.entities] != previous[.entities] {
                try await reloadCanonicalEvents()
            }
            if current[.sources] != previous[.sources] || current[.endpoints] != previous[.endpoints] || current[.entities] != previous[.entities] || current[.topics] != previous[.topics] || current[.library] != previous[.library] {
                try await reloadCanonicalLibrary()
            }
            if current[.searchInputs] != previous[.searchInputs] { _ = try await indexCoordinator?.synchronize() }
            if current[.digests] != previous[.digests], let state = try await repository.digestState(briefingDay: Calendar.autoupdatingCurrent.startOfDay(for: .now)) {
                digestRevisionReason = state.latestRevision.reason
                digestUpdatedAt = state.latestRevision.createdAt
                try await reloadCanonicalEvents()
            }
        } catch {
            startupError = error.localizedDescription
        }
    }

    func foregroundRefresh(endpointID: SourceEndpointID) async throws {
        guard let repository, let refreshExecutor else { throw CocoaError(.fileNoSuchFile) }
        let startedAt = Date.now
        let payload = try JSONEncoder().encode(RefreshJobPayload(endpointID: endpointID))
        let job = DurableJob(kind: CrosscurrentJobKind.refresh, inputHash: endpointID.description, idempotencyKey: "foreground-refresh:\(endpointID):\(UUID().uuidString.lowercased())", payload: payload)
        _ = try await repository.enqueue(job)
        guard let (leasedJob, lease) = try await repository.leaseJob(id: job.id, owner: "main-foreground", duration: 120) else {
            throw CrosscurrentStorageError.jobLeaseUnavailable
        }
        do {
            let checkpoint = try await refreshExecutor.execute(job: leasedJob, lease: lease)
            _ = try await repository.completeJob(lease, checkpoint: try JSONEncoder().encode(checkpoint))
            let maintenance = try await eventMaintainer?.run() ?? EvidenceMaintenanceResult()
            _ = try await indexCoordinator?.synchronize()
            if maintenance.eventsCreated > 0 {
                _ = try await todayCoordinator?.update(trigger: .eventChanged(EventChangeMateriality(isNewEvent: true, changeKind: .initial, importance: 0.8)), schedule: briefingSchedule)
            } else if maintenance.eventRevisionsCreated > 0 {
                _ = try await todayCoordinator?.update(trigger: .eventChanged(EventChangeMateriality(changeKind: .majorUpdate, importance: 0.8, evidenceGrowth: maintenance.eventRevisionsCreated)), schedule: briefingSchedule)
            }
            try await reloadCanonicalEvents()
        } catch {
            let retry = JobRetryClassifier.classify(error, attempt: leasedJob.attemptCount)
            _ = try? await repository.failJob(lease, retryClass: retry.name, retryAt: retry.retryAt)
            _ = try? await repository.recordSyncFailure(endpointID: endpointID, health: Self.health(for: error), errorClass: retry.name, message: error.localizedDescription, startedAt: startedAt)
            try? await reloadCanonicalLibrary()
            throw error
        }
    }

    func refresh(_ snapshot: StoredSourceSnapshot) async {
        guard let endpoint = snapshot.endpoints.first else { return }
        do { try await foregroundRefresh(endpointID: endpoint.id) }
        catch { startupError = error.localizedDescription }
    }

    func reconnect(_ endpoint: SourceEndpoint) async {
        guard let browserClient, let accountID = endpoint.accountID, let platform = Self.authenticatedPlatform(for: endpoint.connector) else {
            startupError = String(localized: "This endpoint does not have an authenticated browser profile yet. Add it again to create one.")
            return
        }
        do {
            try await browserClient.authenticate(platform: platform, accountID: accountID, allowsInteraction: true)
            let health = await browserClient.health(platform: platform, accountID: accountID)
            var updated = endpoint
            updated.health = health
            _ = try await repository?.saveEndpoint(updated)
            try await reloadCanonicalLibrary()
        } catch { startupError = error.localizedDescription }
    }

    func checkForUpdates() {
        guard updateStatus != String(localized: "Release feed not configured") else { return }
        updaterController.checkForUpdates(nil)
    }

    func openAuthenticatedOriginal(_ event: EventCardModel) async {
        guard let url = event.originalURL, let accountID = event.originalAccountID, let browserClient else { return }
        do { _ = try await browserClient.navigate(profileID: accountID.rawValue, url: url, presentsWindow: true) }
        catch { startupError = error.localizedDescription }
    }

    func promptBody(task: AITask) async -> String? {
        do { return try await repository?.activePrompt(for: task)?.revision.body }
        catch { startupError = error.localizedDescription; return nil }
    }

    func savePromptOverride(task: AITask, body: String) async -> String {
        guard let repository else { return String(localized: "Storage is not ready") }
        do {
            guard let active = try await repository.activePrompt(for: task) else {
                return String(localized: "Bundled prompt is unavailable")
            }
            let revision = PromptRevision(
                templateID: active.template.id,
                parentRevisionID: active.revision.id,
                origin: .user,
                body: body,
                variables: active.revision.variables
            )
            _ = try await repository.savePrompt(
                template: active.template,
                revision: revision,
                makeActive: true,
                idempotencyKey: "prompt-override:\(revision.id)"
            )
            return String(localized: "Override saved as a new revision")
        } catch {
            startupError = error.localizedDescription
            return error.localizedDescription
        }
    }

    func restoreBundledPrompt(task: AITask) async -> String {
        guard let repository else { return String(localized: "Storage is not ready") }
        do {
            _ = try await repository.restoreBundledPrompt(for: task)
            return String(localized: "Bundled default restored")
        } catch {
            startupError = error.localizedDescription
            return error.localizedDescription
        }
    }

    func saveProvider(kind: String, endpoint: String, model: String, secret: String) async -> String {
        guard let repository, let url = URL(string: endpoint), !model.isEmpty else { return String(localized: "Enter a valid endpoint and model.") }
        if kind == "openai", url.scheme?.lowercased() != "https" { return String(localized: "Cloud provider endpoints must use HTTPS.") }
        do {
            let existing = providerConfigurations.first(where: { $0.kind == kind })
            let id = existing?.id ?? "\(kind)-\(UUID().uuidString.lowercased())"
            let account = existing?.keychainReference.flatMap { String(data: $0, encoding: .utf8) } ?? "provider-secret:\(id)"
            if !secret.isEmpty { try await keychain.put(Data(secret.utf8), account: account) }
            let settings = AIProviderSettings(endpoint: url, model: model)
            let record = ProviderConfigurationRecord(
                id: id,
                kind: kind,
                displayName: kind == "openai" ? "OpenAI" : "Ollama",
                keychainReference: Data(account.utf8),
                configuration: try JSONEncoder().encode(settings)
            )
            _ = try await repository.saveProviderConfiguration(record)
            providerConfigurations = try await repository.providerConfigurations()
            providerConfigured = true
            if publicCloudConsent { await setPublicCloudConsent(true) }
            return String(localized: "Provider configuration saved. Secrets remain in Keychain.")
        } catch { startupError = error.localizedDescription; return error.localizedDescription }
    }

    func setPublicCloudConsent(_ allowed: Bool) async {
        publicCloudConsent = allowed
        guard let repository else { return }
        do {
            let cloudIDs = Set(providerConfigurations.filter { $0.kind == "openai" }.map(\.id))
            let policy = AIContentPolicy(publicCloudProviders: allowed ? cloudIDs : [])
            _ = try await repository.savePreferenceData(try JSONEncoder().encode(policy), forKey: Self.aiPolicyKey)
            for providerID in cloudIDs {
                _ = try await repository.recordConsent(providerID: providerID, privacy: .public, allowedTasks: Set(AITask.allCases), allowed: allowed)
            }
        } catch { startupError = error.localizedDescription }
    }

    func performAI(task: AITask, input: String, event: EventCardModel) async throws -> String {
        guard let repository, let config = providerConfigurations.first(where: \.enabled) else { throw AIProviderError.configurationRequired }
        guard let settings = try? JSONDecoder().decode(AIProviderSettings.self, from: config.configuration),
              let prompt = try await repository.activePrompt(for: task)
        else { throw AIProviderError.configurationRequired }
        let account = config.keychainReference.flatMap { String(data: $0, encoding: .utf8) }
        let secretData: Data?
        if let account { secretData = try await keychain.data(account: account) } else { secretData = nil }
        let secret = secretData.flatMap { String(data: $0, encoding: .utf8) }
        let provider: any AIProvider
        if config.kind == "openai" {
            guard let secret, !secret.isEmpty else { throw AIProviderError.configurationRequired }
            provider = OpenAIResponsesProvider(id: config.id, apiKey: secret, endpoint: settings.endpoint)
        } else {
            provider = OllamaProvider(id: config.id, endpoint: settings.endpoint, bearerToken: secret)
        }
        let policyData = try await repository.preferenceData(forKey: Self.aiPolicyKey)
        let policy = policyData.flatMap { try? JSONDecoder().decode(AIContentPolicy.self, from: $0) } ?? AIContentPolicy()
        guard policy.allows(sourceID: event.primarySourceID, privacy: event.contentPrivacy, providerID: config.id, location: provider.executionLocation) else {
            throw AIProviderError.policyDenied
        }
        let consentRevisionID: UUID?
        if provider.executionLocation == .cloud {
            let consentSourceID = event.contentPrivacy == .public ? nil : event.primarySourceID
            guard let activeConsent = try await repository.activeConsentRevision(
                providerID: config.id,
                sourceID: consentSourceID,
                privacy: event.contentPrivacy,
                task: task
            ) else {
                // AIContentPolicy is the configured intent; the immutable consent revision is
                // the auditable authorization. Both must be valid before any network request.
                throw AIProviderError.policyDenied
            }
            consentRevisionID = activeConsent
        } else {
            consentRevisionID = nil
        }
        let request = AIRequest(task: task, model: settings.model, instructions: prompt.revision.body, input: input, promptRevisionID: prompt.revision.id)
        let inputHash = HTTPMetadataRedactor.digest(Data(input.precomposedStringWithCanonicalMapping.utf8))
        let policyDecision = "allowed:\(provider.executionLocation.rawValue):\(event.contentPrivacy.rawValue)"
        let cacheIdentity = [task.rawValue, config.id, settings.model, prompt.revision.id.description, inputHash, policyDecision, consentRevisionID?.uuidString.lowercased() ?? "local"].joined(separator: "\u{1f}")
        let cacheKey = HTTPMetadataRedactor.digest(Data(cacheIdentity.utf8))
        if let cached = try await repository.cachedAICompletion(cacheKey: cacheKey) { return cached.text }
        let response = try await provider.perform(request)
        let run = GenerationRun(
            task: task,
            providerID: config.id,
            modelID: settings.model,
            promptRevisionID: prompt.revision.id,
            inputHash: inputHash,
            policyDecision: policyDecision,
            consentRevisionID: consentRevisionID
        )
        _ = try await repository.saveAICompletion(
            StoredAICompletion(text: response.text, providerRequestID: response.providerRequestID, inputTokens: response.inputTokens, outputTokens: response.outputTokens),
            run: run,
            cacheKey: cacheKey
        )
        return response.text
    }

    func setEventRead(_ event: EventCardModel) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index].readStatus = .read
        Task { [repository] in
            _ = try? await repository?.markEventSeen(eventID: event.id, revisionID: event.revisionID, ordinal: event.revisionOrdinal)
        }
    }

    func setEventUnread(_ event: EventCardModel) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index].readStatus = .unread
        Task { [repository] in _ = try? await repository?.setEventManualUnread(eventID: event.id, unread: true) }
    }

    func toggleSaved(_ event: EventCardModel) {
        let shouldSave = !savedEventIDs.contains(event.id)
        if shouldSave { savedEventIDs.insert(event.id) } else { savedEventIDs.remove(event.id) }
        Task { [repository] in _ = try? await repository?.setEventSaved(event.id, saved: shouldSave) }
    }

    func setEntityFollowed(_ snapshot: StoredEntitySnapshot, followed: Bool) {
        if let index = people.firstIndex(where: { $0.id == snapshot.id }) { people[index].entity.isFollowed = followed }
        Task { [repository] in _ = try? await repository?.setEntityFollowed(snapshot.id, followed: followed) }
    }

    func setTopicFollowed(_ snapshot: StoredTopicSnapshot, followed: Bool) {
        if let index = topics.firstIndex(where: { $0.id == snapshot.id }) { topics[index].topic.isFollowed = followed }
        Task { [repository] in _ = try? await repository?.setTopicFollowed(snapshot.id, followed: followed) }
    }

    func setSourceFollowed(_ snapshot: StoredSourceSnapshot, followed: Bool) {
        if let index = sources.firstIndex(where: { $0.id == snapshot.id }) { sources[index].source.isFollowed = followed }
        Task { [repository] in _ = try? await repository?.setSourceFollowed(snapshot.id, followed: followed) }
    }

    func setCoverage(_ snapshot: StoredSourceSnapshot, ecosystem: CoverageEcosystem) {
        let assertion = SourceCoverageAssertion(
            sourceID: snapshot.id,
            ecosystem: ecosystem,
            provenance: .user,
            confidence: .certain,
            rationale: String(localized: "User classification")
        )
        if let index = sources.firstIndex(where: { $0.id == snapshot.id }) { sources[index].coverage = assertion }
        Task { [repository] in _ = try? await repository?.saveSourceCoverage(assertion) }
    }

    func evidence(for eventID: EventID) async -> [StoredEventEvidence] {
        do { return try await repository?.eventEvidence(eventID: eventID) ?? [] }
        catch { startupError = error.localizedDescription; return [] }
    }

    func revisionHistory(for eventID: EventID) async -> [StoredEventRevisionSummary] {
        do { return try await repository?.eventRevisionHistory(eventID: eventID) ?? [] }
        catch { startupError = error.localizedDescription; return [] }
    }

    func coverageComparison(for eventID: EventID) async -> StoredCoverageComparison {
        do { return try await repository?.coverageComparison(eventID: eventID) ?? StoredCoverageComparison() }
        catch { startupError = error.localizedDescription; return StoredCoverageComparison() }
    }

    func search(_ text: String, kinds: Set<SearchDocumentKind>, includeHistory: Bool) async -> [SearchResult] {
        guard let searchStore else { return [] }
        do {
            _ = try await indexCoordinator?.synchronize()
            return try await searchStore.search(SearchQuery(text: text, kinds: kinds, includeHistory: includeHistory))
        } catch {
            startupError = error.localizedDescription
            return []
        }
    }

    func addSource(_ input: String) async -> String {
        let previewStatus = await previewSource(input)
        guard sourcePreview != nil else { return previewStatus }
        return await subscribeSourcePreview()
    }

    func previewSource(_ input: String) async -> String {
        guard let url = URL(string: input), let discoveryService else { return String(localized: "Enter a valid Source URL.") }
        sourceDiscoveryInProgress = true
        defer { sourceDiscoveryInProgress = false }
        do {
            let platform = Self.authenticatedPlatform(for: url)
            var accountID: ConnectorAccountID?
            if let platform {
                if let pending = pendingBrowserAccounts[platform] {
                    accountID = pending
                } else {
                    let created = ConnectorAccountID()
                    pendingBrowserAccounts[platform] = created
                    _ = try await repository?.saveConnectorAccount(id: created, kind: platform.connectorKind, browserProfileID: created.rawValue)
                    try await browserClient?.authenticate(platform: platform, accountID: created, allowsInteraction: true)
                    return String(localized: "Login window opened. Complete authentication, then choose Add and Refresh again.")
                }
            }
            sourcePreview = try await discoveryService.preview(.init(url: url, accountID: accountID), context: ConnectorContext(allowsUserInteraction: true))
            return String(localized: "Source found. Review it before subscribing.")
        } catch { startupError = error.localizedDescription; return error.localizedDescription }
    }

    func subscribeSourcePreview(action: SourceDiscoveryAction = .subscribe) async -> String {
        guard let preview = sourcePreview, let discoveryService else { return String(localized: "Discover a Source first.") }
        sourceDiscoveryInProgress = true
        defer { sourceDiscoveryInProgress = false }
        do {
            let selectedAction = preview.availableActions.contains(action) ? action : (preview.availableActions.first ?? .subscribe)
            let committed = try await discoveryService.commit(preview, action: selectedAction)
            sourcePreview = nil
            if let platform = Self.authenticatedPlatform(for: preview.inputURL) { pendingBrowserAccounts[platform] = nil }
            try await reloadCanonicalLibrary()
            if selectedAction != .importOnce, let endpoint = committed.endpointIDs.first { try await foregroundRefresh(endpointID: endpoint) }
            return selectedAction == .importOnce ? String(localized: "Page imported.") : String(localized: "Source added and refreshed.")
        } catch { startupError = error.localizedDescription; return error.localizedDescription }
    }

    func clearSourcePreview() { sourcePreview = nil }

    func importOPML(from url: URL) async -> String {
        guard let repository, let discoveryService else { return String(localized: "Storage is not ready") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try await OPMLImportService(repository: repository, discovery: discoveryService)
                .importData(data, context: ConnectorContext(allowsUserInteraction: true))
            try await reloadCanonicalLibrary()
            if result.failures.isEmpty {
                return String(localized: "Imported \(result.sourceCount) Sources in \(result.folderCount) folders.")
            }
            return String(localized: "Imported \(result.sourceCount) Sources; \(result.failures.count) entries need attention.")
        } catch {
            startupError = error.localizedDescription
            return error.localizedDescription
        }
    }

    func exportOPML() async throws -> Data {
        guard let repository else { throw CocoaError(.fileNoSuchFile) }
        return try await OPMLExportService(repository: repository).exportData()
    }

    func saveDailyBriefing(_ date: Date) async {
        dailyBriefing = date
        await saveBriefingSchedule()
    }

    func addAdditionalBriefing() async {
        let nextHour = (Calendar.autoupdatingCurrent.component(.hour, from: dailyBriefing) + 6) % 24
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: nextHour, minute: 0, second: 0, of: .now) ?? .now
        additionalBriefings.append(date)
        await saveBriefingSchedule()
    }

    func saveRawRetentionPolicy(_ policy: RawRetentionPolicy) async {
        rawRetentionPolicy = policy
        guard let repository else { return }
        do {
            _ = try await repository.savePreferenceData(try JSONEncoder().encode(policy), forKey: Self.rawRetentionPolicyKey)
            _ = try await repository.expireRawFetches(policy: policy)
        } catch { startupError = error.localizedDescription }
    }

    func setAdditionalBriefing(at index: Int, date: Date) async {
        guard additionalBriefings.indices.contains(index) else { return }
        additionalBriefings[index] = date
        await saveBriefingSchedule()
    }

    func removeAdditionalBriefing(at index: Int) async {
        guard additionalBriefings.indices.contains(index) else { return }
        additionalBriefings.remove(at: index)
        await saveBriefingSchedule()
    }

    private func saveBriefingSchedule() async {
        guard let repository else { return }
        do {
            _ = try await repository.savePreferenceData(try JSONEncoder().encode(briefingSchedule), forKey: Self.briefingScheduleKey)
        } catch { startupError = error.localizedDescription }
    }

    var briefingSchedule: BriefingSchedule {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: dailyBriefing)
        let additional = additionalBriefings.map {
            let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: $0)
            return BriefingTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
        return BriefingSchedule(dailyTime: BriefingTime(hour: components.hour ?? 8, minute: components.minute ?? 0), additionalTimes: additional)
    }

    private func reloadCanonicalEvents() async throws {
        guard let repository else { return }
        let snapshots = try await repository.currentEventSnapshots(limit: 500)
        guard !snapshots.isEmpty else {
            events = []
            digestSections = [:]
            return
        }
        let cards = snapshots.map(Self.eventCard)
        events = cards
        let byRevision = Dictionary(uniqueKeysWithValues: cards.map { ($0.revisionID, $0) })
        if let state = try await repository.digestState(briefingDay: Calendar.autoupdatingCurrent.startOfDay(for: .now)) {
            digestSections = Dictionary(grouping: state.latestRevision.entries, by: \.section).mapValues { entries in
                entries.sorted { $0.rank < $1.rank }.compactMap { byRevision[$0.eventRevisionID] }
            }
        } else {
            digestSections = [:]
        }
    }

    private func reloadCanonicalLibrary() async throws {
        guard let repository else { return }
        async let loadedSources = repository.sourceSnapshots()
        async let loadedPeople = repository.entitySnapshots()
        async let loadedTopics = repository.topicSnapshots()
        async let loadedSaved = repository.savedEventIDs()
        sources = try await loadedSources
        people = try await loadedPeople
        topics = try await loadedTopics
        savedEventIDs = try await loadedSaved
    }

    private static func eventCard(_ snapshot: StoredEventSnapshot) -> EventCardModel {
        let revision = snapshot.aggregate.revision
        var reasons: [RankingReason] = [.primarySource]
        if snapshot.independentSourceCount >= 2 { reasons.append(.independentCoverage) }
        if !snapshot.followedPeople.isEmpty { reasons.append(.followedPerson) }
        if snapshot.chinaGlobalCoverageSufficient { reasons.append(.chinaGlobalCoverage) }
        let escaped = snapshot.readerText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n\n", with: "</p><p>")
        return EventCardModel(
            id: snapshot.aggregate.event.id,
            revisionID: revision.id,
            revisionOrdinal: revision.ordinal,
            primaryItemRevisionID: snapshot.primaryItemRevisionID,
            primarySourceID: snapshot.primarySourceID,
            contentPrivacy: snapshot.contentPrivacy,
            primarySegmentLineageID: snapshot.aggregate.memberships.first(where: { $0.id == snapshot.aggregate.revision.primaryMembershipAssertionID })?.segmentLineageID ?? snapshot.aggregate.memberships.first!.segmentLineageID,
            membershipCount: snapshot.aggregate.memberships.count,
            title: revision.title,
            summary: revision.summary,
            primarySource: snapshot.primarySourceName,
            sourceCount: snapshot.sourceCount,
            independentSourceCount: snapshot.independentSourceCount,
            topics: snapshot.topics,
            followedPeople: snapshot.followedPeople,
            date: revision.endedAt ?? revision.startedAt ?? revision.createdAt,
            readStatus: snapshot.readStatus,
            score: min(1, 0.5 + Double(snapshot.independentSourceCount) * 0.06),
            reasons: reasons,
            bodyHTML: snapshot.readerHTML ?? "<p>\(escaped)</p>",
            originalURL: snapshot.originalURL,
            originalAccountID: snapshot.originalAccountID
        )
    }

    private static let briefingScheduleKey = "today.briefing-schedule.v1"
    private static let aiPolicyKey = "ai.content-policy.v1"
    static let rawRetentionPolicyKey = "retention.raw-policy.v1"

    private static func authenticatedPlatform(for url: URL) -> AuthenticatedCreatorPlatform? {
        let host = url.host?.lowercased() ?? ""
        if host == "mp.weixin.qq.com" || host.hasSuffix(".weixin.qq.com") { return .weChatOfficialAccount }
        if host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") || host == "xhslink.com" { return .xiaohongshu }
        if host == "x.com" || host.hasSuffix("twitter.com") { return .x }
        if host == "weibo.com" || host.hasSuffix(".weibo.com") { return .weibo }
        if host == "zhihu.com" || host.hasSuffix(".zhihu.com") { return .zhihu }
        return nil
    }

    private static func authenticatedPlatform(for connector: ConnectorKind) -> AuthenticatedCreatorPlatform? {
        switch connector {
        case .weChatOfficialAccount: .weChatOfficialAccount
        case .xiaohongshu: .xiaohongshu
        case .x: .x
        case .weibo: .weibo
        case .zhihu: .zhihu
        default: nil
        }
    }

    private static func health(for error: Error) -> ConnectorHealth {
        switch error {
        case ConnectorError.authenticationRequired, ConnectorError.interactionRequired: .authenticationRequired
        case ConnectorError.rateLimited: .rateLimited
        case ConnectorError.platformChanged: .platformChanged
        case ConnectorError.policyDenied: .disabled
        default: .temporarilyUnavailable
        }
    }

    #if DEBUG
    private static var fixtureState: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--fixture-state"), arguments.indices.contains(index + 1) else { return "off" }
        return arguments[index + 1]
    }

    private static var fixtureContainer: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--fixture-container"), arguments.indices.contains(index + 1) else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    private func seedDevelopmentLibrary(_ repository: CrosscurrentRepository) async throws {
        struct SourceFixture {
            var id: UUID; var revisionID: UUID; var endpointID: UUID
            var name: String; var kind: SourceKind; var connector: ConnectorKind
            var access: AccessRequirement; var privacy: ContentPrivacy; var coverage: CoverageEcosystem
            var health: ConnectorHealth; var url: String
        }
        let fixtures = [
            SourceFixture(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, revisionID: UUID(uuidString: "21000000-0000-0000-0000-000000000001")!, endpointID: UUID(uuidString: "22000000-0000-0000-0000-000000000001")!, name: "Model Lab", kind: .publication, connector: .rss, access: .anonymous, privacy: .public, coverage: .globalFocused, health: .healthy, url: "https://example.com/model-lab.xml"),
            SourceFixture(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!, revisionID: UUID(uuidString: "21000000-0000-0000-0000-000000000002")!, endpointID: UUID(uuidString: "22000000-0000-0000-0000-000000000002")!, name: "城市观察 City Brief", kind: .publication, connector: .weChatOfficialAccount, access: .authenticated, privacy: .public, coverage: .chinaFocused, health: .authenticationRequired, url: "https://mp.weixin.qq.com/s/example"),
            SourceFixture(id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!, revisionID: UUID(uuidString: "21000000-0000-0000-0000-000000000003")!, endpointID: UUID(uuidString: "22000000-0000-0000-0000-000000000003")!, name: "Mira Chen / 陈米拉", kind: .person, connector: .xiaohongshu, access: .authenticated, privacy: .public, coverage: .mixed, health: .platformChanged, url: "https://www.xiaohongshu.com/user/profile/example"),
        ]
        for fixture in fixtures {
            let sourceID = SourceID(fixture.id)
            let revisionID = SourceRevisionID(fixture.revisionID)
            let source = LogicalSource(id: sourceID, currentRevisionID: revisionID, kind: fixture.kind)
            let revision = SourceRevision(id: revisionID, sourceID: sourceID, displayName: fixture.name, summary: "Fixture-backed production shell data")
            let endpoint = SourceEndpoint(id: SourceEndpointID(fixture.endpointID), sourceID: sourceID, connector: fixture.connector, externalID: fixture.url, canonicalURL: URL(string: fixture.url), accessRequirement: fixture.access, contentPrivacy: fixture.privacy, health: fixture.health, lastSuccessfulSync: .now.addingTimeInterval(-3_600))
            _ = try await repository.saveSource(source, revision: revision, endpoints: [endpoint], aiClassification: SourceAIClassification(sourceID: sourceID, accessRequirement: fixture.access, contentPrivacy: fixture.privacy, provenance: .connector, confidence: .certain), coverage: SourceCoverageAssertion(sourceID: sourceID, ecosystem: fixture.coverage, provenance: .user, confidence: .certain), idempotencyKey: "debug-fixture-source:\(sourceID)")
        }
        let personID = EntityID(UUID(uuidString: "23000000-0000-0000-0000-000000000001")!)
        let personRevisionID = EntityRevisionID(UUID(uuidString: "24000000-0000-0000-0000-000000000001")!)
        let person = Entity(id: personID, currentRevisionID: personRevisionID, kind: .person, displayName: "Mira Chen", isFollowed: true)
        _ = try await repository.saveEntity(person, revision: EntityRevision(id: personRevisionID, entityID: personID, displayName: "Mira Chen", summary: "Independent researcher and maintainer"), aliases: [EntityAlias(entityID: personID, value: "陈米拉", languageCode: "zh-Hans", provenance: .user, confidence: .certain)], idempotencyKey: "debug-fixture-person")
        _ = try await repository.saveSourceEntityRelationship(SourceEntityRelationship(sourceID: SourceID(fixtures[2].id), entityID: personID, role: .represents, provenance: .user, confidence: .certain), idempotencyKey: "debug-fixture-source-person")
        for (index, name) in ["AI", "本地模型", "WebKit", "SQLite"].enumerated() {
            let topicID = TopicID(UUID(uuidString: "25000000-0000-0000-0000-00000000000\(index + 1)")!)
            let revisionID = TopicRevisionID(UUID(uuidString: "26000000-0000-0000-0000-00000000000\(index + 1)")!)
            _ = try await repository.saveTopic(Topic(id: topicID, currentRevisionID: revisionID, isFollowed: index < 2), revision: TopicRevision(id: revisionID, topicID: topicID, name: name), idempotencyKey: "debug-fixture-topic:\(index)")
        }
        _ = try await repository.setEventSaved(FixtureLibrary.events[4].id, saved: true)
    }
    #endif

    func confirmPrimaryMembership(_ event: EventCardModel) async {
        do { try await correctionService?.confirm(eventID: event.id, lineageID: event.primarySegmentLineageID) }
        catch { startupError = error.localizedDescription }
    }

    func rejectPrimaryMembership(_ event: EventCardModel) async {
        do {
            try await correctionService?.reject(eventID: event.id, lineageID: event.primarySegmentLineageID)
            startupError = String(localized: "Membership rejection saved; reconciliation will preserve it.")
        } catch { startupError = error.localizedDescription }
    }

    func splitPrimaryMembership(_ event: EventCardModel) async {
        do {
            _ = try await correctionService?.split(eventID: event.id, movingLineageID: event.primarySegmentLineageID)
            try await reloadCanonicalEvents()
            _ = try await indexCoordinator?.synchronize()
            _ = try await todayCoordinator?.update(trigger: .eventChanged(EventChangeMateriality(changeKind: .split, importance: 1, lineageChanged: true)), schedule: briefingSchedule)
        } catch { startupError = error.localizedDescription }
    }

    func merge(_ event: EventCardModel, with other: EventCardModel) async {
        do {
            guard let survivor = try await correctionService?.merge(eventIDs: [event.id, other.id]) else { return }
            try await reloadCanonicalEvents()
            selectedEventID = survivor
            _ = try await indexCoordinator?.synchronize()
            _ = try await todayCoordinator?.update(trigger: .eventChanged(EventChangeMateriality(changeKind: .merge, importance: 1, lineageChanged: true)), schedule: briefingSchedule)
        } catch { startupError = error.localizedDescription }
    }
}

private struct AIProviderSettings: Codable {
    var endpoint: URL
    var model: String
}

enum CrosscurrentServices {
    static var agent: SMAppService { .agent(plistName: "com.chonghanqin.crosscurrent.agent.plist") }
    static var browser: SMAppService { .agent(plistName: "com.chonghanqin.crosscurrent.browser.plist") }
}

private extension SMAppService.Status {
    var displayName: String {
        switch self {
        case .enabled: String(localized: "Enabled")
        case .requiresApproval: String(localized: "Approval required")
        case .notRegistered: String(localized: "Not enabled")
        case .notFound: String(localized: "Unavailable")
        @unknown default: String(localized: "Unknown")
        }
    }
}
