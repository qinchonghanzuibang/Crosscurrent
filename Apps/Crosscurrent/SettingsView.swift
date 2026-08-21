import CrosscurrentDomain
import CrosscurrentStorage
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = "General"
    @State private var selectedPromptTask: AITask = .eventSynthesis
    @State private var promptOverride = ""
    @State private var promptStatus = ""
    @State private var providerKind = "ollama"
    @State private var providerEndpoint = "http://127.0.0.1:11434/api/chat"
    @State private var providerModel = "qwen3:4b"
    @State private var providerSecret = ""
    @State private var providerStatus = ""

    var body: some View {
        TabView(selection: $tab) {
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
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Add briefing time", systemImage: "plus") { Task { await model.addAdditionalBriefing() } }
                LabeledContent("Background Agent", value: model.backgroundState)
                HStack { Button("Enable Agent") { enableAgent() }; Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
                LabeledContent("Authenticated Browser Sessions", value: model.browserWorkerState)
                Button("Enable Browser Session Owner") { enableBrowserWorker() }
                LabeledContent("Updates", value: model.updateStatus)
                Button("Check for Updates…") { model.checkForUpdates() }
                if let startupError = model.startupError { Text(startupError).foregroundStyle(.red).font(.caption) }
            }.padding().tabItem { Label("General", systemImage: "gear") }.tag("General")
            Form {
                Toggle("Allow configured cloud providers for public content", isOn: Binding(get: { model.publicCloudConsent }, set: { value in Task { await model.setPublicCloudConsent(value) } }))
                GroupBox("Privacy boundary") { Text("Authenticated and public are independent. Private, restricted, and unknown content stays local unless an explicit compatible policy permits otherwise.").frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                LabeledContent("Reasoning provider", value: model.providerConfigured ? "Configured" : "Not configured")
                Picker("Provider", selection: $providerKind) { Text("Ollama / local-compatible").tag("ollama"); Text("OpenAI Responses API").tag("openai") }
                    .onChange(of: providerKind) { _, value in
                        if value == "openai" { providerEndpoint = "https://api.openai.com/v1/responses"; providerModel = "gpt-5-mini" }
                        else { providerEndpoint = "http://127.0.0.1:11434/api/chat"; providerModel = "qwen3:4b" }
                    }
                TextField("Endpoint", text: $providerEndpoint)
                TextField("Model", text: $providerModel)
                SecureField(providerKind == "openai" ? "API key" : "Optional bearer token", text: $providerSecret)
                Button("Save provider") {
                    Task { providerStatus = await model.saveProvider(kind: providerKind, endpoint: providerEndpoint, model: providerModel, secret: providerSecret); providerSecret = "" }
                }
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
        }
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
        do { try CrosscurrentServices.agent.register(); model.backgroundState = String(localized: "Enabled") }
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
