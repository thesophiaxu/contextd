import Foundation
import Hummingbird
import NIOCore

/// Route registration for the ContextD API.
/// Split from APIServer to keep files under 300 lines.
extension APIServer {

    /// Register all API routes on the given router.
    func registerRoutes(on router: Router<BasicRequestContext>) {
        let storage = storageManager
        let log = logger

        registerHealthRoute(on: router, storage: storage)
        registerSearchRoute(on: router, storage: storage, log: log)
        registerSemanticSearchRoute(on: router, storage: storage, log: log)
        registerSummariesRoute(on: router, storage: storage, log: log)
        registerActivityRoute(on: router, storage: storage, log: log)
        registerDocsRoutes(on: router)
    }

    // MARK: - Health

    private func registerHealthRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager
    ) {
        router.get("health") { _, _ -> Response in
            let captureCount = try? storage.captureCount()
            let summaryCount = try? storage.summaryCount()
            let health = HealthResponse(
                status: "ok",
                capture_count: captureCount,
                summary_count: summaryCount
            )
            return try Self.jsonResponse(health, status: .ok)
        }
    }

    // MARK: - Search

    private func registerSearchRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.post("v1/search") { request, context -> Response in
            var req = request
            let body = try await req.collectBody(upTo: 1_048_576)
            guard let requestData = body.getData(at: 0, length: body.readableBytes) else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "Could not read request body"),
                    status: .badRequest
                )
            }

            let searchRequest: SearchRequest
            do {
                searchRequest = try JSONDecoder().decode(SearchRequest.self, from: requestData)
            } catch {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "Invalid JSON: \(error.localizedDescription)"),
                    status: .badRequest
                )
            }

            let text = searchRequest.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "\"text\" field must be non-empty"),
                    status: .badRequest
                )
            }

            let limit = min(searchRequest.limit ?? 20, 100)
            let timeRangeMinutes = searchRequest.time_range_minutes ?? 1440
            let startTime = Date()

            do {
                // Time range cutoff applied in SQL, before LIMIT
                let cutoff = Date().addingTimeInterval(-Double(timeRangeMinutes * 60))

                // FTS5 search with time filter in the query
                let ftsResults = try storage.searchSummaries(
                    query: text, limit: limit, from: cutoff
                )

                // Count captures covered by matched summaries
                let capturesExamined = ftsResults.reduce(0) { total, summary in
                    total + summary.decodedCaptureIds.count
                }

                let isoFormatter = ISO8601DateFormatter()
                let citations: [Citation] = ftsResults.map { summary in
                    Citation(
                        timestamp: isoFormatter.string(from: summary.startDate),
                        app_name: summary.decodedAppNames.joined(separator: ", "),
                        window_title: nil,
                        relevant_text: summary.summary,
                        relevance_explanation: "FTS match - topics: \(summary.decodedKeyTopics.joined(separator: ", "))",
                        source: "summary"
                    )
                }

                let processingTime = Date().timeIntervalSince(startTime)
                let queryResponse = QueryResponse(
                    citations: citations,
                    metadata: QueryResponseMetadata(
                        query: text,
                        time_range_minutes: timeRangeMinutes,
                        processing_time_ms: Int(processingTime * 1000),
                        captures_examined: capturesExamined,
                        summaries_searched: ftsResults.count
                    )
                )
                return try Self.jsonResponse(queryResponse, status: .ok)
            } catch {
                log.error("Search failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "search_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - Summaries

    private func registerSummariesRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/summaries") { request, _ -> Response in
            let minutesParam = request.uri.queryParameters.get("minutes", as: Int.self) ?? 60
            let limitParam = request.uri.queryParameters.get("limit", as: Int.self) ?? 50
            let offsetParam = request.uri.queryParameters.get("offset", as: Int.self) ?? 0
            let appNameParam = request.uri.queryParameters.get("app_name")

            let minutes = max(1, min(minutesParam, 1440))
            let limit = max(1, min(limitParam, 200))
            let offset = max(0, offsetParam)

            let now = Date()
            let start = now.addingTimeInterval(-Double(minutes * 60))
            let isoFormatter = ISO8601DateFormatter()

            do {
                let records = try storage.summaries(
                    from: start, to: now, limit: limit,
                    offset: offset, appName: appNameParam
                )
                let items: [SummaryItem] = records.map { record in
                    SummaryItem(
                        start_timestamp: isoFormatter.string(from: record.startDate),
                        end_timestamp: isoFormatter.string(from: record.endDate),
                        app_names: record.decodedAppNames,
                        summary: record.summary,
                        key_topics: record.decodedKeyTopics
                    )
                }
                let response = SummariesResponse(
                    summaries: items,
                    time_range_minutes: minutes,
                    total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Summaries failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "summaries_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - Activity

    private func registerActivityRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/activity") { request, _ -> Response in
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let center: Date
            if let tsParam = request.uri.queryParameters.get("timestamp"),
               let parsed = isoFormatter.date(from: tsParam) {
                center = parsed
            } else {
                let basicFormatter = ISO8601DateFormatter()
                if let tsParam = request.uri.queryParameters.get("timestamp"),
                   let parsed = basicFormatter.date(from: tsParam) {
                    center = parsed
                } else {
                    center = Date()
                }
            }

            let windowMinutes = max(1, min(
                request.uri.queryParameters.get("window_minutes", as: Int.self) ?? 5, 1440
            ))
            let limit = max(1, min(
                request.uri.queryParameters.get("limit", as: Int.self) ?? 100, 500
            ))
            let offsetParam = request.uri.queryParameters.get("offset", as: Int.self) ?? 0
            let offset = max(0, offsetParam)
            let kind = request.uri.queryParameters.get("kind") ?? "captures"
            let appNameParam = request.uri.queryParameters.get("app_name")

            guard kind == "captures" || kind == "summaries" else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "\"kind\" must be \"captures\" or \"summaries\""),
                    status: .badRequest
                )
            }

            let halfWindow = Double(windowMinutes * 60) / 2.0
            let start = center.addingTimeInterval(-halfWindow)
            let end = center.addingTimeInterval(halfWindow)
            let outputFormatter = ISO8601DateFormatter()

            do {
                let items: [ActivityItem]
                if kind == "summaries" {
                    let records = try storage.summaries(
                        from: start, to: end, limit: limit,
                        offset: offset, appName: appNameParam
                    )
                    items = records.map { record in
                        ActivityItem(
                            timestamp: outputFormatter.string(from: record.startDate),
                            app_name: record.decodedAppNames.joined(separator: ", "),
                            window_title: nil, text: record.summary,
                            kind: "summary", frame_type: nil, change_percentage: nil
                        )
                    }
                } else {
                    let records = try storage.captures(
                        from: start, to: end, limit: limit,
                        offset: offset, appName: appNameParam
                    )
                    items = records.map { record in
                        ActivityItem(
                            timestamp: outputFormatter.string(from: record.date),
                            app_name: record.appName,
                            window_title: record.windowTitle, text: record.fullOcrText,
                            kind: "capture", frame_type: record.frameType,
                            change_percentage: record.changePercentage
                        )
                    }
                }

                let response = ActivityResponse(
                    activities: items,
                    center_timestamp: outputFormatter.string(from: center),
                    window_minutes: windowMinutes, kind: kind, total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Activity failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "activity_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - Docs & OpenAPI

    private func registerDocsRoutes(on router: Router<BasicRequestContext>) {
        router.get("openapi.json") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: OpenAPISpec.json))
            )
        }

        let serverPort = port
        router.get("docs") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: ScalarDocsPage.html(port: serverPort)))
            )
        }
    }
}
