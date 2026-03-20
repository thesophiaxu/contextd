import SwiftUI
import AppKit

/// The floating panel that appears when the global hotkey is pressed.
/// Allows the user to enter a prompt, enrich it with context, and copy the result.
struct EnrichmentPanel: View {
    @ObservedObject var enrichmentEngine: EnrichmentEngine
    @State private var promptText: String = ""
    @State private var selectedTimeRange: TimeRangeOption = .thirtyMinutes
    @State private var showCopied: Bool = false
    @FocusState private var isPromptFocused: Bool

    enum TimeRangeOption: String, CaseIterable, Identifiable {
        case fiveMinutes = "5 min"
        case fifteenMinutes = "15 min"
        case thirtyMinutes = "30 min"
        case oneHour = "1 hour"
        case twoHours = "2 hours"

        var id: String { rawValue }

        var timeRange: TimeRange {
            switch self {
            case .fiveMinutes: return .last(minutes: 5)
            case .fifteenMinutes: return .last(minutes: 15)
            case .thirtyMinutes: return .last(minutes: 30)
            case .oneHour: return .last(hours: 1)
            case .twoHours: return .last(hours: 2)
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                Text("Enrich Prompt")
                    .font(.headline)
                Spacer()

                Picker("Time Range", selection: $selectedTimeRange) {
                    ForEach(TimeRangeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            // Prompt input
            VStack(alignment: .leading, spacing: 4) {
                Text("Your prompt:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptText)
                    .focused($isPromptFocused)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            // Enrich button
            HStack {
                Button(action: enrich) {
                    if enrichmentEngine.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Enriching...")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Enrich")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(enrichmentEngine.isProcessing || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)

                Spacer()

                if enrichmentEngine.lastResult != nil {
                    Button(action: copyToClipboard) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        Text(showCopied ? "Copied!" : "Copy")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }

            // Error
            if let error = enrichmentEngine.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Result
            if let result = enrichmentEngine.lastResult {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Enriched prompt:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(result.metadata.summariesSearched) summaries, \(result.metadata.capturesExamined) captures, \(String(format: "%.1f", result.metadata.processingTime))s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    ScrollView {
                        Text(result.enrichedPrompt)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            isPromptFocused = true
        }
    }

    private func enrich() {
        Task {
            await enrichmentEngine.enrich(
                query: promptText,
                timeRange: selectedTimeRange.timeRange
            )
        }
    }

    private func copyToClipboard() {
        guard let result = enrichmentEngine.lastResult else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.enrichedPrompt, forType: .string)

        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopied = false
        }
    }
}
