import FeedFlowDesignSystem
import FeedFlowDomain
import FeedFlowModels
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                masthead
                if !model.providerConfigured { ProviderFreeBanner() }
                if model.events.isEmpty {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "No Events Yet",
                            systemImage: "newspaper",
                            description: Text("Add or refresh Sources to build your first evidence-backed daily briefing.")
                        )
                        Button("Add a Source") { model.selection = .sources }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                } else {
                    SectionRule("Today", trailing: Self.leadEventCount(min(5, model.events.count)))
                    ForEach(Array(model.events.prefix(5).enumerated()), id: \.element.id) { index, event in
                        TodayEventCard(event: event, index: index + 1) { model.open(event) }
                            .accessibilityIdentifier("today-event-\(event.id.description)")
                        if index < min(4, model.events.count - 1) { Divider() }
                    }
                    SectionRule("Emerging")
                    compactRows(Array(model.events.dropFirst(2).prefix(3)))
                    SectionRule("From People You Follow")
                    compactRows(model.events.filter { !$0.followedPeople.isEmpty })
                    if model.events.contains(where: { $0.reasons.contains(.chinaGlobalCoverage) }) {
                        SectionRule("China ↔ Global", trailing: "Evidence-qualified comparison")
                        compactRows(model.events.filter { $0.reasons.contains(.chinaGlobalCoverage) })
                    }
                    SectionRule("Everything Else")
                    compactRows(Array(model.events.suffix(2)))
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem { Button { model.manualRefreshToday() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.digestUpdatedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.6).foregroundStyle(FeedFlowColor.accent)
            HStack(alignment: .lastTextBaseline) {
                Text("Today").font(.system(size: 48, weight: .black, design: .serif)).tracking(-1.8)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.digestRevisionReason == .initialDaily ? "Daily snapshot" : "Updated briefing").font(.subheadline.weight(.semibold))
                    Text(model.digestUpdatedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Rectangle().frame(height: 3).foregroundStyle(FeedFlowColor.ink)
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
                    }.padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-compact-event-\(event.id.description)")
                Divider()
            }
        }
    }

    private static func leadEventCount(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld lead events"), count)
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
                        Text(event.topics.first ?? "Event").font(.caption.weight(.semibold)).foregroundStyle(FeedFlowColor.accent)
                    }
                    Text(event.title).font(.system(size: 25, weight: .bold, design: .serif)).tracking(-0.35).multilineTextAlignment(.leading).foregroundStyle(.primary)
                    Text(event.summary).font(.body).foregroundStyle(.secondary).lineSpacing(3).multilineTextAlignment(.leading)
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

struct ProviderFreeBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu").font(.title3).foregroundStyle(FeedFlowColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local briefing mode").font(.subheadline.weight(.semibold))
                Text("Ingestion, clustering, ranking, search, and cited extractive summaries remain active. Configure an AI provider for generative actions.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Configure") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
        .padding(14).background(FeedFlowColor.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
