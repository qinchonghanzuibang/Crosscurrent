import CrosscurrentDesignSystem
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case today, flow, following, saved, search, eventDetail, itemDetail, libraryDetail
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .flow: "Flow"
        case .following: "Following"
        case .saved: "Saved"
        case .search: "Search"
        case .eventDetail: "Event"
        case .itemDetail: "Item"
        case .libraryDetail: "Detail"
        }
    }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .flow: "line.3.horizontal.decrease"
        case .following: "person.crop.circle.badge.checkmark"
        case .saved: "bookmark"
        case .search: "magnifyingglass"
        case .eventDetail: "doc.text.magnifyingglass"
        case .itemDetail: "doc.richtext"
        case .libraryDetail: "info.circle"
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
                    navigation(.following)
                    navigation(.saved)
                }
                Section { navigation(.search) }
            }
            .navigationTitle("Crosscurrent")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(model.backgroundState == String(localized: "Enabled") ? Color.green : Color.secondary).frame(width: 7, height: 7)
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
        .onChange(of: model.focusReading) { _, focused in columnVisibility = focused ? .detailOnly : .all }
        .onExitCommand {
            guard model.selection == .eventDetail else { return }
            if model.handleReaderEscape() == .navigateBack { model.closeEvent() }
        }
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
        case .following: FollowingView()
        case .saved: SavedView()
        case .search: SearchScreen()
        case .eventDetail: EventDetailView()
        case .itemDetail: ItemDetailView()
        case .libraryDetail: LibraryObjectDetailView()
        }
    }
}
