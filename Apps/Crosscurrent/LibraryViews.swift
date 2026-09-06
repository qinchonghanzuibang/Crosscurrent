import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentModels
import CrosscurrentReader
import CrosscurrentSearch
import CrosscurrentStorage
import SwiftUI
import UniformTypeIdentifiers

enum FollowingFilter: String, CaseIterable, Identifiable {
    case all, sources, people, topics
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .all: "All"; case .sources: "Sources"; case .people: "People"; case .topics: "Topics" }
    }
}

struct LibraryPageShell<Controls: View, Content: View>: View {
    var pageTitle: LocalizedStringKey
    var subtitle: LocalizedStringKey
    var controls: Controls
    var content: Content

    init(
        _ pageTitle: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder content: () -> Content
    ) {
        self.pageTitle = pageTitle
        self.subtitle = subtitle
        self.controls = controls()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pageTitle).font(.largeTitle.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct FollowingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LibraryPageShell("Following", subtitle: "Things I follow") {
            Picker("Following", selection: $model.followingFilter) {
                ForEach(FollowingFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
        } content: {
            switch model.followingFilter {
            case .all: AllFollowingView()
            case .sources: SourcesView(embedded: true)
            case .people: PeopleView(embedded: true)
            case .topics: TopicsView(embedded: true)
            }
        }
        .toolbar {
            ToolbarItem { Button("Add Source", systemImage: "plus") { model.showAddSource() } }
        }
    }
}

private struct AllFollowingView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let sources = model.sources.filter(\.source.isFollowed)
        let people = model.people.filter(\.entity.isFollowed)
        let topics = model.topics.filter(\.topic.isFollowed)
        if sources.isEmpty && people.isEmpty && topics.isEmpty {
            ContentUnavailableView("Nothing Followed Yet", systemImage: "person.crop.circle.badge.plus", description: Text("Follow a Source, person, or Topic to see it here."))
        } else {
            List {
                if !sources.isEmpty {
                    Section("Sources") { ForEach(sources) { source in
                        Button { model.openLibraryObject(source.id.description, kind: .source) } label: {
                            HStack { SourceMonogram(source.revision.displayName, size: 30); Text(source.revision.displayName); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        }.buttonStyle(.plain)
                    } }
                }
                if !people.isEmpty {
                    Section("People") { ForEach(people) { person in
                        Button { model.openLibraryObject(person.id.description, kind: .person) } label: {
                            HStack { SourceMonogram(person.revision.displayName, size: 30); Text(person.revision.displayName); Spacer(); Text(person.sourceNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.buttonStyle(.plain)
                    } }
                }
                if !topics.isEmpty {
                    Section("Topics") { ForEach(topics) { topic in
                        Button { model.openLibraryObject(topic.id.description, kind: .topic) } label: {
                            HStack { Text("#").foregroundStyle(CrosscurrentColor.accent); Text(topic.revision.name); Spacer(); Text(String.localizedStringWithFormat(String(localized: "%lld Events"), topic.eventCount)).font(.caption).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    } }
                }
            }.listStyle(.inset)
        }
    }
}

struct SourcesView: View {
    var embedded = false
    var followedOnly = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var adding = false
    @State private var url = ""
    @State private var status = ""
    @State private var selectedAction: SourceDiscoveryAction = .subscribe
    @State private var importingOPML = false
    @State private var exportingOPML = false
    @State private var exportDocument = OPMLExportDocument(data: Data())
    @State private var selectedStarterURLs: Set<String> = []
    @State private var discoveryTask: Task<Void, Never>?
    @State private var diagnosticSource: StoredSourceSnapshot?
    private var visibleSources: [StoredSourceSnapshot] {
        followedOnly ? model.sources.filter(\.source.isFollowed) : model.sources
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !embedded {
                    VStack(alignment: .leading) {
                        Text("Sources").font(.largeTitle.bold())
                        Text("Feeds, publications, repositories, and webpages").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Import OPML…", systemImage: "square.and.arrow.down") { importingOPML = true }
                Button("Export OPML…", systemImage: "square.and.arrow.up") {
                    Task {
                        do {
                            exportDocument = OPMLExportDocument(data: try await model.exportOPML())
                            exportingOPML = true
                        } catch { status = error.localizedDescription }
                    }
                }
                if !embedded { Button("Add Source", systemImage: "plus") { model.presentsAddSource = true } }
            }.padding(.horizontal, 24).padding(.vertical, embedded ? 10 : 24)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                    .textSelection(.enabled)
            }
            if visibleSources.isEmpty {
                ContentUnavailableView(
                    followedOnly ? "No Followed Sources" : "No Sources",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(followedOnly ? "Sources you explicitly follow appear here." : "Add a feed, creator profile, repository, publication, or webpage.")
                )
            }
            else {
                List(visibleSources) { snapshot in
                    HStack(spacing: 14) {
                        SourceMonogram(snapshot.revision.displayName, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.revision.displayName).font(.headline)
                            Text(isWeChat(snapshot) ? String(localized: "WeChat Official Account") : "\(snapshot.source.kind.displayName) · \(snapshot.endpoints.map { $0.connector.rawValue }.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            if let health = logicalHealth(snapshot) {
                                Text(endpointHealthSummary(health))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                if !isWeChat(snapshot), let message = health.lastFailureMessage, [.authenticationRequired, .platformChanged, .configurationRequired, .error, .temporarilyUnavailable].contains(health.health) {
                                    Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                                }
                                if [.authenticationRequired, .platformChanged, .configurationRequired, .error, .temporarilyUnavailable].contains(health.health) {
                                    StatusPill(isWeChat(snapshot) ? String(localized: "Updates temporarily unavailable") : health.health.displayName, color: .orange)
                                }
                            }
                            HStack(spacing: 8) {
                                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh(snapshot) } }
                                    .labelStyle(.iconOnly)
                                    .help("Refresh Source")
                                    .disabled(model.refreshingSourceIDs.contains(snapshot.id) || model.refreshInProgress)
                                if !isWeChat(snapshot), let endpoint = snapshot.endpoints.first(where: { $0.health == .authenticationRequired || $0.health == .platformChanged }) {
                                    Button("Reconnect") { Task { await model.reconnect(endpoint) } }
                                }
                                Menu {
                                    if isWeChat(snapshot) {
                                        Button("Acquisition details…") { diagnosticSource = snapshot }
                                    }
                                    if let endpoint = snapshot.endpoints.first(where: { $0.accountID != nil }) {
                                        Button("Capture redacted diagnostic") { Task { await model.capturePlatformDiagnostic(endpoint) } }
                                        Button("Remove browser session", role: .destructive) { Task { await model.removeBrowserSession(endpoint) } }
                                    }
                                    Divider()
                                    ForEach(CoverageEcosystem.allCases, id: \.self) { ecosystem in
                                        Button("Coverage: \(ecosystem.displayName)") { model.setCoverage(snapshot, ecosystem: ecosystem) }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .accessibilityLabel("Source options")
                                Button(snapshot.source.isFollowed ? "Following" : "Follow") { model.setSourceFollowed(snapshot, followed: !snapshot.source.isFollowed) }
                                    .help(snapshot.source.isFollowed ? "Unfollow Source" : "Follow Source")
                            }.controlSize(.small)
                            if let endpoint = snapshot.endpoints.first,
                               let diagnostic = model.platformDiagnosticStatus[endpoint.id] {
                                Text(diagnostic).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }.listRowBackground(model.selectedLibraryStableID == snapshot.id.description ? CrosscurrentColor.accent.opacity(0.12) : Color.clear)
                }.listStyle(.inset)
            }
        }
        .sheet(isPresented: Binding(get: { adding || model.presentsAddSource }, set: { value in adding = value; model.presentsAddSource = value }), onDismiss: {
            discoveryTask?.cancel()
            model.clearSourcePreview()
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Source").font(.title.bold())
                TextField("Official Account name or Source URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitDiscovery() }
                    .disabled(model.sourceFollowInProgress)
                Text("Search an Official Account by name, or paste a feed, creator, repository, webpage, or public WeChat article URL. Searches run only when you submit.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.sourceFollowInProgress {
                    ProgressView("Adding source and fetching recent articles…")
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                else if model.sourceDiscoveryInProgress { ProgressView("Finding source…").controlSize(.small) }
                if !model.sourceSearchResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.sourceSearchResults, id: \.result.source.id) { result in
                                HStack(spacing: 12) {
                                    AsyncImage(url: result.result.sourceRevision.avatarURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        SourceMonogram(result.result.sourceRevision.displayName, size: 42)
                                    }
                                    .frame(width: 42, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.result.sourceRevision.displayName).font(.headline)
                                        if result.connectorKind == .weChatOfficialAccount {
                                            Text("WeChat Official Account").font(.caption).foregroundStyle(.secondary)
                                        } else {
                                            if let identity = result.result.display?.identity { Text(identity).font(.caption).foregroundStyle(.secondary) }
                                            Text(result.result.display?.detail ?? result.result.sourceRevision.summary ?? "")
                                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Button("Follow") {
                                        model.selectSourceSearchResult(result)
                                        Task {
                                            status = await model.subscribeSourcePreview(action: .subscribe)
                                            if model.sourcePreview == nil { dismissAddSource(); url = "" }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.sourceDiscoveryInProgress)
                                }
                                .padding(10)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                if let submittedQuery = model.sourceSearchQuery, model.sourcePreview == nil {
                    Button("Search more WeChat accounts…") {
                        discoveryTask?.cancel()
                        discoveryTask = Task { status = await model.searchMoreWeChatSources() }
                    }
                    .disabled(model.sourceDiscoveryInProgress || submittedQuery != url.trimmingCharacters(in: .whitespacesAndNewlines))
                    if model.searchMoreNeedsConfiguration {
                        Button("Open Advanced WeChat settings…") {
                            model.settingsTab = "General"
                            dismissAddSource()
                            openSettings()
                        }
                    }
                }
                if model.sourcePreview == nil && model.sourceSearchResults.isEmpty && model.sourceSearchQuery == nil && !model.sourceFollowInProgress {
                    GroupBox("Optional starter Sources") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Self.starterSources, id: \.url) { starter in
                                Toggle(starter.name, isOn: Binding(
                                    get: { selectedStarterURLs.contains(starter.url) },
                                    set: { selected in
                                        if selected { selectedStarterURLs.insert(starter.url) }
                                        else { selectedStarterURLs.remove(starter.url) }
                                    }
                                ))
                            }
                        }
                        .padding(6)
                    }
                    Text("Starter Sources are unchecked and nothing is subscribed until you explicitly add the selected Sources.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !selectedStarterURLs.isEmpty {
                        Button("Add selected starter Sources") {
                            let selected = Self.starterSources.map(\.url).filter(selectedStarterURLs.contains)
                            Task {
                                status = await model.addStarterSources(selected)
                                selectedStarterURLs.removeAll()
                                if !model.sources.isEmpty { dismissAddSource() }
                            }
                        }
                        .disabled(model.sourceDiscoveryInProgress)
                    }
                }
                if let preview = model.sourcePreview {
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        SourceMonogram(preview.result.sourceRevision.displayName, size: 38)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preview.result.sourceRevision.displayName).font(.headline)
                            Text(preview.result.sourceRevision.summary ?? preview.inputURL?.absoluteString ?? preview.inputQuery ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text(preview.connectorKind == .weChatOfficialAccount ? String(localized: "WeChat Official Account") : preview.result.display?.category ?? String(localized: "\(preview.connectorKind.rawValue) · \(preview.result.recentCandidates.count) recent samples"))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if preview.availableActions.count > 1 {
                        Picker("Action", selection: $selectedAction) {
                            ForEach(preview.availableActions, id: \.self) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if !status.isEmpty && !model.sourceFollowInProgress { Text(status).font(.caption).foregroundStyle(.secondary) }
                if model.pendingPlatformCapture != nil {
                    Button("Capture redacted platform diagnostic", systemImage: "waveform.path.ecg.rectangle") {
                        Task { status = await model.capturePendingPlatformDiagnostic() }
                    }
                    Text("This records only a bounded page-shape and HTTPS-origin fixture. It does not invent selectors or qualify the connector.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.clearSourcePreview(); dismissAddSource() }
                        .disabled(model.sourceFollowInProgress)
                    if model.sourcePreview == nil {
                        Button(isSubmittedURL ? "Preview" : "Search") { submitDiscovery() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(url.isEmpty || model.sourceDiscoveryInProgress)
                    } else {
                        Button("Back") { model.clearSourcePreview(); status = "" }
                            .disabled(model.sourceFollowInProgress)
                        Button(selectedAction.commitLabel) {
                            Task {
                                status = await model.subscribeSourcePreview(action: selectedAction)
                                if model.sourcePreview == nil { dismissAddSource(); url = "" }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.sourceDiscoveryInProgress)
                    }
                }
            }.padding(24).frame(width: 620)
                .interactiveDismissDisabled(model.sourceFollowInProgress)
        }
        .sheet(item: $diagnosticSource) { snapshot in
            WeChatAcquisitionDetails(snapshot: snapshot)
                .environmentObject(model)
        }
        .fileImporter(isPresented: $importingOPML, allowedContentTypes: [.xml, .data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let selected = urls.first else {
                if case let .failure(error) = result { status = error.localizedDescription }
                return
            }
            Task { status = await model.importOPML(from: selected) }
        }
        .fileExporter(isPresented: $exportingOPML, document: exportDocument, contentType: .xml, defaultFilename: "Crosscurrent Sources.opml") { result in
            if case let .failure(error) = result { status = error.localizedDescription }
        }
    }

    private func dismissAddSource() {
        discoveryTask?.cancel()
        adding = false
        model.presentsAddSource = false
    }

    private var isSubmittedURL: Bool {
        guard let value = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https"].contains(value.scheme?.lowercased() ?? "") && value.host != nil
    }

    private func submitDiscovery() {
        guard !model.sourceFollowInProgress else { return }
        discoveryTask?.cancel()
        let input = url.trimmingCharacters(in: .whitespacesAndNewlines)
        discoveryTask = Task {
            let message: String
            if isSubmittedURL { model.clearSourcePreview(); message = await model.previewSource(input) }
            else { message = await model.searchSources(input) }
            guard !Task.isCancelled else { return }
            status = message
            selectedAction = model.sourcePreview?.availableActions.first ?? .subscribe
        }
    }

    private func isWeChat(_ snapshot: StoredSourceSnapshot) -> Bool {
        snapshot.endpoints.contains { $0.connector == .weChatOfficialAccount }
    }

    private func logicalHealth(_ snapshot: StoredSourceSnapshot) -> StoredEndpointHealth? {
        let health = snapshot.endpoints.compactMap { model.endpointHealth[$0.id] }
        guard isWeChat(snapshot) else { return health.first }
        // A successful alternate keeps the publisher available even when its
        // primary endpoint or optional index provider needs attention.
        let healthy = health.filter { $0.health == .healthy }
        let available = healthy.isEmpty ? health.filter { [.syncing, .retrying].contains($0.health) } : healthy
        var logical = available
            .max { ($0.lastSuccess ?? .distantPast) < ($1.lastSuccess ?? .distantPast) } ?? health.first
        logical?.itemCount = health.reduce(0) { $0 + $1.itemCount }
        return logical
    }

    private static let starterSources = [
        (name: "Swift.org", url: "https://www.swift.org/atom.xml"),
        (name: "WebKit", url: "https://webkit.org/feed/"),
        (name: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml"),
        (name: "JSON Feed", url: "https://www.jsonfeed.org/feed.json"),
    ]
}

private func endpointHealthSummary(_ health: StoredEndpointHealth) -> String {
    let formatter = RelativeDateTimeFormatter()
    var parts: [String] = []
    if let success = health.lastSuccess { parts.append(String.localizedStringWithFormat(String(localized: "Last updated %@"), formatter.localizedString(for: success, relativeTo: .now))) }
    else if let attempt = health.lastAttempt { parts.append(String.localizedStringWithFormat(String(localized: "Last tried %@"), formatter.localizedString(for: attempt, relativeTo: .now))) }
    if health.health == .retrying || health.health == .rateLimited { parts.append(String(localized: "Retrying…")) }
    parts.append(String.localizedStringWithFormat(String(localized: "%lld Items"), health.itemCount))
    return parts.joined(separator: " · ")
}

private struct WeChatAcquisitionDetails: View {
    let snapshot: StoredSourceSnapshot
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var current: StoredSourceSnapshot { model.sources.first { $0.id == snapshot.id } ?? snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(current.revision.displayName).font(.title2.bold())
            Text("Acquisition details").font(.subheadline).foregroundStyle(.secondary)
            ForEach(current.endpoints.sorted { ($0.weChatAcquisition?.priority ?? 100) < ($1.weChatAcquisition?.priority ?? 100) }) { endpoint in
                let health = model.endpointHealth[endpoint.id]
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(providerName(endpoint), value: health?.health.displayName ?? endpoint.health.displayName)
                        if let success = health?.lastSuccess ?? endpoint.lastSuccessfulSync {
                            LabeledContent("Last success", value: success.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let attempt = health?.lastAttempt ?? endpoint.weChatAcquisition?.lastAttempt {
                            LabeledContent("Last attempt", value: attempt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let audit = endpoint.weChatAcquisition?.lastAudit {
                            LabeledContent("Last secondary audit", value: audit.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let message = health?.lastFailureMessage, health?.health != .healthy {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            if !current.endpoints.contains(where: { $0.weChatAcquisition?.providerID == "jizhila" || $0.weChatAcquisition == nil }) {
                LabeledContent("Jizhila", value: model.weChatIndexConfigured ? String(localized: "Available as fallback") : String(localized: "Not configured"))
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func providerName(_ endpoint: SourceEndpoint) -> String {
        switch endpoint.weChatAcquisition?.providerID {
        case "wechat2rss": "Wechat2RSS"
        case "bestBlogs", "bestblogs": "BestBlogs"
        case "jizhila", nil: "Jizhila"
        default: endpoint.weChatAcquisition?.providerID ?? ""
        }
    }
}

private struct OPMLExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private extension SourceDiscoveryAction {
    var displayName: String {
        switch self {
        case .subscribe: String(localized: "Subscribe")
        case .importOnce: String(localized: "Import Once")
        case .monitor: String(localized: "Monitor")
        }
    }

    var commitLabel: String {
        switch self {
        case .subscribe: String(localized: "Subscribe and Refresh")
        case .importOnce: String(localized: "Import Page")
        case .monitor: String(localized: "Monitor and Refresh")
        }
    }
}

private extension ConnectorHealth {
    var displayName: String {
        switch self {
        case .healthy: String(localized: "Healthy")
        case .syncing: String(localized: "Syncing")
        case .retrying: String(localized: "Retrying")
        case .authenticationRequired: String(localized: "Authentication required")
        case .rateLimited: String(localized: "Rate limited")
        case .temporarilyUnavailable: String(localized: "Temporarily unavailable")
        case .platformChanged: String(localized: "Platform changed")
        case .configurationRequired: String(localized: "Configuration required")
        case .error: String(localized: "Error")
        case .disabled: String(localized: "Disabled")
        }
    }
}

struct PeopleView: View {
    var embedded = false
    @EnvironmentObject private var model: AppModel
    private var followedPeople: [StoredEntitySnapshot] { model.people.filter(\.entity.isFollowed) }
    var body: some View {
        VStack(spacing: 0) {
            if !embedded { title("People", subtitle: "People you explicitly follow") }
            if followedPeople.isEmpty {
                ContentUnavailableView("No Followed People", systemImage: "person.2", description: Text("People appear here only after you choose to follow them."))
            } else {
                List(followedPeople) { value in
                    PersonRow(name: value.revision.displayName, aliases: value.aliases.map(\.value).joined(separator: " · "), endpoints: value.sourceNames.joined(separator: ", "), followed: true) { model.setEntityFollowed(value, followed: false) }
                        .listRowBackground(model.selectedLibraryStableID == value.id.description ? CrosscurrentColor.accent.opacity(0.12) : Color.clear)
                }.listStyle(.inset)
            }
        }
    }
}

private struct PersonRow: View { var name: String; var aliases: String; var endpoints: String; var followed: Bool; var action: () -> Void; var body: some View { HStack { SourceMonogram(name, size: 38); VStack(alignment: .leading) { Text(name).font(.headline); if !aliases.isEmpty { Text(aliases).font(.caption).foregroundStyle(.secondary) }; if !endpoints.isEmpty { Text(endpoints).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button(followed ? "Following" : "Follow", action: action) } } }

struct TopicsView: View {
    var embedded = false
    @EnvironmentObject private var model: AppModel
    private var followedTopics: [StoredTopicSnapshot] { model.topics.filter(\.topic.isFollowed) }
    var body: some View {
        VStack(spacing: 0) {
            if !embedded { title("Topics", subtitle: "Topics you explicitly follow") }
            if followedTopics.isEmpty {
                ContentUnavailableView("No Followed Topics", systemImage: "number", description: Text("Topics appear here only after you choose to follow them."))
            } else {
                List(followedTopics) { topic in
                    HStack {
                        Text("#").foregroundStyle(CrosscurrentColor.accent)
                        Text(topic.revision.name).font(.headline)
                        Spacer()
                        Text(String.localizedStringWithFormat(String(localized: "%lld Events"), topic.eventCount)).foregroundStyle(.secondary)
                        Button("Following") { model.setTopicFollowed(topic, followed: false) }
                    }
                    .listRowBackground(model.selectedLibraryStableID == topic.id.description ? CrosscurrentColor.accent.opacity(0.12) : Color.clear)
                }
            }
        }
    }
}

struct LibraryObjectDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.selectedLibraryResultKind {
        case .person, .organization:
            if let person = selectedPerson {
                detail(
                    title: person.revision.displayName,
                    kind: person.entity.kind == .person ? "Person" : "Organization",
                    summary: person.revision.summary,
                    context: person.sourceNames,
                    isFollowed: person.entity.isFollowed,
                    action: { model.setEntityFollowed(person, followed: !person.entity.isFollowed) }
                )
            } else { missing }
        case .topic:
            if let topic = selectedTopic {
                detail(
                    title: topic.revision.name,
                    kind: "Topic",
                    summary: topic.revision.summary,
                    context: [String.localizedStringWithFormat(String(localized: "%lld Events"), topic.eventCount)],
                    isFollowed: topic.topic.isFollowed,
                    action: { model.setTopicFollowed(topic, followed: !topic.topic.isFollowed) }
                )
            } else { missing }
        case .source:
            if let source = selectedSource {
                detail(
                    title: source.revision.displayName,
                    kind: "Source",
                    summary: source.revision.summary,
                    context: source.endpoints.map { $0.connector.rawValue },
                    isFollowed: source.source.isFollowed,
                    action: { model.setSourceFollowed(source, followed: !source.source.isFollowed) }
                )
            } else { missing }
        default:
            missing
        }
    }

    private var selectedPerson: StoredEntitySnapshot? {
        model.people.first { $0.id.description == model.selectedLibraryStableID }
    }

    private var selectedTopic: StoredTopicSnapshot? {
        model.topics.first { $0.id.description == model.selectedLibraryStableID }
    }

    private var selectedSource: StoredSourceSnapshot? {
        model.sources.first { $0.id.description == model.selectedLibraryStableID }
    }

    private var missing: some View {
        ContentUnavailableView("Detail Unavailable", systemImage: "questionmark.circle", description: Text("This result is no longer available in the current library."))
    }

    private func detail(
        title: String,
        kind: LocalizedStringKey,
        summary: String?,
        context: [String],
        isFollowed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    SourceMonogram(title, size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(kind).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(title).font(.system(size: 34, weight: .bold, design: .serif))
                    }
                    Spacer()
                    Button(isFollowed ? "Following" : "Follow", action: action)
                }
                if let summary, !summary.isEmpty { Text(summary).font(.body).lineSpacing(3) }
                if !context.isEmpty {
                    Divider()
                    Text(context.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                Text("Following is an explicit interest signal. Linked Sources and inferred entities remain independent unless you follow them separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem { Button("Back", systemImage: "chevron.left") { model.selection = .following } }
        }
    }
}

struct ItemDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showOriginal = false
    @State private var activatedLink: URL?
    var body: some View {
        if let item = model.selectedItemDetail {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Button("Back", systemImage: "chevron.left") {
                        model.selection = model.itemReturnDestination
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if item.isHistorical { StatusPill("Historical revision", color: .secondary) }
                        Text(item.author.map { $0 == item.sourceName ? item.sourceName : "\(item.sourceName) · \($0)" } ?? item.sourceName)
                            .foregroundStyle(.secondary).lineLimit(2)
                        if let publishedAt = item.publishedAt { Text(publishedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let url = item.canonicalURL {
                        Button("Open original") {
                            if let accountID = item.originalAccountID {
                                Task { await model.openAuthenticatedOriginal(url: url, accountID: accountID) }
                            } else {
                                activatedLink = nil
                                showOriginal = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                Divider()
                if let html = item.sanitizedHTML, !html.isEmpty {
                    ReaderWebView(
                        document: ReaderDocument(id: item.revisionID.description, title: item.title, byline: item.sourceName, sanitizedHTML: html, baseURL: item.canonicalURL, itemRevisionID: item.revisionID),
                        activatedLink: $activatedLink
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(item.title).font(.system(size: 34, weight: .bold, design: .serif))
                            Text(item.text).textSelection(.enabled).lineSpacing(4)
                        }
                        .padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }
            .onChange(of: activatedLink) { _, link in if link != nil { showOriginal = true } }
            .onChange(of: item.revisionID) { _, _ in activatedLink = nil; showOriginal = false }
            .sheet(isPresented: $showOriginal, onDismiss: { activatedLink = nil }) {
                if let url = activatedLink ?? item.canonicalURL { PublicOriginalWebView(url: url).frame(minWidth: 900, minHeight: 650) }
            }
        } else {
            ContentUnavailableView("Choose an Item", systemImage: "doc.richtext")
        }
    }
}

struct SavedView: View {
    @EnvironmentObject private var model: AppModel
    private var savedEvents: [EventCardModel] { model.events.filter { model.savedEventIDs.contains($0.id) } }

    var body: some View {
        LibraryPageShell("Saved", subtitle: "Stories and articles you want to keep") {
            EmptyView()
        } content: {
            if savedEvents.isEmpty {
                ContentUnavailableView("Nothing Saved", systemImage: "bookmark", description: Text("Save stories and articles to read or revisit later."))
            } else {
                List(savedEvents) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "bookmark.fill").foregroundStyle(CrosscurrentColor.accent)
                        Button { model.open(event) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.headline).foregroundStyle(.primary)
                                Text(event.primarySource + " · " + String.localizedStringWithFormat(String(localized: "%lld sources"), event.sourceCount)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button("Remove") { model.toggleSaved(event) }.buttonStyle(.borderless)
                    }
                }.listStyle(.inset)
            }
        }
    }
}

@MainActor private func title(_ value: String, subtitle: String, add: (() -> Void)? = nil) -> some View { HStack { VStack(alignment: .leading) { Text(LocalizedStringKey(value)).font(.largeTitle.bold()); Text(LocalizedStringKey(subtitle)).foregroundStyle(.secondary) }; Spacer(); if let add { Button(action: add) { Image(systemName: "plus") } } }.padding(24) }

private extension SourceKind {
    var displayName: String {
        switch self {
        case .person: String(localized: "Person")
        case .organization: String(localized: "Organization")
        case .publication: String(localized: "Publication")
        case .repository: String(localized: "Repository")
        case .community: String(localized: "Community")
        case .query: String(localized: "Query")
        case .website: String(localized: "Website")
        case .newsletter: String(localized: "Newsletter")
        }
    }
}

private extension AccessRequirement {
    var displayName: String { self == .anonymous ? String(localized: "Anonymous") : String(localized: "Authenticated") }
}

private extension ContentPrivacy {
    var displayName: String {
        switch self {
        case .public: String(localized: "Public")
        case .private: String(localized: "Private")
        case .restricted: String(localized: "Restricted")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension CoverageEcosystem {
    var displayName: String {
        switch self {
        case .chinaFocused: String(localized: "China-focused")
        case .globalFocused: String(localized: "Global-focused")
        case .mixed: String(localized: "Mixed coverage")
        case .unknown: String(localized: "Unknown coverage")
        }
    }
}
