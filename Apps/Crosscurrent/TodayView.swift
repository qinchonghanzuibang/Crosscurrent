import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var everythingExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                masthead
                if model.events.isEmpty {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "No Events Yet",
                            systemImage: "newspaper",
                            description: Text("Add or refresh Sources to build your first evidence-backed daily briefing.")
                        )
                        Button("Add a Source") { model.showAddSource() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                } else if model.digestSections.values.allSatisfy(\.isEmpty) {
                    ContentUnavailableView {
                        Label("No new developments", systemImage: "checkmark.circle")
                    } description: {
                        Text("Your library is ready. Explore Flow for earlier articles, or refresh your sources for new developments.")
                    } actions: {
                        Button("Explore Flow") { model.selection = .flow }
                    }
                    .padding(.vertical, 42)
                } else {
                    let lead = section(.today)
                    SectionRule("Worth knowing", trailing: Self.leadEventCount(lead.count))
                    if lead.isEmpty {
                        Text("No Event currently meets the evidence and relevance bar for the top five. The remaining briefing stays available below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(lead.enumerated()), id: \.element.id) { index, event in
                            TodayEventCard(event: event, index: index + 1) { model.open(event) }
                                .accessibilityIdentifier("today-event-\(event.id.description)")
                            if index < lead.count - 1 { Divider() }
                        }
                    }
                    optionalSection("Emerging", events: section(.emerging))
                    optionalSection("From Your Follows", events: section(.peopleYouFollow))
                    optionalSection("Worth Reading", events: section(.worthReading))
                    if !section(.chinaGlobal).isEmpty {
                        SectionRule("China ↔ Global", trailing: "Evidence-qualified comparison")
                        compactRows(section(.chinaGlobal))
                    }
                    let remaining = section(.everythingElse)
                    if !remaining.isEmpty {
                        DisclosureGroup(isExpanded: $everythingExpanded) {
                            compactRows(remaining)
                        } label: {
                            Text("Everything Else · \(remaining.count)").font(.title3.bold())
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem {
                if model.refreshInProgress { ProgressView().controlSize(.small).help("Refreshing sources…") }
                else { Button { model.manualRefreshToday() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.activityMessage {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.activityMessage = nil } label: { Label("Dismiss", systemImage: "xmark") }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }.padding(12).background(.bar)
            }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.digestUpdatedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.6).foregroundStyle(CrosscurrentColor.accent)
            HStack(alignment: .lastTextBaseline) {
                Text("Today").font(.system(size: 40, weight: .black, design: .serif)).tracking(-1.4)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.digestRevisionReason == .initialDaily ? "Daily snapshot" : "Updated briefing").font(.subheadline.weight(.semibold))
                    Text(model.digestUpdatedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if !model.providerConfigured {
                        Label("Local briefing", systemImage: "cpu").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Rectangle().frame(height: 3).foregroundStyle(.primary)
        }
    }

    private func compactRows(_ events: [EventCardModel]) -> some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                Button { model.open(event) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        EventReadMarker(event.readStatus)
                        Text(event.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer()
                        Text(event.primarySource).font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Text("Why here?")
                            ForEach(event.reasons, id: \.self) { Text(LocalizedStringKey(reasonLabel($0))) }
                        } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton)
                    }.padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-compact-event-\(event.id.description)")
                Divider()
            }
        }
    }

    @ViewBuilder
    private func optionalSection(_ title: String, events: [EventCardModel]) -> some View {
        if !events.isEmpty {
            SectionRule(title)
            compactRows(events)
        }
    }

    private func section(_ section: DigestSection) -> [EventCardModel] {
        model.digestSections[section] ?? []
    }

    private static func leadEventCount(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld lead events"), count)
    }

    private func reasonLabel(_ reason: RankingReason) -> String {
        switch reason {
        case .followedSource: "From a Source you follow"
        case .followedPerson: "From a person you follow"
        case .followedTopic: "Matches a Topic you follow"
        case .primarySource: "Strong primary evidence"
        case .independentCoverage: "Independent coverage"
        case .rapidGrowth: "Coverage is accelerating"
        case .novelDevelopment: "Material new development"
        case .chinaGlobalCoverage: "Evidence across ecosystems"
        case .savedRelationship: "Related to something saved"
        case .freshPublication: "Fresh publication"
        case .materialUpdate: "Material update"
        case .readingValue: "Substantial primary reading"
        }
    }
}

private struct TodayEventCard: View {
    var event: EventCardModel
    var index: Int
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 18) {
                Text(String(format: "%02d", index)).font(.system(.title3, design: .monospaced).weight(.light)).foregroundStyle(.tertiary).frame(width: 28)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        EventReadMarker(event.readStatus)
                        Text(event.topics.first ?? String(localized: "Event")).font(.caption.weight(.semibold)).foregroundStyle(CrosscurrentColor.accent)
                    }
                    Text(event.title)
                        .font(.system(size: 25, weight: .bold, design: .serif))
                        .tracking(-0.35)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(event.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 9) {
                        SourceMonogram(event.primarySource, size: 24)
                        Text(event.primarySource).font(.caption.weight(.semibold))
                        Text(Self.sourceSummary(independent: event.independentSourceCount, total: event.sourceCount)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(event.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func sourceSummary(independent: Int, total: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld independent · %lld sources"), independent, total)
    }

}
