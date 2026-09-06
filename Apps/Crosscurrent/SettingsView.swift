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
    @State private var providerKind = "ollama"
    @State private var providerEndpoint = "http://127.0.0.1:11434/api/chat"
    @State private var providerModel = "qwen3:4b"
    @State private var providerSecret = ""
    @State private var providerStatus = ""
    @State private var weChatAPIKey = ""
    @State private var weChatVerificationCode = ""
    @State private var weChatConfigurationStatus = ""
    @State private var confirmsCacheClear = false
    @State private var confirmsDeleteAll = false
    @State private var confirmsRemoveWeChatIndex = false
    @State private var providerBusy = false

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Form {
                DatePicker(
                    "Daily briefing",
                    selection: Binding(get: { model.dailyBriefing }, set: { value in Task { await model.saveDailyBriefing(value) } }),
                    displayedComponents: .hourAndMinute
                )
                Text("One initial snapshot per day. Additional briefing times are optional.").font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Background Agent", value: model.backgroundState)
                if model.backgroundState == String(localized: "Foreground refresh only") {
                    Text("Crosscurrent remains fully usable and refreshes while open. Closed-app refresh and notifications require a signed, enabled Background Agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack { Button("Enable Agent") { enableAgent() }; Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
                LabeledContent("Authenticated Browser Sessions", value: model.browserWorkerState)
                Button("Enable Browser Session Owner") { enableBrowserWorker() }
                Section("Advanced WeChat Index") {
                    Text("Public WeChat feeds work without configuration. An optional index provider expands account coverage beyond the built-in public catalogs.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Direct provider", value: "Jizhila · BYOK")
                    LabeledContent("Status", value: model.weChatIndexStatus)
                    SecureField("API key", text: $weChatAPIKey)
                    SecureField("Optional verification code", text: $weChatVerificationCode)
                    HStack {
                        Button("Check configuration") {
                            Task { weChatConfigurationStatus = await model.testWeChatIndexConfiguration() }
                        }
                        Button("Save") {
                            Task {
                                weChatConfigurationStatus = await model.saveWeChatIndex(apiKey: weChatAPIKey, verificationCode: weChatVerificationCode)
                                weChatAPIKey = ""
                                weChatVerificationCode = ""
                            }
                        }
                        .disabled(weChatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.weChatIndexConfigured {
                            Button("Remove configuration…", role: .destructive) { confirmsRemoveWeChatIndex = true }
                        }
                    }
                    Text("The key stays in Keychain. Search More and fallback requests may use paid provider calls. Crosscurrent uses public feeds first and never requires a WeChat login.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !weChatConfigurationStatus.isEmpty {
                        Text(weChatConfigurationStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Updates", value: model.updateStatus)
                Button("Check for Updates…") { model.checkForUpdates() }
                if let startupError = model.startupError { Text(startupError).foregroundStyle(.red).font(.caption) }
            }.padding().tabItem { Label("General", systemImage: "gear") }.tag("General")
            Form {
                Toggle("Allow configured cloud providers for public content", isOn: Binding(get: { model.publicCloudConsent }, set: { value in Task { await model.setPublicCloudConsent(value) } }))
                GroupBox("Privacy boundary") { Text("Authenticated and public are independent. Private, restricted, and unknown content stays local unless an explicit compatible policy permits otherwise.").frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                LabeledContent("Reasoning provider", value: model.providerConfigured ? String(localized: "Configured") : String(localized: "Not configured"))
                LabeledContent("Embedding route", value: String(localized: "Development-selected · multilingual-e5-small / ORT CPU"))
                Text(model.embeddingStatus).font(.caption).foregroundStyle(.secondary)
                Text("Semantic indexing activates only after the pinned model/runtime artifact manifest, checksums, license, and local runtime layout validate. Lexical search remains available without it.")
                    .font(.caption).foregroundStyle(.secondary)
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
                ForEach(model.providerConfigurations) { configuration in
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent(configuration.displayName, value: NSLocalizedString(configuration.health.capitalized, comment: "AI provider connection status"))
                        if let checked = configuration.lastCheckedAt {
                            Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = configuration.lastError {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
                Picker("Provider", selection: $providerKind) {
                    Text("Ollama").tag("ollama")
                    Text("OpenAI Responses").tag("openai")
                    Text("OpenAI-compatible Chat Completions").tag("openai-compatible")
                    Text("Anthropic Messages").tag("anthropic")
                    Text("Gemini generateContent").tag("gemini")
                    Text("OpenRouter").tag("openrouter")
                }
                    .onChange(of: providerKind) { _, value in
                        switch value {
                        case "openai": providerEndpoint = "https://api.openai.com/v1/responses"; providerModel = "gpt-5-mini"
                        case "openai-compatible": providerEndpoint = "https://example.invalid/v1/chat/completions"; providerModel = "model-id"
                        case "anthropic": providerEndpoint = "https://api.anthropic.com/v1/messages"; providerModel = "claude-sonnet-4-5"
                        case "gemini": providerEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"; providerModel = "gemini-2.5-flash"
                        case "openrouter": providerEndpoint = "https://openrouter.ai/api/v1/chat/completions"; providerModel = "openai/gpt-5-mini"
                        default: providerEndpoint = "http://127.0.0.1:11434/api/chat"; providerModel = "qwen3:4b"
                        }
                    }
                TextField("Endpoint", text: $providerEndpoint)
                TextField("Model", text: $providerModel)
                SecureField(providerKind == "ollama" ? "Optional bearer token" : "API key", text: $providerSecret)
                HStack {
                    Button("Test connection") {
                        Task {
                            providerBusy = true
                            defer { providerBusy = false }
                            providerStatus = await model.testProvider(kind: providerKind, endpoint: providerEndpoint, model: providerModel, secret: providerSecret)
                        }
                    }
                    Button("Save provider") {
                        Task { providerStatus = await model.saveProvider(kind: providerKind, endpoint: providerEndpoint, model: providerModel, secret: providerSecret); providerSecret = "" }
                    }
                    if providerBusy { ProgressView().controlSize(.small) }
                }.disabled(providerBusy)
                if !providerStatus.isEmpty { Text(providerStatus).font(.caption).foregroundStyle(.secondary) }
            }.padding().tabItem { Label("AI & Privacy", systemImage: "lock.shield") }.tag("AI")
            Form {
                Picker("Task", selection: $selectedPromptTask) {
                    ForEach(AITask.allCases, id: \.self) { task in Text(task.displayName).tag(task) }
                }
                TextEditor(text: $promptOverride).font(.system(.body, design: .monospaced)).frame(minHeight: 250)
                HStack {
                    Button("Save override") {
                        Task { promptStatus = await model.savePromptOverride(task: selectedPromptTask, body: promptOverride) }
                    }.disabled(promptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Restore bundled default") {
                        Task {
                            promptStatus = await model.restoreBundledPrompt(task: selectedPromptTask)
                            promptOverride = await model.promptBody(task: selectedPromptTask) ?? ""
                        }
                    }
                }
                if !promptStatus.isEmpty { Text(promptStatus).font(.caption).foregroundStyle(.secondary) }
                Text("Every edit creates an immutable PromptRevision used by cache keys and provenance.").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .task(id: selectedPromptTask) {
                promptOverride = await model.promptBody(task: selectedPromptTask) ?? ""
                promptStatus = ""
            }
            .tabItem { Label("Prompts", systemImage: "text.quote") }.tag("Prompts")
            Form {
                Picker("Public raw fetches", selection: retentionBinding(\.publicDays)) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Private raw fetches", selection: retentionBinding(\.privateDays)) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Failed extraction payloads", selection: retentionBinding(\.failedExtractionDays)) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
                Text("Normalized revisions and evidence spans remain durable. Remote deletion retains permitted evidence; legal and connector-mandated purges remove content immediately and leave only permitted tombstones.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Label("Retention", systemImage: "externaldrive") }.tag("Retention")
            Form {
                if let usage = model.localDataUsage {
                    Section {
                        LabeledContent("Total local data", value: format(usage.totalBytes))
                        LabeledContent("Articles & Media", value: format(usage.articlesAndMediaBytes))
                        LabeledContent("Search Index", value: format(usage.searchIndexBytes))
                        LabeledContent("Local AI Model", value: format(usage.localModelBytes))
                        LabeledContent("Backups", value: format(usage.backupsBytes))
                    }
                    Section("Storage location") {
                        if usage.isDevelopment {
                            Label("Development Data", systemImage: "hammer")
                                .font(.subheadline.weight(.semibold))
                            Text("Unsigned builds keep their data separately from signed release builds.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(usage.location.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Open Data Folder", systemImage: "folder") { model.openDataFolder() }
                    }
                    Section("Maintenance") {
                        Button("Back Up Now", systemImage: "externaldrive.badge.plus") { Task { await model.backUpNow() } }
                        Button("Rebuild Search Index", systemImage: "magnifyingglass") { Task { await model.rebuildSearchIndex() } }
                        Button("Clear Rebuildable Cache…", systemImage: "arrow.triangle.2.circlepath") { confirmsCacheClear = true }
                        Button("Delete All Local Data…", systemImage: "trash", role: .destructive) { confirmsDeleteAll = true }
                        if !model.dataStorageStatus.isEmpty {
                            Text(model.dataStorageStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView("Reading local data usage…")
                }
            }
            .padding()
            .task { model.refreshLocalDataUsage() }
            .confirmationDialog("Clear rebuildable cache?", isPresented: $confirmsCacheClear) {
                Button("Clear Cache", role: .destructive) { Task { await model.clearRebuildableCache() } }
            } message: {
                Text("Articles and reading history remain. Search and local intelligence indexes will be rebuilt.")
            }
            .confirmationDialog("Delete all local Crosscurrent data?", isPresented: $confirmsDeleteAll) {
                Button("Delete All Local Data", role: .destructive) { model.deleteAllLocalData() }
            } message: {
                Text("Crosscurrent will quit and remove this data root on the next launch. This cannot be undone unless you have a backup.")
            }
            .tabItem { Label("Data & Storage", systemImage: "internaldrive") }.tag("Data")
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove WeChat Index configuration?", isPresented: $confirmsRemoveWeChatIndex) {
            Button("Remove configuration", role: .destructive) {
                Task { weChatConfigurationStatus = await model.saveWeChatIndex(apiKey: "", verificationCode: "") }
            }
        } message: { Text("Public feeds remain available. Broader search will need an API key again.") }
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
        do {
            try CrosscurrentServices.agent.register()
            model.backgroundState = String(localized: "Enabled")
            Task {
                do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                catch { model.startupError = error.localizedDescription }
            }
        }
        catch { model.backgroundState = error.localizedDescription }
    }

    private func enableBrowserWorker() {
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
