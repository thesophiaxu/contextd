import SwiftUI

/// Menu bar dropdown view with capture status, controls, and navigation.
///
/// Values are snapshotted once when the menu opens to avoid continuous
/// re-renders (which cause flashing and selection jumps in MenuBarExtra).
struct MenuBarView: View {
    var captureEngine: CaptureEngine
    @ObservedObject var permissionManager: PermissionManager
    var storageManager: StorageManager?

    var onOpenEnrichment: () -> Void
    var onOpenDebug: () -> Void

    // Snapshotted values — populated once on appear, not live-bound.
    @State private var isRunning: Bool = false
    @State private var captureCount: Int = 0
    @State private var lastCaptureTime: Date?
    @State private var lastError: String?
    @State private var summarizerUsage: TokenUsageTotals?
    @State private var hasAppeared = false

    var body: some View {
        statusSection
        Divider()
        controlsSection
        Divider()
        navigationSection
        Divider()
        Button("Quit ContextD") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var statusSection: some View {
        let statusText = isRunning
            ? "Capturing (\(captureCount))"
            : "Paused"
        Text(statusText)
            .font(.caption)
            .onAppear {
                snapshotState()
            }

        if let lastTime = lastCaptureTime {
            Text("Last: \(lastTime.relativeString)")
                .font(.caption)
        }

        if let error = lastError {
            Text("Error: \(error)")
                .font(.caption)
        }

        if let usage = summarizerUsage {
            Text("Tokens 24h: \(formatTokens(usage.inputTokens)) in / \(formatTokens(usage.outputTokens)) out")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Button(isRunning ? "Pause Capture" : "Resume Capture") {
            if captureEngine.isRunning {
                captureEngine.stop()
            } else {
                captureEngine.start()
            }
            // Update local snapshot to reflect the toggle immediately.
            isRunning = captureEngine.isRunning
        }

        Button("Enrich Prompt...") {
            onOpenEnrichment()
        }
        .keyboardShortcut(" ", modifiers: [.command, .shift])
    }

    @State private var copiedAPIUrl = false

    @ViewBuilder
    private var navigationSection: some View {
        if !permissionManager.allPermissionsGranted {
            Text("Missing permissions")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if let server = ServiceContainer.shared.apiServer {
            Button(copiedAPIUrl ? "Copied!" : "API Docs — 127.0.0.1:\(String(server.port))/docs") {
                let url = "http://127.0.0.1:\(server.port)/docs"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copiedAPIUrl = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copiedAPIUrl = false
                }
            }
        }

        SettingsLink {
            Text("Settings...")
        }
        .keyboardShortcut(",")

        Button("Database Debug...") {
            onOpenDebug()
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
    }

    /// Capture a one-time snapshot of the engine state and token usage.
    private func snapshotState() {
        guard !hasAppeared else { return }
        hasAppeared = true
        isRunning = captureEngine.isRunning
        captureCount = captureEngine.captureCount
        lastCaptureTime = captureEngine.lastCaptureTime
        lastError = captureEngine.lastError
        if let storage = storageManager {
            summarizerUsage = try? storage.tokenUsageTotals(caller: "summarizer")
        }
    }

    private func formatTokens(_ value: Int64) -> String {
        switch value {
        case 0..<1_000:
            return "\(value)"
        case 1_000..<1_000_000:
            return String(format: "%.1fk", Double(value) / 1_000)
        default:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
    }
}
