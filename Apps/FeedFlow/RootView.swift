import FeedFlowDesignSystem
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case today, flow, sources, people, topics, saved, search, eventDetail
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .flow: "Flow"
        case .sources: "Sources"
        case .people: "People"
        case .topics: "Topics"
        case .saved: "Saved"
        case .search: "Search"
        case .eventDetail: "Event"
        }
    }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .flow: "line.3.horizontal.decrease"
        case .sources: "dot.radiowaves.left.and.right"
        case .people: "person.2"
        case .topics: "number"
        case .saved: "bookmark"
        case .search: "magnifyingglass"
        case .eventDetail: "doc.text.magnifyingglass"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.selection) {
                Section {
                    navigation(.today)
                    navigation(.flow)
                }
                Section("Library") {
                    navigation(.sources)
                    navigation(.people)
                    navigation(.topics)
                    navigation(.saved)
                }
                Section { navigation(.search) }
            }
            .navigationTitle("FeedFlow")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(model.backgroundState == String(localized: "Enabled") ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.backgroundState).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            destination
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func navigation(_ destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.symbol)
            .tag(destination)
            .accessibilityIdentifier("sidebar-\(destination.rawValue)")
    }

    @ViewBuilder private var destination: some View {
        switch model.selection ?? .today {
        case .today: TodayView()
        case .flow: FlowView()
        case .sources: SourcesView()
        case .people: PeopleView()
        case .topics: TopicsView()
        case .saved: SavedView()
        case .search: SearchScreen()
        case .eventDetail: EventDetailView()
        }
    }
}
