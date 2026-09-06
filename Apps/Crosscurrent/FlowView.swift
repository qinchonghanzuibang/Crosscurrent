import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import SwiftUI

struct FlowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Flow").font(.title2.bold())
                Spacer()
                Picker("Order", selection: $model.flowRanked) {
                    Text("Ranked").tag(true)
                    Text("Chronological").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230, alignment: .trailing)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if sortedEvents.isEmpty {
                ContentUnavailableView {
                    Label("No stories yet", systemImage: "rectangle.stack")
                } description: {
                    Text("Add a source to start reading, or refresh your sources for new stories.")
                } actions: { Button("Add Source") { model.showAddSource() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sortedEvents) { event in
                    Button { model.open(event) } label: { EventListRow(event: event, isSaved: model.savedEventIDs.contains(event.id)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flow-event-\(event.id.description)")
                        .contextMenu {
                            Button(model.savedEventIDs.contains(event.id) ? "Remove from Saved" : "Save Event") { model.toggleSaved(event) }
                            Button("Mark Unread") { model.setEventUnread(event) }
                            if !event.reasons.isEmpty {
                                Divider()
                                Menu("Why this story?") {
                                    ForEach(event.reasons, id: \.self) { Text(eventRankingReasonLabel($0)) }
                                }
                            }
                        }
                }.listStyle(.inset)
            }
        }
    }

    private var sortedEvents: [EventCardModel] {
        model.events.sorted {
            if model.flowRanked, $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.description < $1.id.description
        }
    }
}
