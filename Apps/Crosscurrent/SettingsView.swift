import CrosscurrentDomain
import CrosscurrentStorage
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPromptTask: AITask = .eventSynthesis
    @State private var promptOverride = ""
    @State private var promptStatus = ""
    @State private var promptBusy = false
    @State private var providerKind = "ollama"
    @State private var providerEndpoint = "http://127.0.0.1:11434/api/chat"
    @State private var providerModel = "qwen3:4b"
    @State private var providerSecret = ""
    @State private var providerStatus = ""
    @State private var providerBusy = false
    @State private var privacyBusy = false
    @State private var weChatAPIKey = ""
    @State private var weChatVerificationCode = ""
    @State private var weChatConfigurationStatus = ""
    @State private var weChatBusy = false
    @State private var maintenanceBusy = false
    @State private var confirmsCacheClear = false
    @State private var confirmsDeleteAll = false
    @State private var confirmsRemoveWeChatIndex = false

    var body: some View {
        TabView(selection: $model.settingsTab) {
            generalSettings.tabItem { Label("General", systemImage: "gear") }.tag("General")
            aiSettings.tabItem { Label("AI & Privacy", systemImage: "lock.shield") }.tag("AI")
            promptSettings.tabItem { Label("Prompts", systemImage: "text.quote") }.tag("Prompts")
            retentionSettings.tabItem { Label("Retention", systemImage: "externaldrive") }.tag("Retention")
            dataSettings.tabItem { Label("Data & Storage", systemImage: "internaldrive") }.tag("Data")
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove WeChat Index configuration?", isPresented: $confirmsRemoveWeChatIndex) {
            Button("Remove configuration", role: .destructive) {
                updateWeChatConfiguration(remove: true)
            }
        } message: { Text("Public feeds remain available. Broader search will need an API key again.") }
    }

    private var generalSettings: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Briefings") {
                    DatePicker(
                        "Daily briefing",
                        selection: Binding(get: { model.dailyBriefing }, set: { value in Task { await model.saveDailyBriefing(value) } }),
                        displayedComponents: .hourAndMinute
                    )
                    ForEach(Array(model.additionalBriefings.indices), id: \.self) { index in
                        HStack {
                            DatePicker(
                                "Additional briefing \(index + 1)",
                                selection: Binding(
                                    get: { model.additionalBriefings[index] },
                                    set: { value in Task { await model.setAdditionalBriefing(at: index, date: value) } }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            Button(role: .destructive) { Task { await model.removeAdditionalBriefing(at: index) } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).accessibilityLabel("Remove briefing time")
                        }
                    }
                    Button("Add briefing time", systemImage: "plus") { Task { await model.addAdditionalBriefing() } }
                }
                Section("Updates") {
                    LabeledContent("Version status") {
                        HStack {
                            Text(model.updateStatus).foregroundStyle(.secondary)
                            Button("Check for Updates…") { model.checkForUpdates() }
                                .disabled(model.updateStatus == String(localized: "Release feed not configured"))
                        }
                    }
                }
                Section("Background refresh") {
                    LabeledContent("Status", value: model.backgroundState)
                    HStack {
                        Button("Enable Agent") { enableAgent() }
                            .disabled(!model.supportsBackgroundServices || model.backgroundState == String(localized: "Enabled"))
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Text(model.supportsBackgroundServices
                         ? String(localized: "Enable background refresh to receive briefings while Crosscurrent is closed.")
                         : String(localized: "This build refreshes while open. Background services require a signed build."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Browser sessions") {
                        LabeledContent("Status", value: model.browserWorkerState)
                        Text("For sources that require website sign-in. Public WeChat feeds do not use browser sessions.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Enable Browser Session Owner") { enableBrowserWorker() }
                            .disabled(!model.supportsBackgroundServices || model.browserWorkerState == String(localized: "Enabled"))
                    }
                    DisclosureGroup("Advanced WeChat Index", isExpanded: $model.settingsShowsWeChat) {
                        weChatSettings
                    }
                    .id("wechat-index")
                }
            }
            .padding(12)
            .onChange(of: model.settingsShowsWeChat) { _, expanded in
                if expanded { proxy.scrollTo("wechat-index", anchor: .top) }
            }
            .onAppear {
                if model.settingsShowsWeChat { proxy.scrollTo("wechat-index", anchor: .top) }
            }
        }
    }

    private var weChatSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Public feeds need no setup. Jizhila can expand search coverage and may charge for Search More or fallback requests.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Status", value: model.weChatIndexStatus)
            SecureField("API key", text: $weChatAPIKey)
            SecureField("Optional verification code", text: $weChatVerificationCode)
            HStack {
                Button("Save") { updateWeChatConfiguration() }
                    .disabled(weChatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Check configuration") {
                    guard !weChatBusy else { return }
                    weChatBusy = true
                    Task {
                        defer { weChatBusy = false }
                        weChatConfigurationStatus = await model.testWeChatIndexConfiguration()
                    }
                }
                if model.weChatIndexConfigured {
                    Button("Remove configuration…", role: .destructive) { confirmsRemoveWeChatIndex = true }
                }
                if weChatBusy { ProgressView().controlSize(.small) }
            }
            Text("Your key stays in Keychain. A WeChat login is never required.")
                .font(.caption).foregroundStyle(.secondary)
            if !weChatConfigurationStatus.isEmpty {
                Text(weChatConfigurationStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.top, 8)
        .disabled(weChatBusy)
    }

    private var aiSettings: some View {
        ScrollViewReader { proxy in
        Form {
            Section("AI provider") {
                Picker("Provider", selection: $providerKind) {
                    Text("Ollama").tag("ollama")
                    Text("OpenAI").tag("openai")
                    Text("OpenAI-compatible").tag("openai-compatible")
                    Text("Anthropic").tag("anthropic")
                    Text("Gemini").tag("gemini")
                    Text("OpenRouter").tag("openrouter")
                }
                .onChange(of: providerKind) { _, kind in loadProvider(kind) }
                TextField("Endpoint", text: $providerEndpoint)
                TextField("Model", text: $providerModel)
                SecureField(providerKind == "ollama" ? String(localized: "Optional bearer token") : String(localized: "API key"), text: $providerSecret)
                if model.providerEditorValues(for: providerKind) != nil {
                    Text("Leave the key blank to keep the saved key.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save provider") { runProviderAction(save: true) }
                    Button("Test connection") { runProviderAction(save: false) }
                    if providerBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    if let saved = model.providerEditorValues(for: providerKind),
                       saved.endpoint == providerEndpoint, saved.model == providerModel,
                       let configuration = model.providerConfigurations.first(where: { $0.kind == providerKind }) {
                        Text(NSLocalizedString(configuration.health.capitalized, comment: "AI provider connection status"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(providerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || providerModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !providerStatus.isEmpty {
                    Text(providerStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .disabled(providerBusy)
            .id("provider-editor")
            Section("Privacy") {
                Toggle("Allow cloud AI for public content", isOn: Binding(get: { model.publicCloudConsent }, set: { value in
                    privacyBusy = true
                    Task {
                        defer { privacyBusy = false }
                        await model.setPublicCloudConsent(value)
                    }
                }))
                .disabled(privacyBusy || providerBusy)
                Text("Private, restricted, and unclassified content requires separate, explicit permission before it can be sent to a cloud provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.providerConfigurations.isEmpty {
                Section("Saved providers") {
                    ForEach(model.providerConfigurations) { configuration in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(configuration.displayName)
                                if let checked = configuration.lastCheckedAt {
                                    Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = configuration.lastError {
                                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                                }
                            }
                            Spacer()
                            Button("Edit") {
                                providerKind = configuration.kind
                                loadProvider(configuration.kind)
                                proxy.scrollTo("provider-editor", anchor: .top)
                            }
                            .disabled(providerBusy)
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("Task routing") {
                    Picker("Fast route", selection: Binding(get: { model.fastProviderID }, set: { value in Task { await model.setProviderRoute(.fast, providerID: value) } })) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.providerConfigurations.filter(\.enabled)) { configuration in
                            Text(configuration.displayName).tag(Optional(configuration.id))
                        }
                    }
                    Picker("Reasoning route", selection: Binding(get: { model.reasoningProviderID }, set: { value in Task { await model.setProviderRoute(.reasoning, providerID: value) } })) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.providerConfigurations.filter(\.enabled)) { configuration in
                            Text(configuration.displayName).tag(Optional(configuration.id))
                        }
                    }
                }
                DisclosureGroup("Local semantic search") {
                    Text(model.embeddingStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Semantic search uses a verified local model. Keyword search is always available.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Model", value: "multilingual-e5-small / ORT CPU")
                }
            }
        }
        .padding(12)
        .task { loadProvider(providerKind) }
        }
    }

    private var promptSettings: some View {
        Form {
            Section {
                Picker("Task", selection: $selectedPromptTask) {
                    ForEach(AITask.allCases, id: \.self) { task in Text(task.displayName).tag(task) }
                }.disabled(promptBusy)
                TextEditor(text: $promptOverride)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .accessibilityLabel("Prompt instructions")
                    .disabled(promptBusy)
                HStack {
                    Button("Save override") { updatePrompt(restore: false) }
                        .disabled(promptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Restore bundled default") { updatePrompt(restore: true) }
                    if promptBusy { ProgressView().controlSize(.small) }
                }.disabled(promptBusy)
                if !promptStatus.isEmpty { Text(promptStatus).font(.caption).foregroundStyle(.secondary) }
                Text("Changes apply to future AI requests. Previous results keep the instructions they used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .task(id: selectedPromptTask) {
            let body = await model.promptBody(task: selectedPromptTask) ?? ""
            guard !Task.isCancelled else { return }
            promptOverride = body
            promptStatus = ""
        }
    }

    private var retentionSettings: some View {
        Form {
            Section("Keep original downloads") {
                Picker("Public content", selection: retentionBinding(\.publicDays)) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Private content", selection: retentionBinding(\.privateDays)) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Unreadable content", selection: retentionBinding(\.failedExtractionDays)) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
            }
            Text("These limits apply to original downloaded files. Saved article text and reading history remain, except when a source or legal requirement mandates removal.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }

    private var dataSettings: some View {
        Form {
            if let usage = model.localDataUsage {
                Section {
                    LabeledContent("Total local data", value: format(usage.totalBytes))
                    LabeledContent("Articles & Media", value: format(usage.articlesAndMediaBytes))
                    LabeledContent("Search Index", value: format(usage.searchIndexBytes))
                    LabeledContent("Local AI Model", value: format(usage.localModelBytes))
                    LabeledContent("Backups", value: format(usage.backupsBytes))
                }
                Section("Maintenance") {
                    HStack {
                        Button("Back Up Now", systemImage: "externaldrive.badge.plus") { runMaintenance { await model.backUpNow() } }
                        Button("Rebuild Search Index", systemImage: "magnifyingglass") { runMaintenance { await model.rebuildSearchIndex() } }
                        if maintenanceBusy { ProgressView().controlSize(.small) }
                    }
                    Button("Clear Rebuildable Cache…", systemImage: "arrow.triangle.2.circlepath") { confirmsCacheClear = true }
                    if !model.dataStorageStatus.isEmpty {
                        Text(model.dataStorageStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.disabled(maintenanceBusy)
                Section("Storage location") {
                    Text(usage.location.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Open Data Folder", systemImage: "folder") { model.openDataFolder() }
                    if usage.isDevelopment {
                        Text("Unsigned builds keep their data separately from signed release builds.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Delete All Local Data…", systemImage: "trash", role: .destructive) { confirmsDeleteAll = true }
                        .disabled(maintenanceBusy)
                }
            } else {
                ProgressView("Reading local data usage…")
            }
        }
        .padding(12)
        .task { model.refreshLocalDataUsage() }
        .confirmationDialog("Clear rebuildable cache?", isPresented: $confirmsCacheClear) {
            Button("Clear Cache", role: .destructive) { runMaintenance { await model.clearRebuildableCache() } }
        } message: {
            Text("Articles and reading history remain. Search and local intelligence indexes will be rebuilt.")
        }
        .confirmationDialog("Delete all local Crosscurrent data?", isPresented: $confirmsDeleteAll) {
            Button("Delete All Local Data", role: .destructive) { model.deleteAllLocalData() }
        } message: {
            Text("Crosscurrent will quit and remove this data root on the next launch. This cannot be undone unless you have a backup.")
        }
    }

    private func loadProvider(_ kind: String) {
        providerSecret = ""
        providerStatus = ""
        if let saved = model.providerEditorValues(for: kind) {
            providerEndpoint = saved.endpoint
            providerModel = saved.model
            return
        }
        switch kind {
        case "openai": providerEndpoint = "https://api.openai.com/v1/responses"; providerModel = "gpt-5-mini"
        case "openai-compatible": providerEndpoint = "https://example.invalid/v1/chat/completions"; providerModel = "model-id"
        case "anthropic": providerEndpoint = "https://api.anthropic.com/v1/messages"; providerModel = "claude-sonnet-4-5"
        case "gemini": providerEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"; providerModel = "gemini-2.5-flash"
        case "openrouter": providerEndpoint = "https://openrouter.ai/api/v1/chat/completions"; providerModel = "openai/gpt-5-mini"
        default: providerEndpoint = "http://127.0.0.1:11434/api/chat"; providerModel = "qwen3:4b"
        }
    }

    private func runProviderAction(save: Bool) {
        guard !providerBusy else { return }
        providerBusy = true
        providerStatus = ""
        Task {
            defer { providerBusy = false }
            if save {
                let result = await model.saveProvider(kind: providerKind, endpoint: providerEndpoint, model: providerModel, secret: providerSecret)
                providerStatus = result.message
                if result.succeeded { providerSecret = "" }
            } else {
                providerStatus = await model.testProvider(kind: providerKind, endpoint: providerEndpoint, model: providerModel, secret: providerSecret)
            }
        }
    }

    private func updateWeChatConfiguration(remove: Bool = false) {
        guard !weChatBusy else { return }
        weChatBusy = true
        Task {
            defer { weChatBusy = false }
            let result = await model.saveWeChatIndex(apiKey: remove ? "" : weChatAPIKey, verificationCode: remove ? "" : weChatVerificationCode)
            weChatConfigurationStatus = result.message
            if result.succeeded {
                weChatAPIKey = ""
                weChatVerificationCode = ""
            }
        }
    }

    private func updatePrompt(restore: Bool) {
        guard !promptBusy else { return }
        promptBusy = true
        Task {
            defer { promptBusy = false }
            if restore {
                promptStatus = await model.restoreBundledPrompt(task: selectedPromptTask)
                promptOverride = await model.promptBody(task: selectedPromptTask) ?? ""
            } else {
                promptStatus = await model.savePromptOverride(task: selectedPromptTask, body: promptOverride)
            }
        }
    }

    private func runMaintenance(_ operation: @escaping @MainActor () async -> Void) {
        guard !maintenanceBusy else { return }
        maintenanceBusy = true
        Task {
            defer { maintenanceBusy = false }
            await operation()
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func retentionBinding(_ keyPath: WritableKeyPath<RawRetentionPolicy, Int>) -> Binding<Int> {
        Binding(
            get: { model.rawRetentionPolicy[keyPath: keyPath] },
            set: { value in
                var policy = model.rawRetentionPolicy
                policy[keyPath: keyPath] = value
                Task { await model.saveRawRetentionPolicy(policy) }
            }
        )
    }

    private func enableAgent() {
        guard model.supportsBackgroundServices else { return }
        do {
            try CrosscurrentServices.agent.register()
            model.backgroundState = String(localized: "Enabled")
            Task {
                do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                catch { model.backgroundState = error.localizedDescription }
            }
        }
        catch { model.backgroundState = error.localizedDescription }
    }

    private func enableBrowserWorker() {
        guard model.supportsBackgroundServices else { return }
        do {
            try CrosscurrentServices.browser.register()
            model.browserWorkerState = String(localized: "Enabled")
        } catch {
            model.browserWorkerState = error.localizedDescription
        }
    }
}

private extension AITask {
    var displayName: String {
        switch self {
        case .eventTitle: String(localized: "Event title")
        case .eventSynthesis: String(localized: "Event synthesis")
        case .ambiguousClustering: String(localized: "Ambiguous clustering")
        case .articleSummary: String(localized: "Article summary")
        case .keyPoints: String(localized: "Key points")
        case .translation: String(localized: "Translation")
        case .explainSelection: String(localized: "Explain selection")
        case .summarizeSelection: String(localized: "Summarize selection")
        case .askSelection: String(localized: "Ask selection")
        case .askArticle: String(localized: "Ask article")
        case .digestSynthesis: String(localized: "Digest synthesis")
        case .chinaGlobalComparison: String(localized: "China ↔ Global")
        }
    }
}
