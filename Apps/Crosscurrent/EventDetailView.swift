import AppKit
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

    private var event: EventCardModel? { model.selectedEvent }

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
            .id(event.revisionID)
            .task(id: event.revisionID) {
                model.setEventRead(event)
                readingPrimary = false
                perspectiveSynthesis = ""
                perspectiveSynthesisStatus = ""
                async let loadedEvidence = model.evidence(for: event.id, revisionID: event.revisionID)
                async let loadedHistory = model.revisionHistory(for: event.id)
                async let loadedCoverage = model.coverageComparison(for: event.id, revisionID: event.revisionID)
                let loaded = await (loadedEvidence, loadedHistory, loadedCoverage)
                guard !Task.isCancelled else { return }
                evidence = loaded.0
                history = loaded.1
                coverage = loaded.2
            }
            .toolbar {
                if event.sourceCount > 1 && event.membershipCount > 1 && !readingPrimary {
                    ToolbarItemGroup {
                    Button("Back", systemImage: "chevron.left") { model.closeEvent() }
                    Button { model.toggleSaved(event) } label: {
                        Label(model.savedEventIDs.contains(event.id) ? "Saved" : "Save", systemImage: model.savedEventIDs.contains(event.id) ? "bookmark.fill" : "bookmark")
                    }
                    Button("Mark Unread") { model.setEventUnread(event) }
                    Menu {
                        Button("This article doesn’t belong in this story") { Task { await model.splitPrimaryMembership(event) } }
                        Button("These are the same story…") { choosingMergeTarget = true }
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
                            Button { Task { await model.openEvidence(assertion) } } label: {
                                EvidenceRow(source: assertion.sourceName, title: assertion.title, text: assertion.excerpt, metadata: evidenceMetadata(assertion))
                            }.buttonStyle(.plain).help("Read this source")
                        }
                    }.padding(.top, 10)
                } label: {
                    Text("\(event.independentSourceCount) independent sources · \(Set(evidence.map(\.itemRevisionID)).count) items").font(.headline)
                }
                let meaningfulHistory = history.filter { $0.changeKind.isReaderVisible && $0.changeKind != .initial }
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
                            if !perspectiveSynthesisStatus.isEmpty { Text(perspectiveSynthesisStatus).font(.caption).foregroundStyle(.secondary) }
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
        let primary = assertion.isPrimary ? String(localized: "Primary") : NSLocalizedString(assertion.role.rawValue.capitalized, comment: "Evidence membership role")
        if let publishedAt = assertion.publishedAt {
            return String(localized: "\(primary) evidence · \(publishedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "\(primary) evidence")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var event: EventCardModel
    var evidence: [StoredEventEvidence]
    var backAction: () -> Void
    @State private var selection: ReaderSelectionContext?
    @State private var activatedLink: URL?
    @State private var linkPreview: LinkPreview?
    @State private var linkPreviewLoading = false
    @State private var linkPreviewMessage: String?
    @State private var showOriginal = false
    @State private var readerFocusRequest = 0
    private let previewFetcher = LinkPreviewFetcher()

    var body: some View {
        VStack(spacing: 0) {
            if selection != nil && !model.focusReading {
                HStack(spacing: 8) {
                    Text("Selected text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Button("Explain") { runSelection(.explain) }
                    Button("Translate") { runSelection(.translate) }
                    Button("Summarize") { runSelection(.summarize) }
                    Button("Ask AI") { runSelection(.askAI) }
                    Spacer()
                }
                .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
            if let activatedLink {
                linkPreviewBar(for: activatedLink)
            }
            GeometryReader { geometry in
                let overlaysInsights = geometry.size.width < 950
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        ReaderWebView(
                            document: ReaderDocument(id: event.revisionID.description, title: event.title, byline: event.primarySource, publishedAt: evidence.first(where: { $0.itemRevisionID == event.primaryItemRevisionID })?.publishedAt, sanitizedHTML: event.bodyHTML, baseURL: event.originalURL, itemRevisionID: event.primaryItemRevisionID),
                            selection: $selection,
                            activatedLink: $activatedLink,
                            focusRequest: readerFocusRequest,
                            onEscape: {
                                if model.handleReaderEscape() == .navigateBack { backAction() }
                            }
                        )
                        if let insights = model.readerInsights, !overlaysInsights {
                            Divider()
                            insightsPanel(insights).frame(width: 320)
                        }
                    }
                    if let insights = model.readerInsights, overlaysInsights {
                        Color.black.opacity(0.08)
                            .onTapGesture { model.dismissReaderInsights() }
                            .accessibilityHidden(true)
                        insightsPanel(insights)
                            .frame(width: min(360, max(280, geometry.size.width - 32)))
                            .overlay(alignment: .leading) { Divider() }
                            .shadow(color: .black.opacity(0.12), radius: 12, x: -4)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.readerInsights?.id)
            }
        }
        .navigationTitle(event.primarySource)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: backAction)
                    .help("Back")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.focusReading {
                    Button { model.toggleSaved(event) } label: {
                        Label(model.savedEventIDs.contains(event.id) ? "Saved" : "Save", systemImage: model.savedEventIDs.contains(event.id) ? "bookmark.fill" : "bookmark")
                    }
                    .help(model.savedEventIDs.contains(event.id) ? "Saved" : "Save")
                    Button("Open Original", systemImage: "safari") { openOriginal() }
                        .help("Open Original").disabled(event.originalURL == nil)
                }
                Menu {
                    Button("Summary") { openSummary() }
                    Button("Key points") { openKeyPoints() }
                    Button("Ask article") { openAskArticle() }
                    Divider()
                    Button("Mark Unread") { model.setEventUnread(event) }
                } label: { Label("Reader actions", systemImage: "ellipsis.circle") }
                .help("Reader actions")
                .accessibilityLabel("Reader actions")
                Button { model.toggleFocusReading() } label: {
                    Label(model.focusReading ? "Exit Focus Reading" : "Focus Reading", systemImage: model.focusReading ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(model.focusReading ? "Exit Focus Reading" : "Focus Reading (⇧⌘F)")
                .accessibilityIdentifier("reader-focus-toggle")
            }
        }
        .task(id: activatedLink) {
            linkPreview = nil
            linkPreviewMessage = nil
            guard let activatedLink else { linkPreviewLoading = false; return }
            linkPreviewLoading = true
            defer { if self.activatedLink == activatedLink { linkPreviewLoading = false } }
            do {
                let preview = try await previewFetcher.preview(for: activatedLink)
                guard !Task.isCancelled else { return }
                linkPreview = preview
            } catch {
                guard !Task.isCancelled else { return }
                linkPreviewMessage = String(localized: "Preview unavailable. You can still open the link.")
            }
        }
        .onChange(of: model.readerInsights?.id) { oldValue, newValue in
            if oldValue != nil, newValue == nil { readerFocusRequest += 1 }
        }
        .sheet(isPresented: $showOriginal) {
            if let url = activatedLink ?? event.originalURL {
                ReaderOriginalSheet(url: url)
            }
        }
    }

    private func insightsPanel(_ insights: ReaderInsightsState) -> some View {
        ReaderInsightsPanel(
            state: insights,
            onClose: model.dismissReaderInsights,
            onRetry: retryInsights,
            onAsk: runArticleQuestion
        )
        .id(insights.id)
        .frame(maxHeight: .infinity)
        .onExitCommand { model.dismissReaderInsights() }
    }

    private func linkPreviewBar(for url: URL) -> some View {
        HStack(spacing: 10) {
            Group {
                if linkPreviewLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: "link").foregroundStyle(.secondary) }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(linkPreview?.title ?? url.host ?? url.absoluteString)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Text(linkPreviewMessage ?? linkPreview?.summary ?? (linkPreviewLoading ? String(localized: "Loading preview…") : url.absoluteString))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open Link") { showOriginal = true }
            Button {
                activatedLink = nil
                linkPreview = nil
                readerFocusRequest += 1
            } label: { Label("Dismiss link preview", systemImage: "xmark") }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var extractiveSummary: [ReaderInsightPoint] {
        ReaderExtractiveInsights.summary(from: insightEvidence, fallback: event.summary)
    }

    private var extractiveKeyPoints: [ReaderInsightPoint] {
        ReaderExtractiveInsights.keyPoints(from: insightEvidence, fallback: event.summary)
    }

    private var insightEvidence: [ReaderEvidenceExcerpt] {
        let articleText = ReaderTextExtractor.plainText(fromSanitizedHTML: event.bodyHTML)
        var values: [ReaderEvidenceExcerpt] = []
        if !articleText.isEmpty {
            values.append(ReaderEvidenceExcerpt(
                text: articleText,
                citation: "\(event.primarySource) · E1",
                isPrimary: true
            ))
        }
        values.append(contentsOf: evidence.enumerated().compactMap { index, assertion in
            guard !assertion.isPrimary || articleText.isEmpty else { return nil }
            return ReaderEvidenceExcerpt(
                text: assertion.excerpt,
                citation: "\(assertion.sourceName) · E\(articleText.isEmpty ? index + 1 : index + 2)",
                isPrimary: assertion.isPrimary
            )
        })
        return values.isEmpty ? [ReaderEvidenceExcerpt(text: event.summary, citation: "\(event.primarySource) · E1", isPrimary: true)] : values
    }

    private var modelEvidenceInput: String {
        insightEvidence.enumerated().map { index, value in
            "[E\(index + 1)] \(value.citation)\n\(value.text)"
        }.joined(separator: "\n\n")
    }

    private func openSummary() {
        let state = ReaderInsightsState(
            kind: .summary,
            title: String(localized: "Summary"),
            phase: model.providerConfigured ? .loading : .ready,
            points: extractiveSummary,
            message: model.providerConfigured ? nil : String(localized: "Created locally from article evidence.")
        )
        model.presentReaderInsights(state)
        guard model.providerConfigured else { return }
        Task { await generateSummary(state) }
    }

    private func generateSummary(_ state: ReaderInsightsState) async {
        do {
            let response = try await model.performAI(task: .articleSummary, input: modelEvidenceInput, event: event)
            guard let concise = ReaderExtractiveInsights.validatedSummary(response) else { throw AIProviderError.invalidResponse }
            var ready = state
            ready.phase = .ready
            ready.body = concise
            ready.points = []
            ready.message = String(localized: "Generated from the cited article evidence.")
            model.updateReaderInsights(ready)
        } catch {
            model.updateReaderInsights(failureState(from: state, error: error, fallback: extractiveSummary))
        }
    }

    private func openKeyPoints() {
        let state = ReaderInsightsState(
            kind: .keyPoints,
            title: String(localized: "Key points"),
            phase: model.providerConfigured ? .loading : .ready,
            points: extractiveKeyPoints,
            message: model.providerConfigured ? nil : String(localized: "Created locally from article evidence.")
        )
        model.presentReaderInsights(state)
        guard model.providerConfigured else { return }
        Task { await generateKeyPoints(state) }
    }

    private func generateKeyPoints(_ state: ReaderInsightsState) async {
        do {
            let response = try await model.performAI(task: .keyPoints, input: modelEvidenceInput, event: event)
            guard let points = ReaderExtractiveInsights.validatedKeyPoints(response) else { throw AIProviderError.invalidResponse }
            var ready = state
            ready.phase = .ready
            ready.points = points.map { ReaderInsightPoint(text: $0) }
            ready.message = String(localized: "Generated from the cited article evidence.")
            model.updateReaderInsights(ready)
        } catch {
            model.updateReaderInsights(failureState(from: state, error: error, fallback: extractiveKeyPoints))
        }
    }

    private func openAskArticle() {
        model.presentReaderInsights(ReaderInsightsState(
            kind: .askArticle,
            title: String(localized: "Ask article"),
            phase: model.providerConfigured ? .ready : .unavailable,
            message: model.providerConfigured
                ? String(localized: "Ask a question grounded in this article’s evidence.")
                : String(localized: "Configure an AI provider to ask questions. Summary and Key Points remain available locally.")
        ))
    }

    private func runSelection(_ action: ReaderSelectionAction) {
        guard let selection else { return }
        if action == .summarize {
            let points = ReaderExtractiveInsights.summary(
                from: [ReaderEvidenceExcerpt(text: selection.selectedText, citation: String(localized: "Selected passage"), isPrimary: true)],
                fallback: selection.selectedText
            )
            model.presentReaderInsights(ReaderInsightsState(kind: .selectionSummary, title: String(localized: "Summarize"), phase: .ready, points: points))
        } else {
            let task: AITask = switch action {
            case .explain: .explainSelection
            case .translate: .translation
            case .askAI: .askSelection
            case .summarize: .summarizeSelection
            }
            runAI(task: task, kind: insightKind(action), title: actionTitle(action), input: selection.selectedText)
        }
    }

    private func insightKind(_ action: ReaderSelectionAction) -> ReaderInsightKind {
        switch action {
        case .explain: .selectionExplain
        case .translate: .selectionTranslation
        case .summarize: .selectionSummary
        case .askAI: .selectionAnswer
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

    private func runAI(task: AITask, kind: ReaderInsightKind, title: String, input: String) {
        let state = ReaderInsightsState(
            kind: kind,
            title: title,
            phase: model.providerConfigured ? .loading : .unavailable,
            message: model.providerConfigured ? nil : String(localized: "Configure an AI provider to use this action.")
        )
        model.presentReaderInsights(state)
        guard model.providerConfigured else { return }
        Task {
            do {
                var ready = state
                ready.phase = .ready
                ready.body = try await model.performAI(task: task, input: input, event: event)
                model.updateReaderInsights(ready)
            } catch {
                model.updateReaderInsights(failureState(from: state, error: error))
            }
        }
    }

    private func runArticleQuestion(_ question: String) {
        guard let current = model.readerInsights, current.kind == .askArticle else { return }
        var loading = current
        loading.phase = .loading
        loading.body = ""
        loading.message = nil
        model.updateReaderInsights(loading)
        Task {
            do {
                var ready = loading
                ready.phase = .ready
                ready.body = try await model.performAI(
                    task: .askArticle,
                    input: "Question: \(question)\n\nArticle evidence:\n\(modelEvidenceInput)",
                    event: event
                )
                model.updateReaderInsights(ready)
            } catch {
                model.updateReaderInsights(failureState(from: loading, error: error))
            }
        }
    }

    private func retryInsights() {
        guard let state = model.readerInsights else { return }
        switch state.kind {
        case .summary: openSummary()
        case .keyPoints: openKeyPoints()
        default: break
        }
    }

    private func failureState(from state: ReaderInsightsState, error: Error, fallback: [ReaderInsightPoint] = []) -> ReaderInsightsState {
        var failed = state
        failed.points = fallback
        failed.message = error.localizedDescription
        failed.canRetry = state.kind == .summary || state.kind == .keyPoints
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .configurationRequired:
                failed.phase = .unavailable
                failed.canRetry = false
            case .policyDenied:
                failed.phase = .denied
                failed.canRetry = false
            default:
                failed.phase = .error
            }
        } else {
            failed.phase = .error
        }
        return failed
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

}

struct ReaderOriginalSheet: View {
    @Environment(\.dismiss) private var dismiss
    var url: URL
    @State private var loadState: OriginalPageLoadState = .loading
    @State private var reloadRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original page").font(.headline)
                    Text(url.host ?? url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Button("Open in Browser", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            PublicOriginalWebView(url: url, reloadRequest: reloadRequest, onEscape: { dismiss() }, onLoadStateChange: { loadState = $0 })
                .overlay {
                    if loadState == .failed {
                        VStack(spacing: 12) {
                            Text("Couldn’t load this page").font(.headline)
                            Text("Try again, or open it in your browser.")
                                .foregroundStyle(.secondary)
                            Button("Retry", systemImage: "arrow.clockwise") {
                                loadState = .loading
                                reloadRequest += 1
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
                .overlay(alignment: .top) {
                    if loadState == .loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading page…").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(.bar)
                    }
                }
        }
        .frame(width: 760, height: 520)
    }
}

private struct ReaderInsightsPanel: View {
    var state: ReaderInsightsState
    var onClose: () -> Void
    var onRetry: () -> Void
    var onAsk: (String) -> Void
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Insights", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Label("Close Insights", systemImage: "xmark") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close Insights (Esc)")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(state.title).font(.title2.bold())
                    if state.phase == .loading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Working from article evidence…").foregroundStyle(.secondary)
                        }
                    }
                    if !state.body.isEmpty {
                        Text(state.body).textSelection(.enabled).lineSpacing(3)
                    }
                    if !state.points.isEmpty {
                        if state.kind == .keyPoints {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(state.points.enumerated()), id: \.offset) { _, point in
                                    HStack(alignment: .top, spacing: 9) {
                                        Text("•").font(.headline).foregroundStyle(CrosscurrentColor.accent)
                                        insightPoint(point)
                                    }
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(state.points.enumerated()), id: \.offset) { _, point in insightPoint(point) }
                            }
                        }
                    }
                    if state.kind == .askArticle, state.phase != .loading, state.phase != .unavailable, state.phase != .denied, state.body.isEmpty {
                        TextField("Ask about this article", text: $question, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                            .focused($questionFocused)
                            .onSubmit(submitQuestion)
                        Button("Ask", systemImage: "arrow.up.circle.fill", action: submitQuestion)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Ask (⌘↩)")
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let message = state.message {
                        Label(message, systemImage: state.phase == .denied ? "hand.raised" : state.phase == .error ? "exclamationmark.circle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(state.phase == .error ? .orange : .secondary)
                    }
                    if state.canRetry { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reader Insights")
        .task(id: state.id) {
            if state.kind == .askArticle, state.phase == .ready { questionFocused = true }
        }
    }

    private func submitQuestion() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, state.phase == .ready || state.phase == .error else { return }
        onAsk(value)
    }

    private func insightPoint(_ point: ReaderInsightPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.text).textSelection(.enabled).lineSpacing(2)
            if let citation = point.citation {
                Text(citation).font(.caption2.weight(.medium)).foregroundStyle(CrosscurrentColor.accent)
            }
        }
    }
}
