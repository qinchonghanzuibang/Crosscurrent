import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import SwiftUI

struct EventListRow: View {
    var event: EventCardModel
    var isSaved: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EventReadMarker(event.readStatus).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(.system(size: 14, weight: event.readStatus == .read ? .medium : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !event.summary.isEmpty {
                    Text(event.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    Text(event.primarySource).lineLimit(1)
                    if event.sourceCount > 1 {
                        Text("·").accessibilityHidden(true)
                        Text(String.localizedStringWithFormat(String(localized: "%lld sources"), event.sourceCount))
                            .fixedSize()
                    }
                    if isSaved {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(CrosscurrentColor.accent)
                            .accessibilityLabel("Saved")
                    }
                    Spacer(minLength: 8)
                    EventTimestamp(date: event.date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
        .help(event.reasons.map(eventRankingReasonLabel).joined(separator: "\n"))
    }
}

struct EventTimestamp: View {
    var date: Date

    var body: some View {
        Text(label)
            .lineLimit(1)
            .fixedSize()
            .help(date.formatted(date: .complete, time: .shortened))
    }

    private var label: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: .now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

func eventRankingReasonLabel(_ reason: RankingReason) -> String {
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
    case .freshPublication: String(localized: "Fresh publication")
    case .materialUpdate: String(localized: "Material update")
    case .readingValue: String(localized: "Worth reading")
    }
}
