import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import CrosscurrentSearch
import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text("Search").font(.title2.bold())
                    TextField("Search your library", text: $model.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .accessibilityLabel("Search")
                    Toggle("History", isOn: $model.searchIncludesHistory)
                        .toggleStyle(.checkbox)
                        .help("Include earlier versions of stories and articles")
                }
                HStack(spacing: 12) {
                    Picker("Search in", selection: $model.searchFacet) {
                        ForEach(["All", "Items", "Events", "People", "Sources", "Topics"], id: \.self) {
                            Text(LocalizedStringKey($0)).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 560, alignment: .leading)
                    Spacer(minLength: 0)
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .opacity(searching ? 1 : 0)
                        .accessibilityLabel("Searching…")
                        .accessibilityHidden(!searching)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            searchContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { searchFocused = true }
        .task(id: SearchTaskKey(query: model.searchQuery, facet: model.searchFacet, includeHistory: model.searchIncludesHistory, generation: model.canonicalGeneration)) {
            guard !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.searchResults = []
                searching = false
                return
            }
            searching = true
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let matches = await model.search(model.searchQuery, kinds: selectedKinds, includeHistory: model.searchIncludesHistory)
            guard !Task.isCancelled else { return }
            model.searchResults = matches
            searching = false
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView("Search Crosscurrent", systemImage: "magnifyingglass", description: Text("Find stories, articles, sources, people, and topics in your library."))
        } else if model.searchResults.isEmpty {
            if !searching {
                ContentUnavailableView.search(text: model.searchQuery)
            } else {
                Color.clear
            }
        } else {
            List(model.searchResults) { result in
                Button { Task { await model.openSearchResult(result) } } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if !result.snippet.isEmpty {
                            Text(result.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Text(result.kind.displayName)
                            if result.isHistorical {
                                Text("·").accessibilityHidden(true)
                                Label("Earlier version", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .multilineTextAlignment(.leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search-result-\(result.kind.rawValue)-\(result.id)")
            }
            .listStyle(.inset)
        }
    }

    private var selectedKinds: Set<SearchDocumentKind> {
        switch model.searchFacet {
        case "Items": [.item]
        case "Events": [.event]
        case "People": [.person, .organization]
        case "Sources": [.source]
        case "Topics": [.topic]
        default: Set(SearchDocumentKind.allCases)
        }
    }

}

private struct SearchTaskKey: Hashable {
    var query: String
    var facet: String
    var includeHistory: Bool
    var generation: Int64
}

private extension SearchDocumentKind {
    var displayName: String {
        switch self {
        case .item: String(localized: "Item")
        case .event: String(localized: "Event")
        case .source: String(localized: "Source")
        case .person: String(localized: "Person")
        case .organization: String(localized: "Organization")
        case .topic: String(localized: "Topic")
        }
    }
}
