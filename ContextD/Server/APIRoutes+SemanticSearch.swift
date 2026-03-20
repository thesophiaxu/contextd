import Foundation
import Hummingbird
import NIOCore

/// Semantic search route for the ContextD API.
/// Split into its own file to keep APIRoutes.swift under 300 lines.
extension APIServer {

    // MARK: - Semantic Search

    func registerSemanticSearchRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        let semanticService = SemanticSearchService(storageManager: storage)

        router.post("v1/semantic-search") { request, context -> Response in
            var req = request
            let body = try await req.collectBody(upTo: 1_048_576)
            guard let requestData = body.getData(at: 0, length: body.readableBytes) else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "Could not read request body"),
                    status: .badRequest
                )
            }

            let searchRequest: SemanticSearchRequest
            do {
                searchRequest = try JSONDecoder().decode(SemanticSearchRequest.self, from: requestData)
            } catch {
                return try Self.jsonResponse(
                    APIErrorResponse(
                        error: "invalid_request",
                        detail: "Invalid JSON: \(error.localizedDescription)"
                    ),
                    status: .badRequest
                )
            }

            let query = searchRequest.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "\"query\" field must be non-empty"),
                    status: .badRequest
                )
            }

            let limit = min(searchRequest.limit ?? 10, 100)
            let timeRangeMinutes = searchRequest.time_range_minutes ?? 1440
            let startTime = Date()

            do {
                let cutoff = Date().addingTimeInterval(-Double(timeRangeMinutes * 60))
                let now = Date()

                let results = try semanticService.search(
                    query: query,
                    from: cutoff,
                    to: now,
                    limit: limit
                )

                let isoFormatter = ISO8601DateFormatter()
                let items: [SemanticSearchResult] = results.map { (record, similarity) in
                    SemanticSearchResult(
                        summary: SummaryItem(
                            start_timestamp: isoFormatter.string(from: record.startDate),
                            end_timestamp: isoFormatter.string(from: record.endDate),
                            app_names: record.decodedAppNames,
                            summary: record.summary,
                            key_topics: record.decodedKeyTopics
                        ),
                        similarity: Double(similarity)
                    )
                }

                let processingTime = Date().timeIntervalSince(startTime)
                let response = SemanticSearchResponse(
                    results: items,
                    metadata: SemanticSearchMetadata(
                        query: query,
                        time_range_minutes: timeRangeMinutes,
                        processing_time_ms: Int(processingTime * 1000),
                        summaries_compared: results.count
                    )
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Semantic search failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "semantic_search_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }
}
