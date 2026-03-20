import Foundation
import Hummingbird
import NIOCore

/// Embedded HTTP server for the ContextD API.
/// Runs on localhost, binding to a configurable port (default 21890).
/// Provides search, summaries, activity browsing, health check, OpenAPI spec, and interactive docs.
final class APIServer: Sendable {
    private let logger = DualLogger(category: "APIServer")
    private let storageManager: StorageManager

    /// The port the server is running on.
    let port: Int

    /// Task handle for the running server, used for shutdown.
    private let serverTask: ManagedAtomic<Task<Void, Never>?>

    /// Simple atomic wrapper since Task is not Sendable across isolation boundaries.
    final class ManagedAtomic<T>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()

        init(_ value: T) {
            self.value = value
        }

        func load() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func store(_ newValue: T) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    init(storageManager: StorageManager, port: Int = 21890) {
        self.storageManager = storageManager
        self.port = port
        self.serverTask = ManagedAtomic(nil)
    }

    /// Start the HTTP server in a background task.
    func start() {
        let task = Task { [self] in
            do {
                let router = buildRouter()
                let app = Application(
                    router: router,
                    configuration: .init(
                        address: .hostname("127.0.0.1", port: port)
                    )
                )
                logger.info("API server starting on http://127.0.0.1:\(port)")
                logger.info("  POST /v1/search    — Search summaries (FTS)")
                logger.info("  GET  /v1/summaries — List summaries by time")
                logger.info("  GET  /v1/activity  — Browse activity near timestamp")
                logger.info("  GET  /health       — Health check")
                logger.info("  GET  /openapi.json — OpenAPI spec")
                logger.info("  GET  /docs         — Interactive API docs")
                try await app.runService()
            } catch {
                if !Task.isCancelled {
                    logger.error("API server failed: \(error.localizedDescription)")
                }
            }
        }
        serverTask.store(task)
    }

    /// Stop the HTTP server.
    func stop() {
        serverTask.load()?.cancel()
        serverTask.store(nil)
        logger.info("API server stopped")
    }

    // MARK: - Router

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()

        // CORS headers for browser-based API docs
        router.addMiddleware {
            CORSMiddleware(allowOrigin: .all)
        }

        // GET /health
        let sm = storageManager
        router.get("health") { _, _ -> Response in
            let captureCount = try? sm.captureCount()
            let summaryCount = try? sm.summaryCount()

            let health = HealthResponse(
                status: "ok",
                capture_count: captureCount,
                summary_count: summaryCount
            )

            return try Self.jsonResponse(health, status: .ok)
        }

        // POST /v1/search — FTS5 search over summaries, no LLM calls
        let storage = storageManager
        let log = logger
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
                // FTS5 search over summaries
                let ftsResults = try storage.searchSummaries(query: text, limit: limit)

                // Also filter by time range if specified
                let cutoff = Date().addingTimeInterval(-Double(timeRangeMinutes * 60))
                let filtered = ftsResults.filter { $0.endDate >= cutoff }

                let isoFormatter = ISO8601DateFormatter()

                // Convert summaries to citations
                let citations: [Citation] = filtered.map { summary in
                    Citation(
                        timestamp: isoFormatter.string(from: summary.startDate),
                        app_name: summary.decodedAppNames.joined(separator: ", "),
                        window_title: nil,
                        relevant_text: summary.summary,
                        relevance_explanation: "FTS match — topics: \(summary.decodedKeyTopics.joined(separator: ", "))",
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
                        captures_examined: 0,
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

        // GET /v1/summaries?minutes=60&limit=50
        router.get("v1/summaries") { request, _ -> Response in
            let minutesParam = request.uri.queryParameters.get("minutes", as: Int.self) ?? 60
            let limitParam = request.uri.queryParameters.get("limit", as: Int.self) ?? 50

            let minutes = max(1, min(minutesParam, 1440))
            let limit = max(1, min(limitParam, 200))

            let now = Date()
            let start = now.addingTimeInterval(-Double(minutes * 60))
            let isoFormatter = ISO8601DateFormatter()

            do {
                let records = try storage.summaries(from: start, to: now, limit: limit)

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

        // GET /v1/activity?timestamp=ISO8601&window_minutes=5&kind=captures&limit=100
        router.get("v1/activity") { request, _ -> Response in
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let center: Date
            if let tsParam = request.uri.queryParameters.get("timestamp"),
               let parsed = isoFormatter.date(from: tsParam) {
                center = parsed
            } else {
                // Also try without fractional seconds
                let basicFormatter = ISO8601DateFormatter()
                if let tsParam = request.uri.queryParameters.get("timestamp"),
                   let parsed = basicFormatter.date(from: tsParam) {
                    center = parsed
                } else {
                    center = Date()
                }
            }

            let windowMinutes = max(1, min(
                request.uri.queryParameters.get("window_minutes", as: Int.self) ?? 5,
                1440
            ))
            let limit = max(1, min(
                request.uri.queryParameters.get("limit", as: Int.self) ?? 100,
                500
            ))
            let kind = request.uri.queryParameters.get("kind") ?? "captures"

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
                    let records = try storage.summaries(from: start, to: end, limit: limit)
                    items = records.map { record in
                        ActivityItem(
                            timestamp: outputFormatter.string(from: record.startDate),
                            app_name: record.decodedAppNames.joined(separator: ", "),
                            window_title: nil,
                            text: record.summary,
                            kind: "summary",
                            frame_type: nil,
                            change_percentage: nil
                        )
                    }
                } else {
                    let records = try storage.captures(from: start, to: end, limit: limit)
                    items = records.map { record in
                        ActivityItem(
                            timestamp: outputFormatter.string(from: record.date),
                            app_name: record.appName,
                            window_title: record.windowTitle,
                            text: record.fullOcrText,
                            kind: "capture",
                            frame_type: record.frameType,
                            change_percentage: record.changePercentage
                        )
                    }
                }

                let response = ActivityResponse(
                    activities: items,
                    center_timestamp: outputFormatter.string(from: center),
                    window_minutes: windowMinutes,
                    kind: kind,
                    total: items.count
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

        // GET /openapi.json
        router.get("openapi.json") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: OpenAPISpec.json))
            )
        }

        // GET /docs
        let serverPort = port
        router.get("docs") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: ScalarDocsPage.html(port: serverPort)))
            )
        }

        return router
    }

    // MARK: - Helpers

    /// Encode a Codable value to a JSON response with the given status.
    private static func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
