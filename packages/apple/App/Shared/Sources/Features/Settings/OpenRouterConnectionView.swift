#if os(macOS)
import BrieflyCore
import SwiftUI

struct AIProcessingSettingsView: View {
    @Bindable var settings: LibrarySettingsModel
    @State private var promptSaved = false

    var body: some View {
        OpenRouterConnectionView(settings: settings)
        OpenRouterModelSettingsView(settings: settings)

        SettingsGroup(title: "Summary instructions") {
            Text("Briefly writes a concise and a detailed summary in English. Adjust the instructions to change tone, language, or focus.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Customize instructions") {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $settings.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 230)
                        .padding(.vertical, 8)
                        .settingsField()
                        .accessibilityLabel("Summary instructions")
                    Text("Keep {{source}} and {{topics}} so Briefly can insert the source and your library topics. Changes apply to future summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Restore default") { settings.processingPrompt = defaultProcessingPrompt }
                            .buttonStyle(.borderless)
                        Spacer()
                        if promptSaved {
                            Label("Saved", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Save instructions") { promptSaved = settings.saveProcessingPrompt() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!settings.hasUnsavedProcessingPrompt)
                    }
                }
                .padding(.top, 12)
            }
        }
        .onChange(of: settings.processingPrompt) { promptSaved = false }
    }
}

struct OpenRouterConnectionView: View {
    @Bindable var settings: LibrarySettingsModel
    @State private var apiKeyDraft = ""

    var body: some View {
        SettingsGroup(title: "OpenRouter", footer: footer) {
            SettingsRow(
                icon: statusIcon,
                title: statusTitle,
                subtitle: "Summaries are created with your own OpenRouter account.",
                iconTint: settings.isProcessingConfigured ? .green : nil
            ) {
                if settings.isConnectingOpenRouter || settings.isTestingAI {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                if settings.isConnectingOpenRouter {
                    Button("Cancel") { settings.cancelOpenRouterSignIn() }
                } else if settings.isOpenRouterConnected {
                    Button("Test connection") {
                        Task { await settings.testOpenRouterConnection() }
                    }
                    .disabled(settings.isTestingAI || settings.isLoadingOpenRouterModel)
                    Button("Reconnect") { settings.connectOpenRouter() }
                        .disabled(settings.isTestingAI)
                    Spacer()
                    Button("Disconnect", role: .destructive) { settings.disconnectOpenRouter() }
                        .buttonStyle(.borderless)
                        .disabled(settings.isTestingAI)
                } else {
                    Button("Sign in with OpenRouter") { settings.connectOpenRouter() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let message = settings.openRouterConnectionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(settings.openRouterConnectionFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Use an API key instead") {
                HStack(spacing: 10) {
                    SecureField("OpenRouter API key", text: $apiKeyDraft)
                        .textFieldStyle(.plain)
                        .settingsField()
                        .onSubmit(saveKey)
                    Button("Connect", action: saveKey)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 10)
                .disabled(settings.isConnectingOpenRouter || settings.isTestingAI)
            }
            .font(.callout)
        }
        .onDisappear { apiKeyDraft = "" }
    }

    private var statusTitle: String {
        if settings.isConnectingOpenRouter { return "Waiting for sign-in…" }
        if settings.isTestingAI { return "Testing connection…" }
        if settings.isProcessingConfigured { return "Connected" }
        return settings.isOpenRouterConnected ? "Key saved. Test the connection." : "Not connected"
    }

    private var statusIcon: String {
        if settings.isProcessingConfigured { return "checkmark.circle.fill" }
        return settings.isOpenRouterConnected ? "key.fill" : "bolt.horizontal.circle"
    }

    private var footer: String {
        settings.isOpenRouterConnected
            ? "AI usage is billed to your OpenRouter account. Your connection is stored securely on this Mac."
            : "Sign-in opens your browser, where you can set a spending limit. AI usage is billed to your OpenRouter account."
    }

    private func saveKey() {
        guard !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if settings.saveOpenRouterAPIKey(apiKeyDraft) { apiKeyDraft = "" }
    }
}

struct OpenRouterModelSettingsView: View {
    @Bindable var settings: LibrarySettingsModel
    @State private var modelIDInput: String

    init(settings: LibrarySettingsModel) {
        self.settings = settings
        _modelIDInput = State(initialValue: settings.openRouterModelID)
    }

    private var changedModel: Bool {
        modelIDInput.trimmingCharacters(in: .whitespacesAndNewlines) != settings.openRouterModelID
    }

    private var busy: Bool { settings.isLoadingOpenRouterModel || settings.isTestingAI }

    var body: some View {
        SettingsGroup(title: "Model") {
            HStack(spacing: 10) {
                TextField("provider/model-id", text: $modelIDInput)
                    .textFieldStyle(.plain)
                    .settingsField()
                    .accessibilityLabel("OpenRouter model ID")
                    .onSubmit { applyModel() }
                    .disabled(busy)
                Button("Use model") { applyModel() }
                    .disabled(busy || !changedModel || modelIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Copy the model ID from OpenRouter, including its provider name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Link(destination: URL(string: "https://openrouter.ai/models")!) {
                    Label("Browse models", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                }
                .font(.caption.weight(.medium))
            }

            if let model = settings.openRouterModelSelection?.model {
                SettingsRow(
                    icon: "cpu",
                    title: changedModel ? "Currently using \(model.name)" : model.name,
                    subtitle: priceDescription(model)
                ) {
                    if settings.isLoadingOpenRouterModel {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await settings.updateOpenRouterModel(settings.openRouterModelID) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help("Refresh this model’s options")
                        .accessibilityLabel("Refresh model options")
                    }
                }
                if !model.availableEfforts.isEmpty {
                    SettingsRow(
                        icon: "brain",
                        title: "Reasoning effort",
                        subtitle: "Higher effort can take longer and cost more. Saved automatically."
                    ) {
                        Picker("Reasoning effort", selection: Binding(
                            get: { settings.openRouterReasoningEffort ?? "" },
                            set: { settings.setOpenRouterReasoningEffort($0.isEmpty ? nil : $0) }
                        )) {
                            Text(defaultEffortLabel(model)).tag("")
                            ForEach(model.availableEfforts, id: \.self) { effort in
                                Text(effortLabel(effort)).tag(effort)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(busy || changedModel)
                    }
                } else {
                    Text("This model doesn’t offer an adjustable reasoning effort.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if settings.isLoadingOpenRouterModel {
                ProgressView().controlSize(.small)
            }
            if let message = settings.openRouterModelMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(settings.openRouterModelFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await settings.updateOpenRouterModel(settings.openRouterModelID, force: false) }
        .onChange(of: settings.openRouterModelID) { modelIDInput = settings.openRouterModelID }
    }

    private func applyModel() {
        guard changedModel, !busy else { return }
        Task {
            if await settings.updateOpenRouterModel(modelIDInput) { modelIDInput = settings.openRouterModelID }
        }
    }

    private func effortLabel(_ effort: String) -> String {
        switch effort {
        case "none": "Off"
        case "xhigh": "Extra high"
        case "max": "Maximum"
        default: effort.capitalized
        }
    }

    private func defaultEffortLabel(_ model: OpenRouterModel) -> String {
        if model.reasoning?.defaultEnabled == false, model.reasoning?.mandatory != true {
            return "Model default (Off)"
        }
        guard let effort = model.reasoning?.defaultEffort else { return "Model default" }
        return "Model default (\(effortLabel(effort)))"
    }

    private func priceDescription(_ model: OpenRouterModel) -> String? {
        guard let inputPrice = model.pricing?.prompt, let inputValue = Double(inputPrice),
              let outputPrice = model.pricing?.completion, let outputValue = Double(outputPrice),
              inputValue.isFinite, outputValue.isFinite, inputValue >= 0, outputValue >= 0 else { return nil }
        let input = (inputValue * 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(0...4)))
        let output = (outputValue * 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(0...4)))
        return "\(input) input · \(output) output per 1M tokens. Rates vary by provider and source length."
    }
}
#endif
