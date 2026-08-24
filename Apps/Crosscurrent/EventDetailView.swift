import CrosscurrentDesignSystem
import CrosscurrentDomain
import CrosscurrentModels
import CrosscurrentReader
import CrosscurrentStorage
import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var choosingMergeTarget = false
    @State private var readingPrimary = false
    @State private var evidence: [StoredEventEvidence] = []
    @State private var history: [StoredEventRevisionSummary] = []
    @State private var coverage = StoredCoverageComparison()
    @State private var perspectiveSynthesis = ""
    @State private var perspectiveSynthesisStatus = ""

    private var event: EventCardModel? { model.events.first { $0.id == model.selectedEventID } }

    var body: some View {
        if let event {
            Group {
                if event.sourceCount <= 1 || event.membershipCount <= 1 || readingPrimary {
                    ReaderPane(event: event, evidence: evidence, backAction: {
                        if event.sourceCount > 1 && readingPrimary { readingPrimary = false }
                        else { model.closeEvent() }
                    })
                } else {
                    eventSummary(event)
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
                if event.sourceCount > 1 && !readingPrimary {
                    ToolbarItemGroup {
                    Button { model.toggleSaved(event) } label: {
                        Label(model.savedEventIDs.contains(event.id) ? "Saved" : "Save", systemImage: model.savedEventIDs.contains(event.id) ? "bookmark.fill" : "bookmark")
                    }
                    Button("Mark Unread") { model.setEventUnread(event) }
                    Menu {
                        Button("This article doesn’t belong in this story") { Task { await model.splitPrimaryMembership(event) } }
                        Button("These are the same story…") { choosingMergeTarget = true }
                        Button("Move this article to another story…") { choosingMergeTarget = true }
                    } label: {
                        Label("Fix story grouping…", systemImage: "ellipsis.circle")
                    }
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
                    .navigationTitle("Choose the matching story")
                    .toolbar { ToolbarItem { Button("Cancel") { choosingMergeTarget = false } } }
                }.frame(minWidth: 540, minHeight: 420)
            }
        } else {
            ContentUnavailableView("Choose an Event", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func eventSummary(_ event: EventCardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(event.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                Text(event.title).font(.system(size: 36, weight: .bold, design: .serif)).tracking(-0.7)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What happened").font(.title2.bold())
                    Text(event.summary).font(.title3).foregroundStyle(.secondary).lineSpacing(3)
                }
                if let primary = evidence.first(where: \.isPrimary) ?? evidence.first {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Primary source").font(.headline)
                        Text(primary.sourceName).font(.subheadline.weight(.semibold))
                        Text(primary.title).foregroundStyle(.secondary)
                        Button("Read", systemImage: "doc.text") { readingPrimary = true }.buttonStyle(.borderedProminent)
                    }
                    .padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
                DisclosureGroup {
                    VStack(spacing: 10) {
                        ForEach(evidence) { assertion in
                            EvidenceRow(source: assertion.sourceName, title: assertion.title, text: assertion.excerpt, metadata: evidenceMetadata(assertion))
                        }
                    }.padding(.top, 10)
                } label: {
                    Text("\(event.independentSourceCount) independent sources · \(event.sourceCount) items").font(.headline)
                }
                let meaningfulHistory = history.filter { $0.changeKind.isReaderVisible }.dropFirst()
                if !meaningfulHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Important updates").font(.title2.bold())
                        ForEach(Array(meaningfulHistory.prefix(4))) { revision in
                            HStack(alignment: .firstTextBaseline) {
                                Text("Updated \(revision.createdAt.formatted(.relative(presentation: .named))) — \(revision.changeKind.displayName)")
                                Spacer()
                                Text("\(revision.evidenceCount) sources").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if coverage.isQualified {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Different perspectives").font(.title2.bold())
                        HStack(alignment: .top, spacing: 16) {
                            coverageColumn("China-focused", evidence: coverage.chinaFocused)
                            coverageColumn("Global-focused", evidence: coverage.globalFocused)
                        }
                        if model.providerConfigured {
                            Button("Generate cited perspective synthesis") { Task { await generatePerspectiveSynthesis(event) } }
                            if !perspectiveSynthesis.isEmpty { Text(perspectiveSynthesis).textSelection(.enabled) }
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
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
        if let publishedAt = assertion.publishedAt {
            return "\(primary) evidence · \(publishedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(primary) evidence"
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
            perspectiveSynthesisStatus = String(localized: "Generated with the configured reasoning route; citations map to the exact evidence above.")
        } catch {
            perspectiveSynthesisStatus = error.localizedDescription
        }
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
    var backAction: () -> Void
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
            HStack(spacing: 12) {
                Button(action: backAction) { Label("Back", systemImage: "chevron.left") }
                Divider().frame(height: 18)
                SourceMonogram(event.primarySource, size: 24)
                Text(event.primarySource).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if !model.focusReading {
                    Button { model.toggleSaved(event) } label: { Image(systemName: model.savedEventIDs.contains(event.id) ? "bookmark.fill" : "bookmark") }
                        .help(model.savedEventIDs.contains(event.id) ? "Saved" : "Save")
                    Button { model.setEventUnread(event) } label: { Image(systemName: "envelope.badge") }.help("Mark Unread")
                    Button { openOriginal() } label: { Image(systemName: "safari") }.help("Open Original").disabled(event.originalURL == nil)
                    Menu {
                        Button("Summary") { show(String(localized: "Summary"), extractiveSummary) }
                        Button("Key points") { show(String(localized: "Key points"), extractiveKeyPoints) }
                        Button("Ask article") { runAI(task: .askArticle, title: String(localized: "Ask article"), input: event.summary) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                Button { model.toggleFocusReading() } label: { Image(systemName: model.focusReading ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .help(model.focusReading ? "Exit Focus Reading" : "Focus Reading (⇧⌘F)")
            }.padding(.horizontal, 12).frame(height: model.focusReading ? 38 : 44)
            if selection != nil && !model.focusReading {
                HStack(spacing: 8) {
                    Text("Selected text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Button("Explain") { runSelection(.explain) }
                    Button("Translate") { runSelection(.translate) }
                    Button("Summarize") { runSelection(.summarize) }
                    Button("Ask AI") { runSelection(.askAI) }
                    Spacer()
                }
                .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.quaternary.opacity(0.3))
            }
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
