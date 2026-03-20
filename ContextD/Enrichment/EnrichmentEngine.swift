import Foundation

/// Coordinates enrichment by selecting and running the active strategy.
/// Provides the main entry point for the UI to request enrichment.
@MainActor
final class EnrichmentEngine: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var lastResult: EnrichedResult?
    @Published var lastError: String?

    /// Available enrichment strategies.
    let strategies: [EnrichmentStrategy]

    /// Index of the currently active strategy.
    @Published var activeStrategyIndex: Int = 0

    private let storageManager: StorageManager
    private let llmClient: LLMClient
    private let logger = DualLogger(category: "Enrichment")

    /// Handle to the in-flight enrichment task, used for cancellation.
    private var currentTask: Task<EnrichedResult?, Never>?

    var activeStrategy: EnrichmentStrategy {
        strategies[activeStrategyIndex]
    }

    init(storageManager: StorageManager, llmClient: LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient

        // Register available strategies
        self.strategies = [
            TwoPassLLMStrategy(),
        ]
    }

    /// Enrich a user prompt with context from recent screen activity.
    ///
    /// Cancels any previously in-flight enrichment request before starting a new one.
    /// - Parameters:
    ///   - query: The user's prompt text.
    ///   - timeRange: How far back to search for context.
    /// - Returns: The enriched result, or nil if cancelled or failed.
    @discardableResult
    func enrich(query: String, timeRange: TimeRange = .last(minutes: 30)) async -> EnrichedResult? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Please enter a prompt to enrich."
            return nil
        }

        // Cancel any previous in-flight enrichment request
        currentTask?.cancel()

        isProcessing = true
        lastError = nil
        lastResult = nil

        let strategy = activeStrategy
        let storage = storageManager
        let client = llmClient
        let log = logger

        let task = Task<EnrichedResult?, Never> { [weak self] in
            do {
                let result = try await strategy.enrich(
                    query: query,
                    timeRange: timeRange,
                    storageManager: storage,
                    llmClient: client
                )

                // Check cancellation before applying results
                guard !Task.isCancelled else {
                    log.debug("Enrichment cancelled, discarding result")
                    return nil
                }

                await MainActor.run {
                    self?.lastResult = result
                    self?.isProcessing = false
                }

                log.info("Enrichment complete: \(result.metadata.summariesSearched) summaries, \(result.metadata.capturesExamined) captures, \(String(format: "%.1f", result.metadata.processingTime))s")

                return result

            } catch is CancellationError {
                log.debug("Enrichment task cancelled")
                await MainActor.run {
                    self?.isProcessing = false
                }
                return nil

            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isProcessing = false
                }
                log.error("Enrichment failed: \(error.localizedDescription)")
                return nil
            }
        }

        currentTask = task
        return await task.value
    }

    /// Cancel any in-flight enrichment request.
    func cancelEnrichment() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        logger.debug("Enrichment cancelled by user")
    }
}
