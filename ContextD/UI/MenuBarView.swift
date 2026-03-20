import SwiftUI

/// Rich menu bar dropdown panel with status, stats, recent activity, and actions.
///
/// Values are snapshotted once when the menu opens to avoid continuous
/// re-renders (which cause flashing in MenuBarExtra windows).
struct MenuBarView: View {
    @ObservedObject var captureEngine: CaptureEngine
    @ObservedObject var permissionManager: PermissionManager
    var storageManager: StorageManager?

    var onOpenEnrichment: () -> Void
    var onOpenDebug: () -> Void

    // Snapshotted values -- refreshed each time the menu opens.
    @State private var captureCount24h: Int = 0
    @State private var summaryCount24h: Int = 0
    @State private var estimatedCostToday: Double = 0
    @State private var recentCaptures: [CaptureRecord] = []
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 0) {
            StatusHeaderView(
                state: captureEngine.state,
                isRunning: captureEngine.isRunning
            )
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            StatsCardsView(
                captureCount: captureCount24h,
                summaryCount: summaryCount24h,
                estimatedCost: estimatedCostToday
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            IntervalIndicatorView(captureEngine: captureEngine)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            RecentActivityView(captures: recentCaptures)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Only show warning if captures are NOT flowing (real problem)
            // Don't show if it's just the macOS 15 stale permission check
            let capturesWorking = captureCount24h > 0
            if lastError != nil || (!permissionManager.allPermissionsGranted && !capturesWorking) {
                Divider()
                    .padding(.horizontal, 12)
                WarningBannerView(
                    error: lastError,
                    permissionsOK: permissionManager.allPermissionsGranted || capturesWorking
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            Divider()
                .padding(.horizontal, 12)

            ActionsView(
                captureEngine: captureEngine,
                onOpenEnrichment: onOpenEnrichment,
                onOpenDebug: onOpenDebug
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 12)

            QuitButton()
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .frame(width: 320)
        .onAppear {
            snapshotState()
        }
    }

    // MARK: - Data Snapshot

    /// Capture a fresh snapshot of stats each time the menu opens.
    private func snapshotState() {
        lastError = captureEngine.lastError

        guard let storage = storageManager else { return }

        captureCount24h = (try? storage.captureCount24h()) ?? 0
        summaryCount24h = (try? storage.summaryCount24h()) ?? 0
        recentCaptures = (try? storage.recentCaptures(limit: 3)) ?? []

        // Estimate cost from token usage (Haiku pricing approximation)
        if let usage = try? storage.totalTokenUsage24h() {
            // Approximate pricing: $0.25/Mtok input, $1.25/Mtok output (Haiku 4.5)
            let inputCost = usage.inputMtok * 0.25
            let outputCost = usage.outputMtok * 1.25
            estimatedCostToday = inputCost + outputCost
        }
    }
}
