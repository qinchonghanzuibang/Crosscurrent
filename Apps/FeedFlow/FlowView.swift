import FeedFlowDesignSystem
import FeedFlowDomain
import FeedFlowModels
import SwiftUI

struct FlowView: View {
    @EnvironmentObject private var model: AppModel
    @State private var ranked = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Flow").font(.largeTitle.bold())
                Spacer()
                Picker("Order", selection: $ranked) {
                    Text("Ranked").tag(true)
                    Text("Chronological").tag(false)
                }.pickerStyle(.segmented).frame(width: 230)
            }.padding(24)
            Divider()
            if sortedEvents.isEmpty {
                ContentUnavailableView(
                    "No Events in Flow",
                    systemImage: "line.3.horizontal.decrease",
                    description: Text("Refresh a Source to ingest evidence; FeedFlow will cluster supported developments without requiring an AI provider.")
                )
            } else {
                List(sortedEvents) { event in
                    Button { model.open(event) } label: { FlowEventRow(event: event, isSaved: model.savedEventIDs.contains(event.id)) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(model.savedEventIDs.contains(event.id) ? "Remove from Saved" : "Save Event") { model.toggleSaved(event) }
                            Button("Mark Unread") { model.setEventUnread(event) }
                        }
                }.listStyle(.inset)
            }
        }
    }

    private var sortedEvents: [EventCardModel] {
        ranked ? model.events.sorted { $0.score > $1.score } : model.events.sorted { $0.date > $1.date }
    }
}

private struct FlowEventRow: View {
    var event: EventCardModel
    var isSaved: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            EventReadMarker(event.readStatus).frame(minWidth: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.title).font(.headline).lineLimit(2)
                Text(event.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 7) {
                    Text(event.primarySource).font(.caption.weight(.semibold))
                    Text(Self.sourceCount(event.sourceCount)).font(.caption).foregroundStyle(.secondary)
                    ForEach(event.topics.prefix(2), id: \.self) { StatusPill($0, color: .secondary) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(event.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                Text(event.reasons.first.map(reasonText) ?? "Ranked").font(.caption2).foregroundStyle(FeedFlowColor.accent)
                if isSaved { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(FeedFlowColor.accent) }
            }
        }.padding(.vertical, 10)
    }

    private func reasonText(_ reason: RankingReason) -> String {
        switch reason {
        case .followedSource: String(localized: "Followed source")
        case .followedPerson: String(localized: "Person you follow")
        case .followedTopic: String(localized: "Topic you follow")
        case .primarySource: String(localized: "Primary source")
        case .independentCoverage: String(localized: "Independent coverage")
        case .rapidGrowth: String(localized: "Growing quickly")
        case .novelDevelopment: String(localized: "New development")
        case .chinaGlobalCoverage: String(localized: "Cross-ecosystem")
        case .savedRelationship: String(localized: "Related to saved")
        }
    }

    private static func sourceCount(_ count: Int) -> String {
        "· " + String.localizedStringWithFormat(String(localized: "%lld sources"), count)
    }
}
