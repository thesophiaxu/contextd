import Foundation
import Hummingbird
import NIOCore

/// Embedded HTTP server for the ContextD API.
/// Runs on localhost, binding to a configurable port (default 21890).
/// Provides search, summaries, activity browsing, health check, OpenAPI spec,
/// and interactive docs. All routes except /health require bearer token auth.
final class APIServer: Sendable {
    let logger = DualLogger(category: "APIServer")
    let storageManager: StorageManager

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
                logger.info("  Auth token: ~/.config/contextd/auth_token")
                logger.info("  POST /v1/search          - Search summaries (FTS)")
                logger.info("  POST /v1/semantic-search - Semantic similarity search")
                logger.info("  GET  /v1/summaries       - List summaries by time")
                logger.info("  GET  /v1/activity        - Browse activity near timestamp")
                logger.info("  GET  /health       - Health check (no auth)")
                logger.info("  GET  /openapi.json - OpenAPI spec")
                logger.info("  GET  /docs         - Interactive API docs")
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

        // CORS: localhost-only API, no cross-origin access needed
        router.addMiddleware {
            CORSMiddleware(allowOrigin: .none)
        }

        // Request logging (method, path, status, response time)
        router.addMiddleware {
            RequestLoggingMiddleware()
        }

        // Bearer token auth on all routes except /health
        let authToken = AuthTokenManager.token
        router.addMiddleware {
            BearerAuthMiddleware(token: authToken)
        }

        // Register all route handlers (defined in APIRoutes.swift)
        registerRoutes(on: router)

        return router
    }

    // MARK: - Helpers

    /// Encode a Codable value to a JSON response with the given status.
    static func jsonResponse<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status
    ) throws -> Response {
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
