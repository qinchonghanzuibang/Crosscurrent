import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentModels
import CrosscurrentReader
import CrosscurrentStorage
import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var url = ""
    @State private var status = ""
    @State private var selectedAction: SourceDiscoveryAction = .subscribe
    @State private var importingOPML = false
    @State private var exportingOPML = false
    @State private var exportDocument = OPMLExportDocument(data: Data())
    @State private var selectedStarterURLs: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Sources").font(.largeTitle.bold())
                    Text("Logical Sources with connector endpoints").foregroundStyle(.secondary)
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
                Button { model.presentsAddSource = true } label: { Image(systemName: "plus") }
            }.padding(24)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                    .textSelection(.enabled)
            }
            if model.sources.isEmpty { ContentUnavailableView("No Sources", systemImage: "dot.radiowaves.left.and.right", description: Text("Add a feed, creator profile, repository, publication, or webpage.")) }
            else {
                List(model.sources) { snapshot in
                    HStack(spacing: 14) {
                        SourceMonogram(snapshot.revision.displayName, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.revision.displayName).font(.headline)
                            Text("\(snapshot.source.kind.displayName) · \(snapshot.endpoints.map { $0.connector.rawValue }.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if let policy = snapshot.aiClassification { StatusPill("\(policy.accessRequirement.displayName) · \(policy.contentPrivacy.displayName)", color: .secondary) }
                                StatusPill(snapshot.coverage?.ecosystem.displayName ?? CoverageEcosystem.unknown.displayName, color: .secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            StatusPill(snapshot.endpoints.first?.health.displayName ?? String(localized: "No endpoint"), color: snapshot.endpoints.allSatisfy { $0.health == .healthy } ? .green : .orange)
                            if let endpoint = snapshot.endpoints.first,
                               let health = model.endpointHealth[endpoint.id] {
                                Text(endpointHealthSummary(health))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                if let message = health.lastFailureMessage, health.health != .healthy {
                                    Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                                }
                            }
                            HStack(spacing: 8) {
                                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh(snapshot) } }
                                    .labelStyle(.iconOnly)
                                    .help("Refresh Source")
                                if let endpoint = snapshot.endpoints.first(where: { $0.health == .authenticationRequired || $0.health == .platformChanged }) {
                                    Button("Reconnect") { Task { await model.reconnect(endpoint) } }
                                }
                                if let endpoint = snapshot.endpoints.first(where: { $0.accountID != nil }) {
                                    Menu("Session") {
                                        Button("Capture redacted diagnostic") { Task { await model.capturePlatformDiagnostic(endpoint) } }
                                        Button("Remove browser session", role: .destructive) { Task { await model.removeBrowserSession(endpoint) } }
                                    }
                                }
                                Menu(snapshot.coverage?.ecosystem.displayName ?? String(localized: "Unknown coverage")) {
                                    ForEach(CoverageEcosystem.allCases, id: \.self) { ecosystem in
                                        Button(ecosystem.displayName) { model.setCoverage(snapshot, ecosystem: ecosystem) }
                                    }
                                }
                                Button(snapshot.source.isFollowed ? "Following" : "Follow") { model.setSourceFollowed(snapshot, followed: !snapshot.source.isFollowed) }
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
        .sheet(isPresented: Binding(get: { adding || model.presentsAddSource }, set: { value in adding = value; model.presentsAddSource = value })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Source").font(.title.bold())
                TextField("Feed, creator, repository, or webpage URL", text: $url).textFieldStyle(.roundedBorder)
                Text("WeChat Official Accounts and Xiaohongshu creators use the authenticated BrowserWorker; URL capture remains supplementary.").font(.caption).foregroundStyle(.secondary)
                if model.sourcePreview == nil {
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
                            Text(preview.result.sourceRevision.summary ?? preview.inputURL.absoluteString)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text("\(preview.connectorKind.rawValue) · \(preview.result.recentCandidates.count) recent samples")
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
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
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
                    if model.sourcePreview == nil {
                        Button("Preview") { Task { status = await model.previewSource(url); selectedAction = model.sourcePreview?.availableActions.first ?? .subscribe } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(url.isEmpty || model.sourceDiscoveryInProgress)
                    } else {
                        Button("Back") { model.clearSourcePreview(); status = "" }
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
            }.padding(24).frame(width: 560)
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
        adding = false
        model.presentsAddSource = false
    }

    private static let starterSources = [
        (name: "Swift.org", url: "https://www.swift.org/atom.xml"),
        (name: "WebKit", url: "https://webkit.org/feed/"),
        (name: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml"),
        (name: "JSON Feed", url: "https://www.jsonfeed.org/feed.json"),
    ]
}

private func endpointHealthSummary(_ health: StoredEndpointHealth) -> String {
    var parts = [String.localizedStringWithFormat(String(localized: "%lld Items"), health.itemCount)]
    let formatter = RelativeDateTimeFormatter()
    if let success = health.lastSuccess { parts.append("Last success \(formatter.localizedString(for: success, relativeTo: .now))") }
    else if let attempt = health.lastAttempt { parts.append("Last attempt \(formatter.localizedString(for: attempt, relativeTo: .now))") }
    if let retry = health.nextRetry { parts.append("Retry \(formatter.localizedString(for: retry, relativeTo: .now))") }
    if let cursor = health.cursorFamily { parts.append(cursor) }
    return parts.joined(separator: " · ")
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
        case .authenticationRequired: String(localized: "Authentication required")
        case .rateLimited: String(localized: "Rate limited")
        case .temporarilyUnavailable: String(localized: "Temporarily unavailable")
        case .platformChanged: String(localized: "Platform changed")
        case .error: String(localized: "Error")
        case .disabled: String(localized: "Disabled")
        }
    }
}

struct PeopleView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { VStack(spacing: 0) { title("People", subtitle: "Entities, aliases, and all linked Sources"); if model.people.isEmpty { ContentUnavailableView("No People Yet", systemImage: "person.2") } else { List(model.people) { value in PersonRow(name: value.revision.displayName, aliases: value.aliases.map(\.value).joined(separator: " · "), endpoints: value.sourceNames.joined(separator: ", "), followed: value.entity.isFollowed) { model.setEntityFollowed(value, followed: !value.entity.isFollowed) }.listRowBackground(model.selectedLibraryStableID == value.id.description ? CrosscurrentColor.accent.opacity(0.12) : Color.clear) }.listStyle(.inset) } } }
}

private struct PersonRow: View { var name: String; var aliases: String; var endpoints: String; var followed: Bool; var action: () -> Void; var body: some View { HStack { SourceMonogram(name, size: 38); VStack(alignment: .leading) { Text(name).font(.headline); if !aliases.isEmpty { Text(aliases).font(.caption).foregroundStyle(.secondary) }; if !endpoints.isEmpty { Text(endpoints).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button(followed ? "Following" : "Follow", action: action) } } }

struct TopicsView: View { @EnvironmentObject private var model: AppModel; var body: some View { VStack(spacing: 0) { title("Topics", subtitle: "Revisioned assertions from Items and Events"); if model.topics.isEmpty { ContentUnavailableView("No Topics Yet", systemImage: "number") } else { List(model.topics) { topic in HStack { Text("#").foregroundStyle(CrosscurrentColor.accent); Text(topic.revision.name).font(.headline); Spacer(); Text(String.localizedStringWithFormat(String(localized: "%lld Events"), topic.eventCount)).foregroundStyle(.secondary); Button(topic.topic.isFollowed ? "Following" : "Follow") { model.setTopicFollowed(topic, followed: !topic.topic.isFollowed) } }.listRowBackground(model.selectedLibraryStableID == topic.id.description ? CrosscurrentColor.accent.opacity(0.12) : Color.clear) } } } } }

struct ItemDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showOriginal = false
    var body: some View {
        if let item = model.selectedItemDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if item.isHistorical { StatusPill("Historical revision", color: .secondary) }
                    Text(item.title).font(.system(size: 34, weight: .bold, design: .serif))
                    Text([item.sourceName, item.author].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    if let publishedAt = item.publishedAt { Text(publishedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    Text(item.text).textSelection(.enabled).lineSpacing(4)
                    if let url = item.canonicalURL {
                        Button("Open original") {
                            if let accountID = item.originalAccountID {
                                Task { await model.openAuthenticatedOriginal(url: url, accountID: accountID) }
                            } else {
                                showOriginal = true
                            }
                        }
                    }
                }
                .padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $showOriginal) {
                if let url = item.canonicalURL { PublicOriginalWebView(url: url).frame(minWidth: 900, minHeight: 650) }
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
        VStack(spacing: 0) {
            title("Saved", subtitle: "Articles, Events, tags, and smart collections")
            if savedEvents.isEmpty {
                ContentUnavailableView("Nothing Saved", systemImage: "bookmark", description: Text("Save an Event from Flow or Event Detail. Saved references follow the stable Event while preserving revision history."))
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
