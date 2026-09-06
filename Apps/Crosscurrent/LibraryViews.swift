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
    var controls: Controls
    var content: Content

    init(
        _ pageTitle: LocalizedStringKey,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder content: () -> Content
    ) {
        self.pageTitle = pageTitle
        self.controls = controls()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(pageTitle).font(.title2.bold())
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FollowingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LibraryPageShell("Following") {
            Picker("Following", selection: $model.followingFilter) {
                ForEach(FollowingFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
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
                            HStack(spacing: 10) {
                                SourceMonogram(source.revision.displayName, size: 30)
                                Text(source.revision.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Spacer()
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } }
                }
                if !people.isEmpty {
                    Section("People") { ForEach(people) { person in
                        Button { model.openLibraryObject(person.id.description, kind: .person) } label: {
                            HStack(spacing: 10) {
                                SourceMonogram(person.revision.displayName, size: 30)
                                Text(person.revision.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(person.sourceNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } }
                }
                if !topics.isEmpty {
                    Section("Topics") { ForEach(topics) { topic in
                        Button { model.openLibraryObject(topic.id.description, kind: .topic) } label: {
                            HStack(spacing: 10) {
                                Text("#").foregroundStyle(CrosscurrentColor.accent).frame(width: 30)
                                Text(topic.revision.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(String.localizedStringWithFormat(String(localized: "%lld Events"), topic.eventCount)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
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
    @State private var adding = false
    @State private var status = ""
    @State private var importingOPML = false
    @State private var exportingOPML = false
    @State private var exportDocument = OPMLExportDocument(data: Data())
    @State private var diagnosticSource: StoredSourceSnapshot?
    private var visibleSources: [StoredSourceSnapshot] {
        followedOnly ? model.sources.filter(\.source.isFollowed) : model.sources
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !embedded { Text("Sources").font(.title2.bold()) }
                Spacer()
                Menu {
                    Button("Import OPML…", systemImage: "square.and.arrow.down") { importingOPML = true }
                    Button("Export OPML…", systemImage: "square.and.arrow.up") {
                        Task {
                            do {
                                exportDocument = OPMLExportDocument(data: try await model.exportOPML())
                                exportingOPML = true
                            } catch { status = error.localizedDescription }
                        }
                    }
                } label: { Label("Manage sources", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if !embedded { Button("Add Source", systemImage: "plus") { model.presentsAddSource = true } }
            }.padding(.horizontal, 24).padding(.vertical, embedded ? 8 : 16)
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
                List(visibleSources) { snapshot in sourceRow(snapshot) }.listStyle(.inset)
            }
        }
        .sheet(isPresented: Binding(get: { adding || model.presentsAddSource }, set: { value in adding = value; model.presentsAddSource = value }), onDismiss: {
            model.clearSourcePreview()
        }) {
            AddSourceSheet { message in status = message }
                .environmentObject(model)
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

    private func sourceRow(_ snapshot: StoredSourceSnapshot) -> some View {
        let health = logicalHealth(snapshot)
        let refreshing = model.refreshingSourceIDs.contains(snapshot.id) || health?.health == .syncing
        return HStack(spacing: 12) {
            Button { model.openLibraryObject(snapshot.id.description, kind: .source) } label: {
                HStack(spacing: 10) {
                    SourceMonogram(snapshot.revision.displayName, size: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.revision.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(isWeChat(snapshot) ? String(localized: "WeChat Official Account") : snapshot.source.kind.displayName)
                            if let health {
                                Text("·").accessibilityHidden(true)
                                sourceHealthLabel(health, isWeChat: isWeChat(snapshot))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { Task { await model.refresh(snapshot) } } label: {
                Group {
                    if refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh Source")
            .help("Refresh Source")
            .disabled(refreshing || model.refreshInProgress)
            Button(snapshot.source.isFollowed ? "Following" : "Follow") {
                model.setSourceFollowed(snapshot, followed: !snapshot.source.isFollowed)
            }
            .controlSize(.small)
            .help(snapshot.source.isFollowed ? "Unfollow Source" : "Follow Source")
            Menu {
                if !isWeChat(snapshot), let endpoint = snapshot.endpoints.first(where: { $0.health == .authenticationRequired || $0.health == .platformChanged }) {
                    Button("Reconnect") { Task { await model.reconnect(endpoint) } }
                }
                if isWeChat(snapshot) {
                    Button("Acquisition details…") { diagnosticSource = snapshot }
                }
                Menu("Status details") {
                    if let health {
                        Text(endpointHealthSummary(health))
                        if let failure = health.lastFailureMessage { Text(failure) }
                    }
                    ForEach(snapshot.endpoints) { endpoint in
                        if let diagnostic = model.platformDiagnosticStatus[endpoint.id] { Text(diagnostic) }
                    }
                }
                if let endpoint = snapshot.endpoints.first(where: { $0.accountID != nil }) {
                    Divider()
                    Button("Capture redacted diagnostic") { Task { await model.capturePlatformDiagnostic(endpoint) } }
                    Button("Remove browser session", role: .destructive) { Task { await model.removeBrowserSession(endpoint) } }
                }
                Divider()
                Menu("Coverage") {
                    ForEach(CoverageEcosystem.allCases, id: \.self) { ecosystem in
                        Button(ecosystem.displayName) { model.setCoverage(snapshot, ecosystem: ecosystem) }
                    }
                }
            } label: { Label("Source options", systemImage: "ellipsis") }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Source options")
        }
        .padding(.vertical, 6)
        .listRowBackground(model.selectedLibraryStableID == snapshot.id.description ? CrosscurrentColor.accent.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private func sourceHealthLabel(_ health: StoredEndpointHealth, isWeChat: Bool) -> some View {
        if health.health == .healthy, let updated = health.lastSuccess {
            HStack(spacing: 4) {
                Text("Updated")
                EventTimestamp(date: updated)
            }
        } else {
            let needsAttention = [.authenticationRequired, .platformChanged, .configurationRequired, .temporarilyUnavailable, .error].contains(health.health)
            HStack(spacing: 4) {
                if needsAttention { Image(systemName: "exclamationmark.triangle") }
                Text(sourceHealthText(health.health, isWeChat: isWeChat))
            }
            .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
        }
    }

    private func sourceHealthText(_ health: ConnectorHealth, isWeChat: Bool) -> String {
        switch health {
        case .healthy: String(localized: "Up to date")
        case .syncing: String(localized: "Refreshing…")
        case .retrying, .rateLimited: String(localized: "Waiting to retry")
        case .authenticationRequired: isWeChat ? String(localized: "Updates unavailable") : String(localized: "Sign in to update")
        case .platformChanged: String(localized: "Source needs attention")
        case .configurationRequired: String(localized: "Setup needed")
        case .temporarilyUnavailable, .error: String(localized: "Updates unavailable")
        case .disabled: String(localized: "Updates paused")
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
                    PersonRow(name: value.revision.displayName, aliases: value.aliases.map(\.value).joined(separator: " · "), endpoints: value.sourceNames.joined(separator: ", "), followed: true, open: {
                        model.openLibraryObject(value.id.description, kind: .person)
                    }) { model.setEntityFollowed(value, followed: false) }
                        .listRowBackground(model.selectedLibraryStableID == value.id.description ? CrosscurrentColor.accent.opacity(0.08) : Color.clear)
                }.listStyle(.inset)
            }
        }
    }
}

private struct PersonRow: View {
    var name: String
    var aliases: String
    var endpoints: String
    var followed: Bool
    var open: () -> Void
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    SourceMonogram(name, size: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        if !endpoints.isEmpty || !aliases.isEmpty {
                            Text(endpoints.isEmpty ? aliases : endpoints).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(followed ? "Following" : "Follow", action: action)
                .controlSize(.small)
                .help(followed ? "Unfollow person" : "Follow person")
        }
        .padding(.vertical, 6)
    }
}

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
                        Button { model.openLibraryObject(topic.id.description, kind: .topic) } label: {
                            HStack(spacing: 10) {
                                Text("#").foregroundStyle(CrosscurrentColor.accent).frame(width: 30)
                                Text(topic.revision.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text(String.localizedStringWithFormat(String(localized: "%lld Events"), topic.eventCount)).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Following") { model.setTopicFollowed(topic, followed: false) }
                            .controlSize(.small)
                            .help("Unfollow topic")
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(model.selectedLibraryStableID == topic.id.description ? CrosscurrentColor.accent.opacity(0.08) : Color.clear)
                }.listStyle(.inset)
            }
        }
    }
}

struct LibraryObjectDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
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
                    context: [source.source.kind.displayName],
                    isFollowed: source.source.isFollowed,
                    action: { model.setSourceFollowed(source, followed: !source.source.isFollowed) }
                )
            } else { missing }
        default:
            missing
        }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.selection = model.libraryReturnDestination }
            }
        }
        .onExitCommand { model.selection = model.libraryReturnDestination }
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
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(title)
    }
}

struct ItemDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showOriginal = false
    @State private var activatedLink: URL?
    var body: some View {
        if let item = model.selectedItemDetail {
            VStack(spacing: 0) {
                if item.isHistorical {
                    HStack {
                        Label("Earlier version", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 24).padding(.vertical, 8).background(.bar)
                }
                if let html = item.sanitizedHTML, !html.isEmpty {
                    ReaderWebView(
                        document: ReaderDocument(id: item.revisionID.description, title: item.title, byline: item.author.map { $0 == item.sourceName ? item.sourceName : "\(item.sourceName) · \($0)" } ?? item.sourceName, publishedAt: item.publishedAt, sanitizedHTML: html, baseURL: item.canonicalURL, itemRevisionID: item.revisionID),
                        activatedLink: $activatedLink
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(item.title).font(.system(size: 34, weight: .bold, design: .default))
                            Text(item.text).textSelection(.enabled).lineSpacing(4)
                        }
                        .padding(32).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(item.sourceName)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { model.selection = model.itemReturnDestination }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = item.canonicalURL {
                        Button("Open Original", systemImage: "safari") {
                            if let accountID = item.originalAccountID {
                                Task { await model.openAuthenticatedOriginal(url: url, accountID: accountID) }
                            } else {
                                activatedLink = nil
                                showOriginal = true
                            }
                        }
                    }
                }
            }
            .onExitCommand { model.selection = model.itemReturnDestination }
            .onChange(of: activatedLink) { _, link in if link != nil { showOriginal = true } }
            .onChange(of: item.revisionID) { _, _ in activatedLink = nil; showOriginal = false }
            .sheet(isPresented: $showOriginal, onDismiss: { activatedLink = nil }) {
                if let url = activatedLink ?? item.canonicalURL { ReaderOriginalSheet(url: url) }
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
        LibraryPageShell("Saved") {
            EmptyView()
        } content: {
            if savedEvents.isEmpty {
                ContentUnavailableView("Nothing Saved", systemImage: "bookmark", description: Text("Save stories and articles to read or revisit later."))
            } else {
                List(savedEvents) { event in
                    HStack(spacing: 10) {
                        Button { model.open(event) } label: { EventListRow(event: event, isSaved: true) }
                            .buttonStyle(.plain)
                        Menu {
                            Button("Remove from Saved") { model.toggleSaved(event) }
                            Button("Mark Unread") { model.setEventUnread(event) }
                        } label: {
                            Label("Story options", systemImage: "ellipsis")
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Story options")
                    }
                    .contextMenu {
                        Button("Remove from Saved") { model.toggleSaved(event) }
                        Button("Mark Unread") { model.setEventUnread(event) }
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
