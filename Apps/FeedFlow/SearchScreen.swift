import FeedFlowDesignSystem
import FeedFlowDomain
import FeedFlowModels
import FeedFlowSearch
import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var includeHistory = false
    @State private var facet = "All"
    @State private var results: [SearchResult] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Search").font(.largeTitle.bold())
                HStack { Image(systemName: "magnifyingglass"); TextField("Items, Events, Sources, People, organizations, Topics", text: $query).textFieldStyle(.plain).font(.title3); Toggle("History", isOn: $includeHistory).toggleStyle(.button) }.padding(12).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                Picker("Facet", selection: $facet) { ForEach(["All", "Events", "People", "Sources", "Topics"], id: \.self, content: Text.init) }.pickerStyle(.segmented).frame(maxWidth: 500)
            }.padding(24)
            Divider()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search FeedFlow", systemImage: "magnifyingglass", description: Text("Search current Items, Events, Sources, People, organizations, and Topics. History is opt-in."))
            } else if searching {
                ProgressView("Searching current revisions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { result in
                    Button { open(result) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.headline)
                            Text(result.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(result.isHistorical ? String(localized: "Historical revision") : String(localized: "Current revision")) · \(result.kind.displayName)")
                                .font(.caption).foregroundStyle(result.isHistorical ? .secondary : FeedFlowColor.accent)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .task(id: SearchTaskKey(query: query, facet: facet, includeHistory: includeHistory)) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            results = await model.search(query, kinds: selectedKinds, includeHistory: includeHistory)
            searching = false
        }
    }

    private var selectedKinds: Set<SearchDocumentKind> {
        switch facet {
        case "Events": [.event]
        case "People": [.person, .organization]
        case "Sources": [.source]
        case "Topics": [.topic]
        default: Set(SearchDocumentKind.allCases)
        }
    }

    private func open(_ result: SearchResult) {
        guard result.kind == .event,
              let uuid = UUID(uuidString: result.stableID),
              let event = model.events.first(where: { $0.id == EventID(uuid) })
        else { return }
        model.open(event)
    }
}

private struct SearchTaskKey: Hashable {
    var query: String
    var facet: String
    var includeHistory: Bool
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
