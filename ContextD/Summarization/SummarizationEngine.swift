import Foundation

/// Background engine that progressively summarizes captured screen content.
/// Runs periodically, picks up unsummarized captures, chunks them, and sends
/// each chunk to a cheap LLM (Claude Haiku) for summarization.
actor SummarizationEngine {
    private let storageManager: StorageManager
    private let llmClient: LLMClient
    private let logger = DualLogger(category: "Summarization")

    /// How often to check for unsummarized captures (seconds).
    var pollInterval: TimeInterval = 60

    /// Minimum age of captures before summarizing (seconds).
    /// Ensures we don't summarize very recent captures that might still be changing.
    var minimumAge: TimeInterval = 300 // 5 minutes

    /// Duration of each summarization time window (seconds).
    var chunkDuration: TimeInterval = 300 // 5 minutes

    /// Minimum sub-chunk duration when splitting at app boundaries (seconds).
    /// Sub-chunks shorter than this are merged into the previous chunk to avoid
    /// micro-chunks from rapid app switching. Set to 0 to disable merging.
    var minimumChunkDuration: TimeInterval = 15

    /// The model to use for summarization (cheap/fast).
    var model: String = "anthropic/claude-haiku-4-5"

    /// Maximum OCR text samples to include per chunk (to stay within token limits).
    var maxSamplesPerChunk: Int = 10

    /// Max response tokens for summarization LLM calls.
    var maxTokens: Int = 1024

    /// Max deltas per keyframe in formatted output.
    var maxDeltasPerKeyframe: Int = 3

    /// Max keyframe text length in formatted output.
    var maxKeyframeTextLength: Int = 2000

    /// Max delta text length in formatted output.
    var maxDeltaTextLength: Int = 300

    private var isRunning = false
    private var task: Task<Void, Never>?

    init(storageManager: StorageManager, llmClient: LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient
    }

    // MARK: - Settings Setters (for applying UserDefaults from outside the actor)

    func setModel(_ value: String) { model = value }
    func setMaxTokens(_ value: Int) { maxTokens = value }
    func setMaxSamplesPerChunk(_ value: Int) { maxSamplesPerChunk = value }
    func setMaxDeltasPerKeyframe(_ value: Int) { maxDeltasPerKeyframe = value }
    func setMaxKeyframeTextLength(_ value: Int) { maxKeyframeTextLength = value }
    func setMaxDeltaTextLength(_ value: Int) { maxDeltaTextLength = value }

    /// Start the background summarization loop.
    func start() {
        guard !isRunning else {
            logger.info("Summarization engine already running, ignoring start()")
            return
        }
        isRunning = true
        logger.info("Summarization engine started (poll: \(self.pollInterval)s, chunk: \(self.chunkDuration)s, minSubChunk: \(self.minimumChunkDuration)s)")

        task = Task { [weak self] in
            guard let self = self else {
                // This fires if the actor was deallocated before the Task ran.
                // Likely cause: @State on a SwiftUI struct not retaining the actor.
                DualLogger(category: "Summarization").error("SummarizationEngine deallocated before background task started (weak self was nil)")
                return
            }
            while !Task.isCancelled {
                await self.processPendingChunks()
                try? await Task.sleep(nanoseconds: UInt64(await self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stop the background summarization loop.
    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        logger.info("Summarization engine stopped")
    }

    /// Process all pending (unsummarized) captures.
    private func processPendingChunks() async {
        do {
            logger.debug("Polling for unsummarized captures (minimumAge: \(self.minimumAge)s)")

            let captures = try storageManager.unsummarizedCaptures(
                olderThan: minimumAge,
                limit: 500
            )

            guard !captures.isEmpty else {
                logger.debug("No unsummarized captures found (older than \(self.minimumAge)s)")
                return
            }

            logger.info("Found \(captures.count) unsummarized captures")

            let chunks = Chunker.chunkHybrid(
                captures: captures,
                windowDuration: chunkDuration,
                minimumChunkDuration: minimumChunkDuration
            )

            for chunk in chunks {
                do {
                    try await summarizeChunk(chunk)
                } catch {
                    logger.error("Failed to summarize chunk: \(error.localizedDescription)")
                    // Continue with next chunk instead of stopping entirely
                }
            }
        } catch {
            logger.error("Failed to fetch unsummarized captures: \(error.localizedDescription)")
        }
    }

    /// Summarize a single chunk of captures.
    private func summarizeChunk(_ chunk: Chunker.Chunk) async throws {
        // Build OCR samples using hierarchical keyframe+delta format
        let ocrSamples = CaptureFormatter.formatHierarchical(
            captures: chunk.captures,
            maxKeyframes: maxSamplesPerChunk,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let duration = chunk.endTime.timeIntervalSince(chunk.startTime)
        let durationStr = duration < 60
            ? "\(Int(duration))s"
            : "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .summarizationUser),
            values: [
                "start_time": dateFormatter.string(from: chunk.startTime),
                "end_time": dateFormatter.string(from: chunk.endTime),
                "duration": durationStr,
                "app_name": chunk.primaryApp,
                "window_title": chunk.primaryWindowTitle ?? "Unknown",
                "ocr_samples": ocrSamples,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .summarizationSystem)

        // Call LLM
        let llmResponse = try await llmClient.completeWithUsage(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        // Record token usage
        if let usage = llmResponse.usage {
            let usageRecord = TokenUsageRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                caller: "summarizer",
                model: model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            logger.debug("Summarizer tokens: in=\(usage.inputTokens) out=\(usage.outputTokens)")
        }

        // Parse JSON response
        let (summary, keyTopics) = parseSummarizationResponse(llmResponse.text)

        // Store the summary
        let appNamesJSON = try String(data: JSONEncoder().encode(chunk.appNames), encoding: .utf8) ?? "[]"
        let captureIdsJSON = try String(data: JSONEncoder().encode(chunk.captureIds), encoding: .utf8) ?? "[]"
        let keyTopicsJSON = try String(data: JSONEncoder().encode(keyTopics), encoding: .utf8) ?? "[]"

        let record = SummaryRecord(
            id: nil,
            startTimestamp: chunk.startTime.timeIntervalSince1970,
            endTimestamp: chunk.endTime.timeIntervalSince1970,
            appNames: appNamesJSON,
            summary: summary,
            keyTopics: keyTopicsJSON,
            captureIds: captureIdsJSON
        )

        try storageManager.insertSummary(record)
        try storageManager.markCapturesAsSummarized(ids: chunk.captureIds)

        logger.info("Summarized chunk: \(chunk.startTime.shortTimestamp)-\(chunk.endTime.shortTimestamp) (\(chunk.captures.count) captures)")
    }

    /// Parse the LLM's JSON response into summary text and key topics.
    private func parseSummarizationResponse(_ response: String) -> (summary: String, keyTopics: [String]) {
        let cleaned = stripCodeFences(response)

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let summary = json["summary"] as? String ?? response
            let topics = json["key_topics"] as? [String] ?? []
            return (summary, topics)
        }

        // Fallback: use the raw response as the summary
        logger.warning("Failed to parse summarization response as JSON. Raw response:\n\(response)")
        return (response, [])
    }

    /// Strip markdown code fences (```json ... ``` or ``` ... ```) from LLM output.
    private func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let endOfFirstLine = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: endOfFirstLine)...])
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generate evenly spaced indices for sampling.
    private func evenlySpacedIndices(count: Int, maxSamples: Int) -> [Int] {
        guard count > maxSamples else { return Array(0..<count) }
        let step = Double(count - 1) / Double(maxSamples - 1)
        return (0..<maxSamples).map { Int(Double($0) * step) }
    }
}
