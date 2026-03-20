import SwiftUI

/// Settings window for ContextD configuration.
struct SettingsView: View {

    // MARK: - Defaults

    /// Single source of truth for all default values. Used by both declarations and reset functions.
    enum Defaults {
        static let summarizationModel = "anthropic/claude-haiku-4-5"
        static let enrichmentPass1Model = "anthropic/claude-haiku-4-5"
        static let enrichmentPass2Model = "anthropic/claude-sonnet-4-6"
        static let captureInterval: Double = 2.0
        static let maxKeyframeInterval: Double = 60
        static let keyframeChangeThreshold: Double = 0.50
        static let chunkDuration: Double = 300
        static let pollInterval: Double = 60
        static let minAge: Double = 300
        static let apiServerEnabled = true
        static let apiServerPort = 21890
        static let retentionDays = 7
        static let summarizationMaxTokens = 1024
        static let enrichmentPass1MaxTokens = 1024
        static let enrichmentPass2MaxTokens = 2048
        static let maxSummariesForPass1 = 30
        static let maxCapturesForPass2 = 50
        static let maxSamplesPerChunk = 10
        static let enrichmentMaxKeyframes = 10
        static let enrichmentMaxDeltasPerKeyframe = 5
        static let enrichmentMaxKeyframeTextLength = 3000
        static let enrichmentMaxDeltaTextLength = 500
        static let summarizationMaxDeltasPerKeyframe = 3
        static let summarizationMaxKeyframeTextLength = 2000
        static let summarizationMaxDeltaTextLength = 300
    }

    // API Settings
    @State private var apiKey: String = ""
    @State private var hasApiKey: Bool = false
    @AppStorage("summarizationModel") private var summarizationModel: String = Defaults.summarizationModel
    @AppStorage("enrichmentPass1Model") private var enrichmentPass1Model: String = Defaults.enrichmentPass1Model
    @AppStorage("enrichmentPass2Model") private var enrichmentPass2Model: String = Defaults.enrichmentPass2Model

    // Capture Settings
    @AppStorage("captureInterval") private var captureInterval: Double = Defaults.captureInterval
    @AppStorage("maxKeyframeInterval") private var maxKeyframeInterval: Double = Defaults.maxKeyframeInterval
    @AppStorage("keyframeChangeThreshold") private var keyframeChangeThreshold: Double = Defaults.keyframeChangeThreshold

    // Summarization Settings
    @AppStorage("summarizationChunkDuration") private var chunkDuration: Double = Defaults.chunkDuration
    @AppStorage("summarizationPollInterval") private var pollInterval: Double = Defaults.pollInterval
    @AppStorage("summarizationMinAge") private var minAge: Double = Defaults.minAge

    // API Server Settings
    @AppStorage("apiServerEnabled") private var apiServerEnabled: Bool = Defaults.apiServerEnabled
    @AppStorage("apiServerPort") private var apiServerPort: Int = Defaults.apiServerPort

    // Storage Settings
    @AppStorage("retentionDays") private var retentionDays: Int = Defaults.retentionDays

    // LLM Token Limits
    @AppStorage("summarizationMaxTokens") private var summarizationMaxTokens: Int = Defaults.summarizationMaxTokens
    @AppStorage("enrichmentPass1MaxTokens") private var enrichmentPass1MaxTokens: Int = Defaults.enrichmentPass1MaxTokens
    @AppStorage("enrichmentPass2MaxTokens") private var enrichmentPass2MaxTokens: Int = Defaults.enrichmentPass2MaxTokens

    // Context Size Limits
    @AppStorage("maxSummariesForPass1") private var maxSummariesForPass1: Int = Defaults.maxSummariesForPass1
    @AppStorage("maxCapturesForPass2") private var maxCapturesForPass2: Int = Defaults.maxCapturesForPass2
    @AppStorage("maxSamplesPerChunk") private var maxSamplesPerChunk: Int = Defaults.maxSamplesPerChunk

    // Capture Formatting Limits (Enrichment)
    @AppStorage("enrichmentMaxKeyframes") private var enrichmentMaxKeyframes: Int = Defaults.enrichmentMaxKeyframes
    @AppStorage("enrichmentMaxDeltasPerKeyframe") private var enrichmentMaxDeltasPerKeyframe: Int = Defaults.enrichmentMaxDeltasPerKeyframe
    @AppStorage("enrichmentMaxKeyframeTextLength") private var enrichmentMaxKeyframeTextLength: Int = Defaults.enrichmentMaxKeyframeTextLength
    @AppStorage("enrichmentMaxDeltaTextLength") private var enrichmentMaxDeltaTextLength: Int = Defaults.enrichmentMaxDeltaTextLength

    // Capture Formatting Limits (Summarization)
    @AppStorage("summarizationMaxDeltasPerKeyframe") private var summarizationMaxDeltasPerKeyframe: Int = Defaults.summarizationMaxDeltasPerKeyframe
    @AppStorage("summarizationMaxKeyframeTextLength") private var summarizationMaxKeyframeTextLength: Int = Defaults.summarizationMaxKeyframeTextLength
    @AppStorage("summarizationMaxDeltaTextLength") private var summarizationMaxDeltaTextLength: Int = Defaults.summarizationMaxDeltaTextLength

    // Prompt Templates
    @AppStorage(PromptTemplates.SettingsKey.summarizationSystem.rawValue)
    private var customSummarizationSystem: String = ""
    @AppStorage(PromptTemplates.SettingsKey.summarizationUser.rawValue)
    private var customSummarizationUser: String = ""
    @AppStorage(PromptTemplates.SettingsKey.enrichmentPass1System.rawValue)
    private var customPass1System: String = ""
    @AppStorage(PromptTemplates.SettingsKey.enrichmentPass2System.rawValue)
    private var customPass2System: String = ""

    @State private var showApiKeySaved: Bool = false
    @State private var saveError: String?
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case privacy = "Privacy"
        case models = "Models"
        case limits = "Limits"
        case prompts = "Prompts"
        case storage = "Storage"

        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            SettingsPrivacyTab()
                .tabItem { Label("Privacy", systemImage: "eye.slash") }
                .tag(SettingsTab.privacy)

            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)

            limitsTab
                .tabItem { Label("Limits", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.limits)

            promptsTab
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
                .tag(SettingsTab.prompts)

            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
        }
        .padding(20)
        .frame(width: 580, height: 500)
        .onAppear {
            hasApiKey = OpenRouterClient.hasAPIKey()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("API Key") {
                HStack {
                    SecureField("OpenRouter API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button(action: saveApiKey) {
                        Text(showApiKeySaved ? "Saved!" : "Save")
                    }
                    .disabled(apiKey.isEmpty)
                }

                if let error = saveError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if hasApiKey {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("API key is configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Capture") {
                HStack {
                    Text("Capture interval:")
                    Slider(value: $captureInterval, in: 1...10, step: 0.5)
                    Text("\(String(format: "%.1f", captureInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Keyframe interval:")
                    Slider(value: $maxKeyframeInterval, in: 30...300, step: 10)
                    Text("\(Int(maxKeyframeInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text("Maximum time between full-screen OCR captures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Keyframe threshold:")
                    Slider(value: $keyframeChangeThreshold, in: 0.20...0.80, step: 0.05)
                    Text("\(Int(keyframeChangeThreshold * 100))%")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text("Percentage of screen tiles that must change to trigger a full-screen OCR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API Server") {
                Toggle("Enable API server", isOn: $apiServerEnabled)
                    .onChange(of: apiServerEnabled) { _, enabled in
                        if enabled {
                            ServiceContainer.shared.startAPIServer()
                        } else {
                            ServiceContainer.shared.stopAPIServer()
                        }
                    }

                HStack {
                    Text("Port:")
                    TextField("Port", value: $apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: apiServerPort) { _, newValue in
                            apiServerPort = min(max(newValue, 1024), 65535)
                        }

                    Button("Restart") {
                        ServiceContainer.shared.stopAPIServer()
                        ServiceContainer.shared.startAPIServer()
                    }
                    .disabled(!apiServerEnabled)
                }

                if apiServerEnabled {
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(.green)
                        Text("http://127.0.0.1:\(apiServerPort)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Spacer()

                        Button("Open Docs") {
                            if let url = URL(string: "http://127.0.0.1:\(apiServerPort)/docs") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Models Tab

    private var modelsTab: some View {
        Form {
            Section("Summarization") {
                TextField("Model:", text: $summarizationModel)
                    .textFieldStyle(.roundedBorder)
                Text("Used for progressive summarization of screen activity. Recommend a cheap/fast model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Enrichment Pass 1 (Relevance Judging)") {
                TextField("Model:", text: $enrichmentPass1Model)
                    .textFieldStyle(.roundedBorder)
                Text("Judges which summaries are relevant to your prompt. Cheap/fast recommended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Enrichment Pass 2 (Context Synthesis)") {
                TextField("Model:", text: $enrichmentPass2Model)
                    .textFieldStyle(.roundedBorder)
                Text("Synthesizes detailed context into footnotes. Can use a more capable model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Limits Tab

    private var limitsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                limitsSection("Max Response Tokens") {
                    limitRow("Summarization", value: $summarizationMaxTokens, range: 256...8192, step: 256)
                    limitRow("Enrichment Pass 1", value: $enrichmentPass1MaxTokens, range: 256...8192, step: 256)
                    limitRow("Enrichment Pass 2", value: $enrichmentPass2MaxTokens, range: 256...8192, step: 256)
                }

                limitsSection("Context Retrieval") {
                    limitRow("Summaries for Pass 1", value: $maxSummariesForPass1, range: 5...100, step: 5)
                    limitRow("Captures for Pass 2", value: $maxCapturesForPass2, range: 10...200, step: 10)
                    limitRow("Samples per chunk", value: $maxSamplesPerChunk, range: 3...30, step: 1)
                }

                limitsSection("Enrichment Formatting") {
                    limitRow("Keyframes", value: $enrichmentMaxKeyframes, range: 1...30, step: 1)
                    limitRow("Deltas / keyframe", value: $enrichmentMaxDeltasPerKeyframe, range: 1...15, step: 1)
                    limitRow("Keyframe text chars", value: $enrichmentMaxKeyframeTextLength, range: 500...10000, step: 500)
                    limitRow("Delta text chars", value: $enrichmentMaxDeltaTextLength, range: 100...3000, step: 100)
                }

                limitsSection("Summarization Formatting") {
                    limitRow("Deltas / keyframe", value: $summarizationMaxDeltasPerKeyframe, range: 1...10, step: 1)
                    limitRow("Keyframe text chars", value: $summarizationMaxKeyframeTextLength, range: 500...10000, step: 500)
                    limitRow("Delta text chars", value: $summarizationMaxDeltaTextLength, range: 100...3000, step: 100)
                }

                Button("Reset All to Defaults") {
                    resetLimitsToDefaults()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 4)
        }
    }

    /// A grouped section box for the limits tab.
    private func limitsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(spacing: 2) {
                content()
            }
        }
    }

    /// A single settings row: label on the left, value + stepper on the right.
    private func limitRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(label)
                .lineLimit(1)
            Spacer()
            Text("\(value.wrappedValue)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func resetLimitsToDefaults() {
        summarizationMaxTokens = Defaults.summarizationMaxTokens
        enrichmentPass1MaxTokens = Defaults.enrichmentPass1MaxTokens
        enrichmentPass2MaxTokens = Defaults.enrichmentPass2MaxTokens
        maxSummariesForPass1 = Defaults.maxSummariesForPass1
        maxCapturesForPass2 = Defaults.maxCapturesForPass2
        maxSamplesPerChunk = Defaults.maxSamplesPerChunk
        enrichmentMaxKeyframes = Defaults.enrichmentMaxKeyframes
        enrichmentMaxDeltasPerKeyframe = Defaults.enrichmentMaxDeltasPerKeyframe
        enrichmentMaxKeyframeTextLength = Defaults.enrichmentMaxKeyframeTextLength
        enrichmentMaxDeltaTextLength = Defaults.enrichmentMaxDeltaTextLength
        summarizationMaxDeltasPerKeyframe = Defaults.summarizationMaxDeltasPerKeyframe
        summarizationMaxKeyframeTextLength = Defaults.summarizationMaxKeyframeTextLength
        summarizationMaxDeltaTextLength = Defaults.summarizationMaxDeltaTextLength
    }

    // MARK: - Prompts Tab

    private var promptsTab: some View {
        Form {
            Section("Summarization System Prompt") {
                TextEditor(text: $customSummarizationSystem)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)

                if customSummarizationSystem.isEmpty {
                    Text("Using default prompt. Enter custom text to override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset to Default") {
                    customSummarizationSystem = ""
                }
                .controlSize(.small)
            }

            Section("Enrichment Pass 1 System Prompt") {
                TextEditor(text: $customPass1System)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)

                Button("Reset to Default") {
                    customPass1System = ""
                }
                .controlSize(.small)
            }

            Section("Enrichment Pass 2 System Prompt") {
                TextEditor(text: $customPass2System)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)

                Button("Reset to Default") {
                    customPass2System = ""
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Storage Tab

    private var storageTab: some View {
        Form {
            Section("Retention") {
                Stepper("Keep data for \(retentionDays) days", value: $retentionDays, in: 1...90)
            }

            Section("Summarization Timing") {
                HStack {
                    Text("Chunk duration:")
                    Slider(value: $chunkDuration, in: 60...900, step: 60)
                    Text("\(Int(chunkDuration / 60))m")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Poll interval:")
                    Slider(value: $pollInterval, in: 10...300, step: 10)
                    Text("\(Int(pollInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Min age before summarizing:")
                    Slider(value: $minAge, in: 60...600, step: 30)
                    Text("\(Int(minAge / 60))m")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
        }
    }

    // MARK: - Actions

    private func saveApiKey() {
        do {
            try OpenRouterClient.saveAPIKey(apiKey)
            hasApiKey = true
            showApiKeySaved = true
            saveError = nil
            apiKey = "" // Clear from memory
            Task {
                try? await Task.sleep(for: .seconds(2))
                showApiKeySaved = false
            }
        } catch {
            saveError = "Failed to save API key: \(error.localizedDescription)"
        }
    }
}
