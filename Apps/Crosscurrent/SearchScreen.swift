import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import CrosscurrentSearch
import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var includeHistory = false
    @State private var facet = "All"
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        LibraryPageShell("Search", subtitle: "Find stories, sources, people, and topics") {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Image(systemName: "magnifyingglass"); TextField("Items, Events, Sources, People, organizations, Topics", text: $query).textFieldStyle(.plain).font(.title3).focused($searchFocused); Toggle("History", isOn: $includeHistory).toggleStyle(.button) }.padding(12).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                Picker("Facet", selection: $facet) { ForEach(["All", "Items", "Events", "People", "Sources", "Topics"], id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 560)
            }
        } content: {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search Crosscurrent", systemImage: "magnifyingglass", description: Text("Search current Items, Events, Sources, People, organizations, and Topics. History is opt-in."))
            } else if searching {
                ProgressView("Searching current revisions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { result in
                    Button { Task { await model.openSearchResult(result) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.headline)
                            Text(result.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(result.isHistorical ? String(localized: "Historical revision") : String(localized: "Current revision")) · \(result.kind.displayName)")
                                .font(.caption).foregroundStyle(result.isHistorical ? .secondary : CrosscurrentColor.accent)
                            Text(result.matchReasons.map(\.displayName).sorted().joined(separator: " + "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { searchFocused = true }
        .task(id: SearchTaskKey(query: query, facet: facet, includeHistory: includeHistory, generation: model.canonicalGeneration)) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; searching = false; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let matches = await model.search(query, kinds: selectedKinds, includeHistory: includeHistory)
            guard !Task.isCancelled else { return }
            results = matches
            searching = false
        }
    }

    private var selectedKinds: Set<SearchDocumentKind> {
        switch facet {
        case "Items": [.item]
        case "Events": [.event]
        case "People": [.person, .organization]
        case "Sources": [.source]
        case "Topics": [.topic]
        default: Set(SearchDocumentKind.allCases)
        }
    }

}

private extension SearchResult.MatchReason {
    var displayName: String {
        switch self {
        case .lexical: String(localized: "Lexical")
        case .semantic: String(localized: "Semantic")
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
