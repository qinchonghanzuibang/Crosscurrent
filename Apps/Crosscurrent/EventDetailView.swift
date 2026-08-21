import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import CrosscurrentReader
import CrosscurrentStorage
import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = "Overview"
    @State private var choosingMergeTarget = false
    @State private var evidence: [StoredEventEvidence] = []
    @State private var history: [StoredEventRevisionSummary] = []
    @State private var coverage = StoredCoverageComparison()
    @State private var perspectiveSynthesis = ""
    @State private var perspectiveSynthesisStatus = ""

    private var event: EventCardModel? { model.events.first { $0.id == model.selectedEventID } }

    var body: some View {
        if let event {
            VStack(spacing: 0) {
                header(event)
                EventSectionStrip(selection: $tab)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                Divider()
                Group {
                    switch tab {
                    case "Reader": ReaderPane(event: event, evidence: evidence)
                    case "Primary": primarySource(event)
                    case "Sources": sources
                    case "Timeline": timeline(event)
                    case "Perspectives": perspectives(event)
                    default: overview(event)
                    }
                }
            }
            .onAppear { model.setEventRead(event) }
            .task(id: event.id) {
                async let loadedEvidence = model.evidence(for: event.id)
                async let loadedHistory = model.revisionHistory(for: event.id)
                async let loadedCoverage = model.coverageComparison(for: event.id)
                evidence = await loadedEvidence
                history = await loadedHistory
                coverage = await loadedCoverage
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { model.toggleSaved(event) } label: {
                        Label(model.savedEventIDs.contains(event.id) ? "Saved" : "Save", systemImage: model.savedEventIDs.contains(event.id) ? "bookmark.fill" : "bookmark")
                    }
                    Button("Mark Unread") { model.setEventUnread(event) }
                    Button("Merge") { choosingMergeTarget = true }
                    Button("Split") { Task { await model.splitPrimaryMembership(event) } }.disabled(event.membershipCount < 2)
                    Menu("Correct") {
                        Button("Confirm membership") { Task { await model.confirmPrimaryMembership(event) } }
                        Button("Reject membership") { Task { await model.rejectPrimaryMembership(event) } }
                    }
                }
            }
            .sheet(isPresented: $choosingMergeTarget) {
                NavigationStack {
                    List(model.events.filter { $0.id != event.id }) { candidate in
                        Button {
                            choosingMergeTarget = false
                            Task { await model.merge(event, with: candidate) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title).font(.headline)
                                Text(candidate.primarySource).font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                    .navigationTitle("Merge with Event")
                    .toolbar { ToolbarItem { Button("Cancel") { choosingMergeTarget = false } } }
                }.frame(minWidth: 540, minHeight: 420)
            }
        } else {
            ContentUnavailableView("Choose an Event", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func header(_ event: EventCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { StatusPill(event.readStatus == .updated ? String(localized: "Updated") : String(localized: "Event"), color: event.readStatus == .updated ? CrosscurrentColor.update : CrosscurrentColor.accent); Spacer(); Text(event.date, style: .relative).foregroundStyle(.secondary) }
            Text(event.title).font(.system(size: 34, weight: .bold, design: .serif)).tracking(-0.7)
            Text(event.summary).font(.title3).foregroundStyle(.secondary).lineSpacing(3)
            Text(String.localizedStringWithFormat(String(localized: "Primary: %@ · %lld independent evidence groups"), event.primarySource, event.independentSourceCount)).font(.caption).foregroundStyle(.secondary)
        }.padding(28)
    }

    private func overview(_ event: EventCardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionRule("Overview")
                Text(event.summary).font(.title3)
                SectionRule("Evidence", trailing: String.localizedStringWithFormat(String(localized: "%lld exact assertions"), evidence.count))
                if evidence.isEmpty {
                    ContentUnavailableView("No canonical evidence loaded", systemImage: "doc.text.magnifyingglass")
                } else {
                    ForEach(evidence.prefix(3)) { assertion in
                        EvidenceRow(source: assertion.sourceName, title: assertion.title, text: assertion.excerpt, metadata: evidenceMetadata(assertion))
                    }
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func primarySource(_ event: EventCardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionRule("Primary Source")
                if let primary = evidence.first(where: \.isPrimary) {
                    EvidenceRow(source: primary.sourceName, title: primary.title, text: primary.excerpt, metadata: evidenceMetadata(primary))
                } else {
                    ContentUnavailableView("Primary evidence unavailable", systemImage: "doc.badge.ellipsis")
                }
                Text("Primary-source selection is deterministic and the EventRevision stores the exact membership assertion; later revisions never rewrite this provenance.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var sources: some View {
        Group {
            if evidence.isEmpty { ContentUnavailableView("No canonical evidence loaded", systemImage: "doc.text") }
            else {
                List(evidence) { assertion in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(assertion.sourceName).font(.headline); if assertion.isPrimary { StatusPill("Primary") }; Spacer(); Text(assertion.confidence.value, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary) }
                        Text(assertion.title).font(.subheadline)
                        Text(evidenceMetadata(assertion)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }
    }

    private func timeline(_ event: EventCardModel) -> some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView("No revision history loaded", systemImage: "clock.arrow.circlepath")
            } else {
                List(history) { revision in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: revision.id == event.revisionID ? "circle.fill" : "circle")
                            .foregroundStyle(revision.id == event.revisionID ? CrosscurrentColor.accent : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(revision.title).font(.headline)
                            Text(String.localizedStringWithFormat(String(localized: "Revision %lld · %@ · %lld evidence assertions"), revision.ordinal, revision.changeKind.displayName, revision.evidenceCount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(revision.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }
    }

    private func perspectives(_ event: EventCardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionRule("Different perspectives")
                if evidence.count < 2 {
                    ContentUnavailableView("More independent evidence is needed", systemImage: "rectangle.3.group.bubble")
                } else {
                    ForEach(evidence.filter { !$0.isPrimary }.prefix(4)) { assertion in
                        EvidenceRow(source: assertion.sourceName, title: assertion.title, text: assertion.excerpt, metadata: evidenceMetadata(assertion))
                    }
                }
                SectionRule("Coverage Comparison", trailing: coverage.isQualified ? String(localized: "Evidence-qualified") : String(localized: "More classified evidence needed"))
                HStack(alignment: .top, spacing: 16) {
                    coverageColumn("China-focused", evidence: coverage.chinaFocused)
                    coverageColumn("Global-focused", evidence: coverage.globalFocused)
                }
                Text("This provider-free comparison shows classified independent Sources, timing, primary evidence, and factual evidence excerpts. It does not infer framing, sentiment, motive, language, or nationality.")
                    .font(.caption).foregroundStyle(.secondary)
                SectionRule("Perspective Synthesis")
                if model.providerConfigured {
                    Button("Generate cited perspective synthesis") { Task { await generatePerspectiveSynthesis(event) } }
                        .disabled(!coverage.isQualified || perspectiveSynthesisStatus == String(localized: "Generating…"))
                    if !perspectiveSynthesisStatus.isEmpty { Text(perspectiveSynthesisStatus).font(.caption).foregroundStyle(.secondary) }
                    if !perspectiveSynthesis.isEmpty { Text(perspectiveSynthesis).textSelection(.enabled) }
                } else {
                    Text("Configure a policy-permitted reasoning provider to synthesize framing or emphasis differences with citations. Crosscurrent does not generate a pseudo-semantic narrative without one.")
                        .foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func coverageColumn(_ title: LocalizedStringKey, evidence: [StoredCoverageEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text("\(Set(evidence.map(\.independenceGroup)).count) independent Sources · \(evidence.count) evidence spans")
                .font(.caption).foregroundStyle(.secondary)
            if evidence.isEmpty {
                Text("No classified evidence").foregroundStyle(.tertiary)
            } else {
                ForEach(evidence.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(item.sourceName).font(.subheadline.bold()); if item.isPrimary { StatusPill("Primary") } }
                        Text(item.title).font(.caption).lineLimit(2)
                        Text(item.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        if let date = item.publishedAt { Text(date, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func evidenceMetadata(_ assertion: StoredEventEvidence) -> String {
        let primary = assertion.isPrimary ? String(localized: "Primary") : assertion.role.rawValue.capitalized
        return "\(primary) · ItemRevision \(assertion.itemRevisionID.description.prefix(8)) · bytes \(assertion.span.utf8Start)–\(assertion.span.utf8Start + assertion.span.utf8Length)"
    }

    private func generatePerspectiveSynthesis(_ event: EventCardModel) async {
        guard coverage.isQualified else {
            perspectiveSynthesisStatus = String(localized: "More classified independent evidence is required.")
            return
        }
        let inputs = (coverage.chinaFocused + coverage.globalFocused).enumerated().map { index, item in
            "[E\(index + 1)] ecosystem=\(item.ecosystem.rawValue); source=\(item.sourceName); membership=\(item.id.description); primary=\(item.isPrimary); published=\(item.publishedAt?.ISO8601Format() ?? "unknown")\n\(item.excerpt)"
        }.joined(separator: "\n\n")
        perspectiveSynthesisStatus = String(localized: "Generating…")
        do {
            let result = try await model.performAI(
                task: .chinaGlobalComparison,
                input: "Describe only supported framing, emphasis, or claim-presence differences. Cite every statement with one or more [E#] labels. Keep language, information ecosystem, publisher location, and nationality separate.\n\n\(inputs)",
                event: event
            )
            guard result.contains("[E") else { throw AIProviderError.invalidResponse }
            perspectiveSynthesis = result
            perspectiveSynthesisStatus = String(localized: "Generated with the configured reasoning route; citations map to exact membership assertions above.")
        } catch {
            perspectiveSynthesisStatus = error.localizedDescription
        }
    }
}

private struct EventSectionStrip: View {
    @Binding var selection: String
    private let sections = ["Overview", "Timeline", "Primary", "Sources", "Perspectives", "Reader"]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sections, id: \.self) { section in
                Button {
                    selection = section
                } label: {
                    Text(LocalizedStringKey(section))
                        .font(.subheadline.weight(selection == section ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.white : Color.primary)
                .background(selection == section ? CrosscurrentColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityAddTraits(selection == section ? .isSelected : [])
                .accessibilityIdentifier("event-section-\(section.lowercased())")
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: 650)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }
}

private struct EvidenceRow: View {
    var source: String; var title: String; var text: String; var metadata: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SourceMonogram(source)
            VStack(alignment: .leading, spacing: 5) {
                Text(source).font(.headline)
                Text(title).font(.subheadline.weight(.medium))
                Text(text).foregroundStyle(.secondary).lineLimit(5)
                Text(metadata).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension RevisionChangeKind {
    var displayName: String {
        switch self {
        case .initial: String(localized: "Initial")
        case .minorMetadata: String(localized: "Metadata update")
        case .contentUpdate: String(localized: "Content update")
        case .majorUpdate: String(localized: "Major update")
        case .correction: String(localized: "Correction")
        case .merge: String(localized: "Merge")
        case .split: String(localized: "Split")
        }
    }
}

private struct ReaderPane: View {
    @EnvironmentObject private var model: AppModel
    var event: EventCardModel
    var evidence: [StoredEventEvidence]
    @State private var selection: ReaderSelectionContext?
    @State private var activatedLink: URL?
    @State private var linkPreview: LinkPreview?
    @State private var resultTitle = ""
    @State private var resultText = ""
    @State private var showResult = false
    @State private var showOriginal = false
    private let previewFetcher = LinkPreviewFetcher()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Selection actions") {
                    Button("Explain") { runSelection(.explain) }
                    Button("Translate") { runSelection(.translate) }
                    Button("Summarize") { runSelection(.summarize) }
                    Button("Ask AI") { runSelection(.askAI) }
                }.disabled(selection == nil)
                Menu("Article actions") {
                    Button("Summary") { show(String(localized: "Summary"), extractiveSummary) }
                    Button("Key points") { show(String(localized: "Key points"), extractiveKeyPoints) }
                    Button("Ask article") { runAI(task: .askArticle, title: String(localized: "Ask article"), input: event.summary) }
                    Divider()
                    Button("Open original") { openOriginal() }.disabled(event.originalURL == nil)
                }
                if let selection {
                    Text("\(selection.span.utf8Length) bytes selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(10)
            if let linkPreview {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(linkPreview.title).font(.subheadline.weight(.semibold))
                        if let summary = linkPreview.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Button("Preview") { showOriginal = true }
                }.padding(10).background(.quaternary.opacity(0.35))
            }
            Divider()
            ReaderWebView(
                document: ReaderDocument(id: event.revisionID.description, title: event.title, byline: event.primarySource, sanitizedHTML: event.bodyHTML, itemRevisionID: event.primaryItemRevisionID),
                selection: $selection,
                activatedLink: $activatedLink
            )
        }
        .task(id: activatedLink) {
            guard let activatedLink else { linkPreview = nil; return }
            do { linkPreview = try await previewFetcher.preview(for: activatedLink) }
            catch { show(String(localized: "Link preview unavailable"), error.localizedDescription) }
        }
        .alert(resultTitle, isPresented: $showResult) { Button("OK", role: .cancel) {} } message: { Text(resultText) }
        .sheet(isPresented: $showOriginal) {
            if let url = activatedLink ?? event.originalURL {
                PublicOriginalWebView(url: url).frame(minWidth: 900, minHeight: 650)
            }
        }
    }

    private var extractiveSummary: String {
        guard let primary = evidence.first(where: \.isPrimary) ?? evidence.first else { return event.summary }
        return "\(primary.excerpt)\n\n[\(citation(primary))]"
    }

    private var extractiveKeyPoints: String {
        let selected = evidence.reduce(into: [StoredEventEvidence]()) { values, assertion in
            guard values.count < 3, !values.contains(where: { $0.excerpt == assertion.excerpt }) else { return }
            values.append(assertion)
        }
        guard !selected.isEmpty else { return event.summary }
        return selected.map { "• \($0.excerpt)\n  [\(citation($0))]" }.joined(separator: "\n")
    }

    private func citation(_ assertion: StoredEventEvidence) -> String {
        let end = assertion.span.utf8Start + assertion.span.utf8Length
        return "\(assertion.sourceName) · ItemRevision \(assertion.itemRevisionID.description) · bytes \(assertion.span.utf8Start)–\(end)"
    }

    private func runSelection(_ action: ReaderSelectionAction) {
        guard let selection else { return }
        if action == .summarize {
            show(String(localized: "Summarize"), selection.selectedText)
        } else {
            let task: AITask = switch action {
            case .explain: .explainSelection
            case .translate: .translation
            case .askAI: .askSelection
            case .summarize: .summarizeSelection
            }
            runAI(task: task, title: actionTitle(action), input: selection.selectedText)
        }
    }

    private func actionTitle(_ action: ReaderSelectionAction) -> String {
        switch action {
        case .explain: String(localized: "Explain")
        case .translate: String(localized: "Translate")
        case .summarize: String(localized: "Summarize")
        case .askAI: String(localized: "Ask AI")
        }
    }

    private func runAI(task: AITask, title: String, input: String) {
        guard model.providerConfigured else {
            show(title, String(localized: "Configure an AI provider to use this action. Reading, search, ranking, and extractive summaries remain available."))
            return
        }
        Task {
            do { show(title, try await model.performAI(task: task, input: input, event: event)) }
            catch { show(title, error.localizedDescription) }
        }
    }

    private func openOriginal() {
        guard event.originalURL != nil else { return }
        if event.originalAccountID != nil {
            Task { await model.openAuthenticatedOriginal(event) }
        } else {
            activatedLink = nil
            showOriginal = true
        }
    }

    private func show(_ title: String, _ text: String) {
        resultTitle = title
        resultText = text
        showResult = true
    }
}
