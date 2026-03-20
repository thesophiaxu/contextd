import Foundation

/// Citation-oriented enrichment strategy for the API endpoint.
///
/// Uses the shared RetrievalPipeline for Pass 1 (relevance judging + capture fetching),
/// then runs its own Pass 2 to extract structured JSON citations.
final class CitationStrategy: @unchecked Sendable {
    private let logger = DualLogger(category: "CitationStrategy")
    private let pipeline = RetrievalPipeline()

    /// Model for Pass 1 (cheap/fast, relevance judging).
    var pass1Model: String = "anthropic/claude-haiku-4-5" {
        didSet { pipeline.pass1Model = pass1Model }
    }

    /// Model for Pass 2 (context synthesis into structured citations).
    var pass2Model: String = "anthropic/claude-sonnet-4-6"

    /// Maximum summaries to send to Pass 1.
    var maxSummariesForPass1: Int = 30 {
        didSet { pipeline.maxSummariesForPass1 = maxSummariesForPass1 }
    }

    /// Maximum captures to send to Pass 2.
    var maxCapturesForPass2: Int = 50 {
        didSet { pipeline.maxCapturesForPass2 = maxCapturesForPass2 }
    }

    /// Max response tokens for Pass 1 (relevance judging).
    var pass1MaxTokens: Int = 1024 {
        didSet { pipeline.pass1MaxTokens = pass1MaxTokens }
    }

    /// Max response tokens for Pass 2 (citation synthesis).
    var pass2MaxTokens: Int = 4096

    /// Capture formatting limits.
    var maxKeyframes: Int = 10
    var maxDeltasPerKeyframe: Int = 5
    var maxKeyframeTextLength: Int = 3000
    var maxDeltaTextLength: Int = 500

    /// Threshold below which we skip Pass 1 (LLM relevance judging) and send
    /// all FTS matches directly to Pass 2. When few summaries match, the LLM
    /// filtering cost exceeds the savings from excluding irrelevant ones.
    var smallResultSetThreshold: Int = 5 {
        didSet { pipeline.smallResultSetThreshold = smallResultSetThreshold }
    }

    // MARK: - Public API

    /// Result of a citation query.
    struct CitationResult: Sendable {
        let citations: [Citation]
        let summariesSearched: Int
        let capturesExamined: Int
        let processingTime: TimeInterval
    }

    /// Run the citation pipeline: retrieve relevant context and return structured citations.
    func queryCitations(
        text: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> CitationResult {
        let startTime = Date()

        // Shared retrieval pipeline: Pass 1 relevance + unsummarized, merged
        let retrieval = try await pipeline.retrieve(
            query: text,
            timeRange: timeRange,
            storageManager: storageManager,
            llmClient: llmClient
        )

        // Pass 2: Synthesize structured citations
        let citations: [Citation]
        let capturesExamined: Int

        if !retrieval.captures.isEmpty {
            let result = try await pass2ExtractCitations(
                query: text,
                captures: retrieval.captures,
                llmClient: llmClient,
                storageManager: storageManager
            )
            citations = result.citations
            capturesExamined = result.capturesExamined
        } else {
            citations = []
            capturesExamined = 0
        }

        let processingTime = Date().timeIntervalSince(startTime)

        logger.info(
            "Citation query: \(retrieval.captures.count) retrieved, "
            + "\(citations.count) citations in "
            + "\(String(format: "%.1f", processingTime))s"
        )

        return CitationResult(
            citations: citations,
            summariesSearched: retrieval.summariesSearched,
            capturesExamined: capturesExamined,
            processingTime: processingTime
        )
    }

    // MARK: - Pass 2: Citation Extraction

    private struct Pass2CitationResult {
        let citations: [Citation]
        let capturesExamined: Int
    }

    private func pass2ExtractCitations(
        query: String,
        captures: [CaptureRecord],
        llmClient: LLMClient,
        storageManager: StorageManager
    ) async throws -> Pass2CitationResult {
        let capturesText = CaptureFormatter.formatHierarchical(
            captures: captures,
            maxKeyframes: maxKeyframes,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .citationPass2User),
            values: [
                "query": query,
                "captures": capturesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .citationPass2System)

        let response = try await llmClient.completeWithUsage(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass2Model,
            maxTokens: pass2MaxTokens,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        // Record token usage
        if let usage = response.usage {
            let usageRecord = TokenUsageRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                caller: "enrichment_pass2_citation",
                model: pass2Model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            let cost = PromptTemplates.estimateCost(
                model: pass2Model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            logger.debug("Pass 2 (citation) \(cost)")
        }

        let citations = parseCitationResponse(response.text)
        logger.info("Pass 2: Examined \(captures.count) captures, extracted \(citations.count) citations")
        return Pass2CitationResult(citations: citations, capturesExamined: captures.count)
    }

    // MARK: - Response Parsing

    /// Parse the Pass 2 JSON response into Citation objects.
    private func parseCitationResponse(_ response: String) -> [Citation] {
        let cleaned = RetrievalPipeline.stripCodeFences(response)

        guard let data = cleaned.data(using: .utf8) else {
            logger.warning("Failed to encode citation response as UTF-8")
            return []
        }

        // Try decoding directly as [Citation]
        if let citations = try? JSONDecoder().decode([Citation].self, from: data) {
            return citations
        }

        // Fallback: parse as [[String: Any]] and extract manually
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.warning("Failed to parse citation response as JSON array. Raw:\n\(response.prefix(500))")
            return []
        }

        return json.compactMap { item -> Citation? in
            guard let relevantText = item["relevant_text"] as? String,
                  let explanation = item["relevance_explanation"] as? String else {
                return nil
            }

            return Citation(
                timestamp: item["timestamp"] as? String ?? ISO8601DateFormatter().string(from: Date()),
                app_name: item["app_name"] as? String ?? "Unknown",
                window_title: item["window_title"] as? String,
                relevant_text: relevantText,
                relevance_explanation: explanation,
                source: item["source"] as? String ?? "capture"
            )
        }
    }
}
