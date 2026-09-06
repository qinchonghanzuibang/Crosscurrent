import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                masthead
                if model.events.isEmpty {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "Your briefing starts here",
                            systemImage: "newspaper",
                            description: Text("Add a source to bring the stories you follow into Today.")
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
                        Text("Explore Flow for earlier stories, or refresh your sources.")
                    } actions: {
                        Button("Explore Flow") { model.selection = .flow }
                    }
                    .padding(.vertical, 42)
                } else {
                    let lead = section(.today)
                    SectionRule("Worth knowing", trailing: Self.leadEventCount(lead.count))
                    if lead.isEmpty {
                        Text("No highlights right now. More stories are available below.")
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
                        SectionRule("China ↔ Global")
                        compactRows(section(.chinaGlobal))
                    }
                    let remaining = section(.everythingElse)
                    if !remaining.isEmpty {
                        DisclosureGroup(isExpanded: $model.todayEverythingExpanded) {
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
                }
            }
            Rectangle().frame(height: 3).foregroundStyle(.primary)
        }
    }

    private func compactRows(_ events: [EventCardModel]) -> some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Button { model.open(event) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            EventReadMarker(event.readStatus).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title)
                                    .font(.system(size: 14, weight: event.readStatus == .read ? .medium : .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                HStack {
                                    Text(event.primarySource).lineLimit(1)
                                    Spacer(minLength: 8)
                                    EventTimestamp(date: event.date)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today-compact-event-\(event.id.description)")
                    if !event.reasons.isEmpty {
                        Menu {
                            ForEach(event.reasons, id: \.self) { Text(eventRankingReasonLabel($0)) }
                        } label: { Label("Why this story?", systemImage: "info.circle") }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Why this story?")
                    }
                }
                .padding(.vertical, 10)
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
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 9) {
                        SourceMonogram(event.primarySource, size: 24)
                        Text(event.primarySource).font(.caption.weight(.semibold)).lineLimit(1)
                        if event.sourceCount > 1 {
                            Text(String.localizedStringWithFormat(String(localized: "%lld sources"), event.sourceCount))
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        Spacer(minLength: 8)
                        EventTimestamp(date: event.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.reasons.map(eventRankingReasonLabel).joined(separator: "\n"))
    }

}
