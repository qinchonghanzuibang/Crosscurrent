import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentIngestion
import SwiftUI

struct AddSourceSheet: View {
    var onComplete: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @FocusState private var queryFocused: Bool
    @State private var input = ""
    @State private var status = ""
    @State private var selectedResultID: String?
    @State private var selectedAction: SourceDiscoveryAction = .subscribe
    @State private var selectedStarterURLs: Set<String> = []
    @State private var discoveryTask: Task<Void, Never>?
    @State private var actionBusy = false
    @State private var discoveryBusy = false
    @State private var addedStarters = false

    private var busy: Bool { actionBusy || discoveryBusy || model.sourceDiscoveryInProgress }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isURL: Bool {
        guard let url = URL(string: trimmedInput) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
    private var selectedResult: SourceDiscoveryPreview? {
        model.sourceSearchResults.first { $0.result.source.id.description == selectedResultID }
    }
    private var preview: SourceDiscoveryPreview? { model.sourcePreview ?? selectedResult }
    private var alreadyFollowing: Bool { preview.map { model.isFollowing($0) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Source").font(.title2.bold())
                TextField("Official Account name or Source URL", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit { submitDiscovery() }
                    .accessibilityIdentifier("sourceDiscoveryInput")
                    .disabled(busy)
                Text("Search a WeChat account, or paste a feed, website, or article URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            discoveryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .interactiveDismissDisabled(actionBusy || model.sourceFollowInProgress)
        .task { queryFocused = true }
        .onChange(of: input) { _, _ in
            model.clearSourcePreview()
            selectedResultID = nil
            status = ""
            selectedStarterURLs.removeAll()
        }
        .onDisappear { discoveryTask?.cancel() }
    }

    @ViewBuilder private var discoveryContent: some View {
        if !model.sourceSearchResults.isEmpty {
            VStack(spacing: 0) {
                List(selection: $selectedResultID) {
                    ForEach(model.sourceSearchResults, id: \.result.source.id) { result in
                        resultRow(result)
                            .tag(result.result.source.id.description)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .disabled(busy)
                .accessibilityLabel("Source search results")
                searchMoreActions.padding(.horizontal, 20).padding(.vertical, 10)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview = model.sourcePreview {
                        resultRow(preview)
                        if preview.availableActions.count > 1 {
                            Picker("Action", selection: $selectedAction) {
                                ForEach(preview.availableActions, id: \.self) { action in
                                    Text(action.displayName).tag(action)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(busy)
                        }
                        if let summary = preview.result.sourceRevision.summary, !summary.isEmpty {
                            Text(summary).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else if model.sourceSearchQuery != nil {
                        if !busy {
                            Text("No matching accounts").font(.headline)
                            Text("Try another name or paste an article URL.")
                                .foregroundStyle(.secondary)
                        }
                        searchMoreActions
                    } else if !busy {
                        Text("Suggested sources").font(.headline)
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 14) {
                            ForEach(Self.starterSources, id: \.url) { starter in
                                Toggle(starter.name, isOn: Binding(
                                    get: { selectedStarterURLs.contains(starter.url) },
                                    set: { selected in
                                        if selected { selectedStarterURLs.insert(starter.url) }
                                        else { selectedStarterURLs.remove(starter.url) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                        Text("Choose any you would like to follow.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.pendingPlatformCapture != nil {
                        DisclosureGroup("Connection diagnostics") {
                            VStack(alignment: .leading, spacing: 8) {
                                Button("Capture redacted platform diagnostic", systemImage: "waveform.path.ecg.rectangle") {
                                    guard !busy else { return }
                                    discoveryBusy = true
                                    discoveryTask = Task {
                                        defer { discoveryBusy = false }
                                        status = await model.capturePendingPlatformDiagnostic()
                                    }
                                }
                                Text("Save a local diagnostic with sensitive details removed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 6)
                        }
                        .disabled(busy)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func resultRow(_ result: SourceDiscoveryPreview) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.result.sourceRevision.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SourceMonogram(result.result.sourceRevision.displayName, size: 36)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.result.sourceRevision.displayName).font(.body.weight(.medium))
                Text(result.connectorKind == .weChatOfficialAccount
                     ? String(localized: "WeChat Official Account")
                     : result.result.display?.identity ?? result.inputURL?.host ?? result.result.display?.detail ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if model.isFollowing(result) {
                Label("Following", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var searchMoreActions: some View {
        if let submittedQuery = model.sourceSearchQuery, model.sourcePreview == nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Search more WeChat accounts…") {
                        guard !busy else { return }
                        status = ""
                        discoveryBusy = true
                        discoveryTask = Task {
                            defer { discoveryBusy = false }
                            let message = await model.searchMoreWeChatSources()
                            guard !Task.isCancelled else { return }
                            status = message
                            selectFirstAvailableResult()
                        }
                    }
                    .disabled(busy || submittedQuery != trimmedInput)
                    Spacer()
                    if model.searchMoreNeedsConfiguration {
                        Button("Configure WeChat search…") {
                            model.settingsTab = "General"
                            model.settingsShowsWeChat = true
                            dismiss()
                            openSettings()
                        }
                    }
                }
                if model.searchMoreNeedsConfiguration {
                    Text("More results require an optional provider. Public feeds stay free.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(actionBusy || model.sourceFollowInProgress
                     ? String(localized: "Adding source and fetching recent articles…")
                     : busy ? String(localized: "Finding source…") : status)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(status)
            }
            .frame(height: 30, alignment: .top)
            HStack {
                if model.sourcePreview != nil {
                    Button("Back") {
                        model.clearSourcePreview()
                        status = ""
                        queryFocused = true
                    }.disabled(busy)
                }
                Spacer()
                Button(addedStarters ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(actionBusy || model.sourceFollowInProgress)
                Button(primaryLabel) { performPrimaryAction() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || primaryDisabled)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var primaryLabel: String {
        if !selectedStarterURLs.isEmpty { return String(localized: "Add Selected") }
        if alreadyFollowing { return String(localized: "Following") }
        if model.sourcePreview != nil { return selectedAction.commitLabel }
        if selectedResult != nil { return String(localized: "Follow") }
        return isURL ? String(localized: "Preview") : String(localized: "Search")
    }

    private var primaryDisabled: Bool {
        if !selectedStarterURLs.isEmpty { return false }
        if alreadyFollowing { return true }
        if preview != nil { return false }
        return trimmedInput.isEmpty
    }

    private func submitDiscovery() {
        guard !busy, !trimmedInput.isEmpty else { return }
        discoveryTask?.cancel()
        model.clearSourcePreview()
        selectedResultID = nil
        selectedStarterURLs.removeAll()
        status = ""
        discoveryBusy = true
        let query = trimmedInput
        let submittedURL = isURL
        discoveryTask = Task {
            defer { discoveryBusy = false }
            let message = submittedURL ? await model.previewSource(query) : await model.searchSources(query)
            guard !Task.isCancelled else { return }
            status = model.sourcePreview.map { model.isFollowing($0) } == true
                ? String(localized: "This source is already in Following.")
                : message
            selectedAction = model.sourcePreview?.availableActions.first ?? .subscribe
            selectFirstAvailableResult()
        }
    }

    private func selectFirstAvailableResult() {
        selectedResultID = (model.sourceSearchResults.first { !model.isFollowing($0) }
                            ?? model.sourceSearchResults.first)?.result.source.id.description
    }

    private func performPrimaryAction() {
        guard !busy, !primaryDisabled else { return }
        if !selectedStarterURLs.isEmpty {
            let urls = Self.starterSources.map(\.url).filter(selectedStarterURLs.contains)
            actionBusy = true
            Task {
                defer { actionBusy = false }
                status = await model.addStarterSources(urls)
                selectedStarterURLs.removeAll()
                model.clearSourcePreview()
                addedStarters = true
                onComplete(status)
            }
        } else if preview != nil {
            let action = model.sourcePreview == nil ? SourceDiscoveryAction.subscribe : selectedAction
            if let selectedResult { model.selectSourceSearchResult(selectedResult) }
            actionBusy = true
            Task {
                defer { actionBusy = false }
                status = await model.subscribeSourcePreview(action: action)
                if model.sourcePreview == nil {
                    onComplete(status)
                    dismiss()
                }
            }
        } else {
            submitDiscovery()
        }
    }

    private static let starterSources = [
        (name: "Swift.org", url: "https://www.swift.org/atom.xml"),
        (name: "WebKit", url: "https://webkit.org/feed/"),
        (name: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml"),
        (name: "JSON Feed", url: "https://www.jsonfeed.org/feed.json"),
    ]
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
        case .subscribe: String(localized: "Follow")
        case .importOnce: String(localized: "Import Page")
        case .monitor: String(localized: "Monitor")
        }
    }
}
