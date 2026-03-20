import Foundation

/// Singleton container for all long-lived services.
/// Lives outside SwiftUI's struct lifecycle so services are created once
/// and never deallocated by view re-renders.
@MainActor
final class ServiceContainer {
    static let shared = ServiceContainer()

    private let logger = DualLogger(category: "Services")

    // Core services
    let database: AppDatabase?
    let storageManager: StorageManager?
    let llmClient: OpenRouterClient
    let captureEngine: CaptureEngine?
    let enrichmentEngine: EnrichmentEngine?
    let summarizationEngine: SummarizationEngine?
    let panelController: EnrichmentPanelController?
    let debugController: DebugWindowController?

    // API server
    private(set) var apiServer: APIServer?

    private init() {
        llmClient = OpenRouterClient()

        do {
            let db = try AppDatabase()
            let storage = StorageManager(database: db)

            database = db
            storageManager = storage
            captureEngine = CaptureEngine(storageManager: storage)

            let enrichment = EnrichmentEngine(storageManager: storage, llmClient: llmClient)
            enrichmentEngine = enrichment

            summarizationEngine = SummarizationEngine(storageManager: storage, llmClient: llmClient)
            panelController = EnrichmentPanelController(enrichmentEngine: enrichment)
            debugController = DebugWindowController(storageManager: storage)

            logger.info("ServiceContainer initialized successfully")
        } catch {
            logger.error("Failed to initialize services: \(error.localizedDescription)")
            database = nil
            storageManager = nil
            captureEngine = nil
            enrichmentEngine = nil
            summarizationEngine = nil
            panelController = nil
            debugController = nil
        }
    }

    /// Start capture + summarization. Call once after permissions are confirmed.
    func startServices() {
        guard PermissionManager.shared.allPermissionsGranted else {
            logger.warning("Cannot start services: missing permissions")
            return
        }

        // Apply user settings to capture engine
        if let engine = captureEngine {
            let interval = UserDefaults.standard.double(forKey: "captureInterval")
            if interval > 0 { engine.captureInterval = interval }

            let maxKFInterval = UserDefaults.standard.double(forKey: "maxKeyframeInterval")
            if maxKFInterval > 0 { engine.maxKeyframeInterval = maxKFInterval }

            let threshold = UserDefaults.standard.double(forKey: "keyframeChangeThreshold")
            if threshold > 0 { engine.imageDiffer.significantChangeThreshold = threshold }
        }

        captureEngine?.start()

        // Apply user settings to enrichment strategy
        if let enrichment = enrichmentEngine,
           let strategy = enrichment.strategies.first as? TwoPassLLMStrategy {
            let defaults = UserDefaults.standard

            let maxSummP1 = defaults.integer(forKey: "maxSummariesForPass1")
            if maxSummP1 > 0 { strategy.maxSummariesForPass1 = maxSummP1 }

            let maxCapP2 = defaults.integer(forKey: "maxCapturesForPass2")
            if maxCapP2 > 0 { strategy.maxCapturesForPass2 = maxCapP2 }

            let p1Tokens = defaults.integer(forKey: "enrichmentPass1MaxTokens")
            if p1Tokens > 0 { strategy.pass1MaxTokens = p1Tokens }

            let p2Tokens = defaults.integer(forKey: "enrichmentPass2MaxTokens")
            if p2Tokens > 0 { strategy.pass2MaxTokens = p2Tokens }

            let maxKF = defaults.integer(forKey: "enrichmentMaxKeyframes")
            if maxKF > 0 { strategy.maxKeyframes = maxKF }

            let maxDPKF = defaults.integer(forKey: "enrichmentMaxDeltasPerKeyframe")
            if maxDPKF > 0 { strategy.maxDeltasPerKeyframe = maxDPKF }

            let maxKFText = defaults.integer(forKey: "enrichmentMaxKeyframeTextLength")
            if maxKFText > 0 { strategy.maxKeyframeTextLength = maxKFText }

            let maxDText = defaults.integer(forKey: "enrichmentMaxDeltaTextLength")
            if maxDText > 0 { strategy.maxDeltaTextLength = maxDText }
        }

        let hasAPIKey = OpenRouterClient.hasAPIKey()
        logger.info("API key present: \(hasAPIKey)")

        if hasAPIKey {
            if let engine = summarizationEngine {
                Task {
                    // Apply user settings to summarization engine
                    let defaults = UserDefaults.standard

                    let sumMaxTokens = defaults.integer(forKey: "summarizationMaxTokens")
                    if sumMaxTokens > 0 { await engine.setMaxTokens(sumMaxTokens) }

                    let maxSamples = defaults.integer(forKey: "maxSamplesPerChunk")
                    if maxSamples > 0 { await engine.setMaxSamplesPerChunk(maxSamples) }

                    let sumMaxDPKF = defaults.integer(forKey: "summarizationMaxDeltasPerKeyframe")
                    if sumMaxDPKF > 0 { await engine.setMaxDeltasPerKeyframe(sumMaxDPKF) }

                    let sumMaxKFText = defaults.integer(forKey: "summarizationMaxKeyframeTextLength")
                    if sumMaxKFText > 0 { await engine.setMaxKeyframeTextLength(sumMaxKFText) }

                    let sumMaxDText = defaults.integer(forKey: "summarizationMaxDeltaTextLength")
                    if sumMaxDText > 0 { await engine.setMaxDeltaTextLength(sumMaxDText) }

                    await engine.start()
                }
            } else {
                logger.error("summarizationEngine is nil — cannot start summarization")
            }
        } else {
            logger.warning("No API key at \(OpenRouterClient.apiKeyFileURL.path) — summarization disabled")
        }

        // Start the API server if enabled
        let apiServerEnabled = UserDefaults.standard.bool(forKey: "apiServerEnabled")
        // Default to enabled if the key has never been set
        let hasBeenSet = UserDefaults.standard.object(forKey: "apiServerEnabled") != nil
        if !hasBeenSet || apiServerEnabled {
            startAPIServer()
        }

        logger.info("All services started")
    }

    /// Start the API server on the configured port.
    func startAPIServer() {
        guard let storage = storageManager else {
            logger.error("Cannot start API server: storageManager is nil")
            return
        }

        // Stop existing server if running
        apiServer?.stop()

        let port = UserDefaults.standard.integer(forKey: "apiServerPort")
        let effectivePort = port > 0 ? port : 21890

        let server = APIServer(storageManager: storage, port: effectivePort)
        server.start()
        apiServer = server

        logger.info("API server started on port \(effectivePort)")
    }

    /// Stop the API server.
    func stopAPIServer() {
        apiServer?.stop()
        apiServer = nil
        logger.info("API server stopped")
    }
}
