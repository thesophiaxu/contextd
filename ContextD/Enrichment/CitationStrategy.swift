import Foundation

/// Citation-oriented enrichment strategy for the API endpoint.
///
/// Reuses the same two-pass retrieval pipeline as TwoPassLLMStrategy:
///   Pass 1: FTS5 search summaries + recency -> LLM judges relevance
///   Pass 2: Fetch detailed captures for relevant summaries -> LLM outputs JSON citations
///
/// The key difference: Pass 2 returns a JSON array of structured citations instead of
/// markdown footnotes, making it suitable for programmatic consumption via the API.
final class CitationStrategy: @unchecked Sendable {
    private let logger = DualLogger(category: "CitationStrategy")

    /// Model for Pass 1 (cheap/fast, relevance judging).
    var pass1Model: String = "anthropic/claude-haiku-4-5"

    /// Model for Pass 2 (context synthesis into structured citations).
    var pass2Model: String = "anthropic/claude-sonnet-4-6"

    /// Maximum summaries to send to Pass 1.
    var maxSummariesForPass1: Int = 30

    /// Maximum captures to send to Pass 2.
    var maxCapturesForPass2: Int = 50

    /// Max response tokens for Pass 1 (relevance judging).
    var pass1MaxTokens: Int = 1024

    /// Max response tokens for Pass 2 (citation synthesis).
    var pass2MaxTokens: Int = 4096

    /// Capture formatting limits.
    var maxKeyframes: Int = 10
    var maxDeltasPerKeyframe: Int = 5
    var maxKeyframeTextLength: Int = 3000
    var maxDeltaTextLength: Int = 500

    // MARK: - Citation-Specific Prompts

    private let citationPass2System = """
        You are a context retrieval system. Given a user's query and detailed screen \
        captures from their recent computer activity, extract structured citations that \
        are relevant to the query.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific — include exact names, values, code snippets, etc.
        - Order by relevance (most relevant first)
        - Maximum 10 citations
        - Each citation must include the timestamp, app name, and window title from the capture data

        Respond ONLY with a JSON array (no markdown, no explanation). Example:
        [
          {
            "timestamp": "2026-03-12T10:23:45Z",
            "app_name": "Google Chrome",
            "window_title": "Pull Request #482 - GitHub",
            "relevant_text": "Refactored OAuth2 token refresh logic to handle concurrent requests...",
            "relevance_explanation": "This PR review discussed the auth token changes the user is asking about",
            "source": "capture"
          }
        ]

        If nothing is relevant, respond with an empty array: []
        """

    private let citationPass2User = """
        ## User's Query
        {query}

        ## Detailed Screen Activity
        {captures}

        Extract structured JSON citations with relevant context for the user's query.
        """

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

        // --- Run both retrieval paths in parallel ---
        async let summaryCapturesResult = fetchCapturesViaSummaries(
            query: text,
            timeRange: timeRange,
            storageManager: storageManager,
            llmClient: llmClient
        )

        async let unsummarizedCapturesResult = fetchUnsummarizedCaptures(
            query: text,
            timeRange: timeRange,
            storageManager: storageManager
        )

        let summaryPath = try await summaryCapturesResult
        let unsummarizedPath = try await unsummarizedCapturesResult

        // --- Merge and deduplicate captures from both paths ---
        var seen = Set<Int64>()
        var mergedCaptures: [CaptureRecord] = []

        for capture in summaryPath.captures {
            if let id = capture.id, !seen.contains(id) {
                seen.insert(id)
                mergedCaptures.append(capture)
            }
        }

        for capture in unsummarizedPath {
            if let id = capture.id, !seen.contains(id) {
                seen.insert(id)
                mergedCaptures.append(capture)
            }
        }

        mergedCaptures.sort { $0.timestamp > $1.timestamp }
        let limitedCaptures = Array(mergedCaptures.prefix(maxCapturesForPass2))

        // --- Pass 2: Synthesize structured citations ---
        let citations: [Citation]
        let capturesExamined: Int

        if !limitedCaptures.isEmpty {
            let result = try await pass2ExtractCitations(
                query: text,
                captures: limitedCaptures,
                llmClient: llmClient
            )
            citations = result.citations
            capturesExamined = result.capturesExamined
        } else {
            citations = []
            capturesExamined = 0
        }

        let processingTime = Date().timeIntervalSince(startTime)

        logger.info("Citation query: \(summaryPath.captures.count) from summaries, \(unsummarizedPath.count) unsummarized, \(limitedCaptures.count) merged, \(citations.count) citations in \(String(format: "%.1f", processingTime))s")

        return CitationResult(
            citations: citations,
            summariesSearched: summaryPath.summariesSearched,
            capturesExamined: capturesExamined,
            processingTime: processingTime
        )
    }

    // MARK: - Pass 1: Relevance Judging (identical to TwoPassLLMStrategy)

    private func pass1RelevanceJudging(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> (relevantIds: [Int64], allSummaries: [SummaryRecord]) {
        var summaries: [SummaryRecord] = []

        let ftsResults = try storageManager.searchSummaries(query: query, limit: maxSummariesForPass1 / 2)
        summaries.append(contentsOf: ftsResults)

        let recentResults = try storageManager.summaries(
            from: timeRange.start,
            to: timeRange.end,
            limit: maxSummariesForPass1 / 2
        )
        summaries.append(contentsOf: recentResults)

        var seen = Set<Int64>()
        summaries = summaries.filter { summary in
            guard let id = summary.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }

        guard !summaries.isEmpty else {
            logger.info("Pass 1: No summaries found")
            return ([], [])
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let summariesText: String = summaries.enumerated().map { index, summary -> String in
            let apps = summary.decodedAppNames.joined(separator: ", ")
            let topics = summary.decodedKeyTopics.joined(separator: ", ")
            let id = summary.id ?? Int64(index)
            let start = dateFormatter.string(from: summary.startDate)
            let end = dateFormatter.string(from: summary.endDate)
            return "[\(id)]: \(start) - \(end)\nApps: \(apps)\nTopics: \(topics)\nSummary: \(summary.summary)"
        }.joined(separator: "\n\n")

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .enrichmentPass1User),
            values: [
                "query": query,
                "summaries": summariesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .enrichmentPass1System)

        let response = try await llmClient.complete(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass1Model,
            maxTokens: pass1MaxTokens,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        let relevantIds = parsePass1Response(response, validIds: Set(summaries.compactMap(\.id)))

        logger.info("Pass 1: \(summaries.count) summaries searched, \(relevantIds.count) relevant")
        return (relevantIds, summaries)
    }

    // MARK: - Path A: Fetch captures via summaries

    private struct SummaryPathResult {
        let captures: [CaptureRecord]
        let summariesSearched: Int
    }

    private func fetchCapturesViaSummaries(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> SummaryPathResult {
        let (relevantSummaryIds, allSummaries) = try await pass1RelevanceJudging(
            query: query,
            timeRange: timeRange,
            storageManager: storageManager,
            llmClient: llmClient
        )

        guard !relevantSummaryIds.isEmpty else {
            return SummaryPathResult(captures: [], summariesSearched: allSummaries.count)
        }

        var allCaptureIds: [Int64] = []
        let allDBSummaries = try storageManager.summaries(
            from: Date.distantPast,
            to: Date.distantFuture,
            limit: 1000
        )
        for summaryId in relevantSummaryIds {
            if let summary = allDBSummaries.first(where: { $0.id == summaryId }) {
                allCaptureIds.append(contentsOf: summary.decodedCaptureIds)
            }
        }

        let captures = try storageManager.captures(ids: Array(Set(allCaptureIds)))
        logger.info("Path A (summaries): \(allSummaries.count) searched, \(relevantSummaryIds.count) relevant, \(captures.count) captures resolved")
        return SummaryPathResult(captures: captures, summariesSearched: allSummaries.count)
    }

    // MARK: - Path B: Fetch unsummarized captures

    private func fetchUnsummarizedCaptures(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager
    ) throws -> [CaptureRecord] {
        let ftsResults = try storageManager.searchCaptures(query: query, limit: maxCapturesForPass2 / 2)
            .filter { !$0.isSummarized }

        let recentUnsummarized = try storageManager.unsummarizedCaptures(
            from: timeRange.start,
            to: timeRange.end,
            limit: maxCapturesForPass2 / 2
        )

        var seen = Set<Int64>()
        let merged = (ftsResults + recentUnsummarized).filter { capture in
            guard let id = capture.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }

        logger.info("Path B (unsummarized): \(ftsResults.count) FTS + \(recentUnsummarized.count) recent = \(merged.count) after dedup")
        return merged
    }

    // MARK: - Pass 2: Citation Extraction

    private struct Pass2CitationResult {
        let citations: [Citation]
        let capturesExamined: Int
    }

    private func pass2ExtractCitations(
        query: String,
        captures: [CaptureRecord],
        llmClient: LLMClient
    ) async throws -> Pass2CitationResult {
        let capturesText = CaptureFormatter.formatHierarchical(
            captures: captures,
            maxKeyframes: maxKeyframes,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )

        let userPrompt = PromptTemplates.render(
            citationPass2User,
            values: [
                "query": query,
                "captures": capturesText,
            ]
        )

        let response = try await llmClient.complete(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass2Model,
            maxTokens: pass2MaxTokens,
            systemPrompt: citationPass2System,
            temperature: 0.0
        )

        let citations = parseCitationResponse(response)
        logger.info("Pass 2: Examined \(captures.count) captures, extracted \(citations.count) citations")
        return Pass2CitationResult(citations: citations, capturesExamined: captures.count)
    }

    // MARK: - Response Parsing

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

    private func parsePass1Response(_ response: String, validIds: Set<Int64>) -> [Int64] {
        let cleaned = stripCodeFences(response)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.warning("Failed to parse Pass 1 response as JSON array")
            return []
        }

        return json.compactMap { item -> Int64? in
            if let intId = item["id"] as? Int {
                let id64 = Int64(intId)
                return validIds.contains(id64) ? id64 : nil
            }
            if let id64 = item["id"] as? Int64, validIds.contains(id64) {
                return id64
            }
            if let doubleId = item["id"] as? Double {
                let id64 = Int64(doubleId)
                return validIds.contains(id64) ? id64 : nil
            }
            return nil
        }
    }

    /// Parse the Pass 2 JSON response into Citation objects.
    private func parseCitationResponse(_ response: String) -> [Citation] {
        let cleaned = stripCodeFences(response)

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
