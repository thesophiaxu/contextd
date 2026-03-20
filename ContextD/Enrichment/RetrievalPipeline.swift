import Foundation

/// Shared retrieval pipeline: Pass 1 relevance judging, summary-to-capture resolution,
/// and unsummarized capture fetching. Each strategy only implements its own Pass 2.
final class RetrievalPipeline: @unchecked Sendable {
    private let logger = DualLogger(category: "RetrievalPipeline")

    /// Model for Pass 1 (cheap/fast, relevance judging).
    var pass1Model: String = "anthropic/claude-haiku-4-5"

    /// Maximum summaries to send to Pass 1.
    var maxSummariesForPass1: Int = 30

    /// Maximum captures to merge for Pass 2.
    var maxCapturesForPass2: Int = 50

    /// Max response tokens for Pass 1 (relevance judging).
    var pass1MaxTokens: Int = 1024

    /// Fast-path threshold: if fewer than this many summaries match FTS,
    /// skip Pass 1 (LLM relevance judging) and treat all matches as relevant.
    /// The Haiku filtering cost exceeds savings for tiny result sets.
    var smallResultSetThreshold: Int = 5

    struct RetrievalResult: Sendable { let captures: [CaptureRecord]; let summariesSearched: Int }
    struct SummaryPathResult: Sendable { let captures: [CaptureRecord]; let summariesSearched: Int }

    // MARK: - Public API

    /// Run the full retrieval pipeline and return merged, deduped captures for Pass 2.
    func retrieve(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> RetrievalResult {
        // Run both retrieval paths in parallel
        async let summaryCapturesResult = fetchCapturesViaSummaries(
            query: query,
            timeRange: timeRange,
            storageManager: storageManager,
            llmClient: llmClient
        )

        async let unsummarizedCapturesResult = fetchUnsummarizedCaptures(
            query: query,
            timeRange: timeRange,
            storageManager: storageManager
        )

        let summaryPath = try await summaryCapturesResult
        let unsummarizedPath = try await unsummarizedCapturesResult

        // Merge and deduplicate: summary-path first, then unsummarized
        var seen = Set<Int64>()
        var mergedCaptures: [CaptureRecord] = []
        for capture in summaryPath.captures + unsummarizedPath {
            if let id = capture.id, !seen.contains(id) {
                seen.insert(id)
                mergedCaptures.append(capture)
            }
        }

        mergedCaptures.sort { $0.timestamp > $1.timestamp }
        let limitedCaptures = Array(mergedCaptures.prefix(maxCapturesForPass2))

        logger.info(
            "Retrieval: \(summaryPath.captures.count) from summaries, "
            + "\(unsummarizedPath.count) unsummarized, "
            + "\(limitedCaptures.count) merged for Pass 2"
        )

        return RetrievalResult(
            captures: limitedCaptures,
            summariesSearched: summaryPath.summariesSearched
        )
    }

    // MARK: - Pass 1: Relevance Judging

    /// Search summaries via FTS + recency, then ask the LLM which are relevant
    /// (or skip the LLM call for small result sets below `smallResultSetThreshold`).
    func pass1RelevanceJudging(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> (relevantIds: [Int64], allSummaries: [SummaryRecord]) {
        // Gather summaries: FTS search + recent
        var summaries: [SummaryRecord] = []

        let ftsResults = try storageManager.searchSummaries(
            query: query,
            limit: maxSummariesForPass1 / 2
        )
        summaries.append(contentsOf: ftsResults)

        let recentResults = try storageManager.summaries(
            from: timeRange.start,
            to: timeRange.end,
            limit: maxSummariesForPass1 / 2
        )
        summaries.append(contentsOf: recentResults)

        // Deduplicate by ID
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

        // Fast-path: if the result set is small, skip the LLM call entirely.
        // The Haiku filtering cost exceeds savings when there are few candidates.
        if summaries.count < smallResultSetThreshold {
            let allIds = summaries.compactMap(\.id)
            logger.info(
                "Pass 1: Fast-path -- \(summaries.count) summaries below threshold "
                + "(\(smallResultSetThreshold)), skipping LLM relevance judging"
            )
            return (allIds, summaries)
        }

        // Format summaries for the LLM
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

        let response = try await llmClient.completeWithUsage(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass1Model,
            maxTokens: pass1MaxTokens,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        // Record token usage
        if let usage = response.usage {
            let usageRecord = TokenUsageRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                caller: "enrichment_pass1",
                model: pass1Model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            let cost = PromptTemplates.estimateCost(
                model: pass1Model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            logger.debug("Pass 1 \(cost)")
        }

        // Parse relevant IDs from response
        let relevantIds = Self.parsePass1Response(
            response.text,
            validIds: Set(summaries.compactMap(\.id))
        )

        logger.info("Pass 1: \(summaries.count) summaries searched, \(relevantIds.count) relevant")
        return (relevantIds, summaries)
    }

    // MARK: - Path A: Fetch captures via summaries

    func fetchCapturesViaSummaries(
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

        // Fetch only the relevant summaries by ID (not all summaries)
        let relevantSummaries = try storageManager.summaries(ids: relevantSummaryIds)

        var allCaptureIds: [Int64] = []
        for summary in relevantSummaries {
            allCaptureIds.append(contentsOf: summary.decodedCaptureIds)
        }

        let captures = try storageManager.captures(ids: Array(Set(allCaptureIds)))
        logger.info(
            "Path A (summaries): \(allSummaries.count) searched, "
            + "\(relevantSummaryIds.count) relevant, "
            + "\(captures.count) captures resolved"
        )
        return SummaryPathResult(captures: captures, summariesSearched: allSummaries.count)
    }

    // MARK: - Path B: Fetch unsummarized captures

    func fetchUnsummarizedCaptures(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager
    ) throws -> [CaptureRecord] {
        let ftsResults = try storageManager.searchCaptures(
            query: query,
            limit: maxCapturesForPass2 / 2
        ).filter { !$0.isSummarized }

        let recentUnsummarized = try storageManager.unsummarizedCaptures(
            from: timeRange.start,
            to: timeRange.end,
            limit: maxCapturesForPass2 / 2
        )

        // Merge and deduplicate
        var seen = Set<Int64>()
        let merged = (ftsResults + recentUnsummarized).filter { capture in
            guard let id = capture.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }

        logger.info(
            "Path B (unsummarized): \(ftsResults.count) FTS "
            + "+ \(recentUnsummarized.count) recent "
            + "= \(merged.count) after dedup"
        )
        return merged
    }

    // MARK: - Response Parsing

    /// Strip markdown code fences from LLM output.
    static func stripCodeFences(_ text: String) -> String {
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

    static func parsePass1Response(_ response: String, validIds: Set<Int64>) -> [Int64] {
        let cleaned = stripCodeFences(response)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            DualLogger(category: "RetrievalPipeline")
                .warning("Failed to parse Pass 1 response as JSON array. Raw response:\n\(response)")
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
}
