import SwiftUI

/// Settings › AI: which provider answers in the Find panel, as tiles that
/// say whether it's on this Mac, and that provider's model (and Ollama's
/// server).
struct AISettingsView: View {
    @StateObject private var settingsManager = TOMLSettingsManager.shared

    /// The command line tools found, by provider; nil until looked for.
    @State private var located: [AIProvider: URL]?
    /// The provider used while none is chosen.
    @State private var automaticProvider: AIProvider?

    @State private var installedModels: [OllamaService.InstalledModel] = []
    @State private var isLoadingModels = false
    @State private var loadError: String?
    /// Nil until Ollama's server has been asked for its models.
    @State private var hasReachedOllama: Bool?

    private let ollamaService = OllamaService()

    private var provider: AIProvider? {
        settingsManager.aiProvider ?? automaticProvider
    }

    var body: some View {
        SettingsDetailContainer {
            Section {
                AIProviderPicker(
                    selection: provider,
                    status: status(of:),
                    onSelect: { settingsManager.aiProvider = $0 }
                )
            } header: {
                Text("Provider")
            } footer: {
                if let provider {
                    Text(footer(for: provider))
                }
            }

            switch provider {
            case .claude:
                commandLineSection(.claude) {
                    Picker(selection: $settingsManager.claudeModel) {
                        Text("Default").tag("")
                        Text("Fable").tag("fable")
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                        if !["", "fable", "opus", "sonnet", "haiku"].contains(settingsManager.claudeModel) {
                            Text(settingsManager.claudeModel).tag(settingsManager.claudeModel)
                        }
                    } label: {
                        Text("Model")
                        Text("Default is the one Claude Code uses. Haiku answers fastest")
                    }
                }
            case .codex:
                commandLineSection(.codex) {
                    TextField(text: $settingsManager.codexModel, prompt: Text("Default")) {
                        Text("Model")
                        Text("A model name, or empty for the one Codex uses")
                    }
                }
            case .ollama:
                ollamaSection
            case nil:
                EmptyView()
            }
        }
        .task { await locate() }
    }

    // MARK: - Status

    enum ProviderStatus {
        case unknown
        case installed
        case notInstalled
    }

    private func status(of provider: AIProvider) -> ProviderStatus {
        if provider == .ollama {
            guard let hasReachedOllama else { return .unknown }
            return hasReachedOllama ? .installed : .notInstalled
        }
        guard let located else { return .unknown }
        return located[provider] == nil ? .notInstalled : .installed
    }

    private func locate() async {
        var found: [AIProvider: URL] = [:]
        for provider in AIProvider.allCases {
            if let command = provider.command, let url = await AICommandLine.locate(command) {
                found[provider] = url
            }
        }
        located = found
        automaticProvider = await AIProvider.resolved()
        await refreshModels()
    }

    private func footer(for provider: AIProvider) -> String {
        switch provider {
        case .claude:
            return "Answers with your Claude subscription, through Claude Code. Your question and the page’s text go to Anthropic"
        case .codex:
            return "Answers with your ChatGPT subscription, through Codex. Your question and the page’s text go to OpenAI"
        case .ollama:
            return "Answers on this Mac with a model you’ve downloaded. Nothing leaves your Mac"
        }
    }

    // MARK: - Command line tools

    private func commandLineSection<Model: View>(_ provider: AIProvider, @ViewBuilder model: () -> Model) -> some View {
        Section(provider.title) {
            if let url = located?[provider] {
                model()
                LabeledContent("Command") {
                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if located != nil {
                notInstalledRow(provider)
            }
        }
    }

    private func notInstalledRow(_ provider: AIProvider) -> some View {
        SettingsRow(
            title: "\(provider.title) isn’t installed",
            subtitle: "Install it, sign in once with “\(provider.command ?? "")” in Terminal, then check again"
        ) {
            HStack {
                Button("Check Again") { Task { await locate() } }
                Link("Get \(provider.title)…", destination: provider.downloadURL)
            }
        }
    }

    // MARK: - Ollama

    private var ollamaSection: some View {
        Section("Ollama") {
            TextField(text: $settingsManager.aiBaseURL, prompt: Text("http://localhost:11434")) {
                Text("Server URL")
                Text("Address of your local Ollama instance")
            }
            .onSubmit { Task { await refreshModels() } }

            LabeledContent {
                HStack(spacing: 6) {
                    Picker("Model", selection: $settingsManager.aiModel) {
                        if !settingsManager.aiModel.isEmpty
                            && !installedModels.contains(where: { $0.name == settingsManager.aiModel }) {
                            Text(settingsManager.aiModel).tag(settingsManager.aiModel)
                        }
                        ForEach(installedModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(installedModels.isEmpty && settingsManager.aiModel.isEmpty)

                    Button {
                        Task { await refreshModels() }
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Refresh installed models")
                    .disabled(isLoadingModels)
                }
            } label: {
                Text("Model")
                Text("One of the models you’ve downloaded with Ollama")
            }

            if let loadError = loadError {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't reach Ollama")
                        Group {
                            Text(loadError)
                            Text("Make sure Ollama is running and reachable at \(settingsManager.aiBaseURL)")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @MainActor
    private func refreshModels() async {
        isLoadingModels = true
        loadError = nil
        defer { isLoadingModels = false }

        do {
            installedModels = try await ollamaService.fetchInstalledModels()
            hasReachedOllama = true
        } catch let error as OllamaService.OllamaError {
            hasReachedOllama = false
            loadError = error.errorDescription ?? "Unknown error"
        } catch {
            hasReachedOllama = false
            loadError = error.localizedDescription
        }
    }
}

/// The providers side by side, each a tile with its mark, name and whether
/// it's on this Mac.
private struct AIProviderPicker: View {
    let selection: AIProvider?
    let status: (AIProvider) -> AISettingsView.ProviderStatus
    let onSelect: (AIProvider) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AIProvider.allCases) { provider in
                let isSelected = provider == selection
                Button {
                    onSelect(provider)
                } label: {
                    VStack(spacing: 8) {
                        Image(provider.iconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 26, height: 26)
                            .foregroundStyle(.primary)
                        VStack(spacing: 2) {
                            Text(provider.title)
                                .font(.callout)
                                .fontWeight(isSelected ? .semibold : .regular)
                            statusLabel(status(provider), provider: provider)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(isSelected ? 0.08 : 0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(provider.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusLabel(_ status: AISettingsView.ProviderStatus, provider: AIProvider) -> some View {
        switch status {
        case .unknown:
            Text("Looking…")
        case .installed:
            Label(provider == .ollama ? "Running" : "Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(StatusLabelStyle(tint: .green))
        case .notInstalled:
            Text(provider == .ollama ? "Not running" : "Not installed")
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

#Preview {
    AISettingsView()
        .frame(width: 570, height: 600)
}
