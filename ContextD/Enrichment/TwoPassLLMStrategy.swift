import Foundation

/// Two-pass LLM retrieval strategy for context enrichment.
///
/// Uses the shared RetrievalPipeline for Pass 1 (relevance judging + capture fetching),
/// then runs its own Pass 2 to synthesize markdown footnotes.
final class TwoPassLLMStrategy: EnrichmentStrategy, @unchecked Sendable {
    let name = "Two-Pass LLM"
    let strategyDescription = "Uses FTS5 search + LLM relevance judging, then detailed capture analysis"

    private let logger = DualLogger(category: "TwoPassLLM")
    private let pipeline = RetrievalPipeline()

    /// Model for Pass 1 (cheap/fast, relevance judging).
    var pass1Model: String = "anthropic/claude-haiku-4-5" {
        didSet { pipeline.pass1Model = pass1Model }
    }

    /// Model for Pass 2 (can be more capable, context synthesis).
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

    /// Max response tokens for Pass 2 (context synthesis).
    var pass2MaxTokens: Int = 2048

    /// Capture formatting limits for enrichment.
    var maxKeyframes: Int = 10
    var maxDeltasPerKeyframe: Int = 5
    var maxKeyframeTextLength: Int = 3000
    var maxDeltaTextLength: Int = 500

    func enrich(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> EnrichedResult {
        let startTime = Date()

        // Shared retrieval pipeline: Pass 1 relevance + unsummarized, merged
        let retrieval = try await pipeline.retrieve(
            query: query,
            timeRange: timeRange,
            storageManager: storageManager,
            llmClient: llmClient
        )

        // Pass 2: Synthesize footnotes from retrieved captures
        let footnotes: String
        let capturesExamined: Int

        if !retrieval.captures.isEmpty {
            let result = try await pass2Synthesize(
                query: query,
                captures: retrieval.captures,
                llmClient: llmClient,
                storageManager: storageManager
            )
            footnotes = result.footnotes
            capturesExamined = result.capturesExamined
        } else {
            footnotes = ""
            capturesExamined = 0
        }

        // Build final result. The LLM already returns a "## Recent Screen Context"
        // heading with structured lines, so we just append it with a separator.
        let enrichedPrompt: String
        if footnotes.isEmpty {
            enrichedPrompt = query + "\n\n_(No relevant context found from recent activity.)_"
        } else {
            enrichedPrompt = query + "\n\n---\n" + footnotes
        }

        let metadata = EnrichmentMetadata(
            strategy: name,
            timeRange: timeRange,
            summariesSearched: retrieval.summariesSearched,
            capturesExamined: capturesExamined,
            processingTime: Date().timeIntervalSince(startTime),
            pass1Model: pass1Model,
            pass2Model: pass2Model
        )

        return EnrichedResult(
            originalPrompt: query,
            enrichedPrompt: enrichedPrompt,
            references: [],
            metadata: metadata
        )
    }

    // MARK: - Pass 2: Context Synthesis

    private struct Pass2Result {
        let footnotes: String
        let capturesExamined: Int
    }

    /// Run the Pass 2 LLM call to synthesize footnotes from a set of captures.
    private func pass2Synthesize(
        query: String,
        captures: [CaptureRecord],
        llmClient: LLMClient,
        storageManager: StorageManager
    ) async throws -> Pass2Result {
        let capturesText = CaptureFormatter.formatHierarchical(
            captures: captures,
            maxKeyframes: maxKeyframes,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .enrichmentPass2User),
            values: [
                "query": query,
                "captures": capturesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .enrichmentPass2System)

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
                caller: "enrichment_pass2",
                model: pass2Model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            let cost = PromptTemplates.estimateCost(
                model: pass2Model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            logger.debug("Pass 2 \(cost)")
        }

        logger.info("Pass 2: Examined \(captures.count) captures, generated footnotes")
        return Pass2Result(footnotes: response.text, capturesExamined: captures.count)
    }
}
