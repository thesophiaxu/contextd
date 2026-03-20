import Foundation
import Hummingbird
import NIOCore

// MARK: - Auth Token Management

/// Manages a bearer token for API authentication.
/// Generates a random token at startup and writes it to
/// ~/.config/contextd/auth_token with mode 0600.
enum AuthTokenManager {
    /// The generated auth token for this process lifetime.
    static let token: String = {
        let token = generateToken()
        writeTokenFile(token)
        return token
    }()

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeTokenFile(_ token: String) {
        let logger = DualLogger(category: "AuthToken")
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/contextd")
        let tokenFile = configDir.appendingPathComponent("auth_token")

        do {
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true
            )
            try token.write(to: tokenFile, atomically: true, encoding: .utf8)
            // Set file permissions to 0600 (owner read/write only)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenFile.path
            )
            logger.info("Auth token written to \(tokenFile.path)")
        } catch {
            logger.error("Failed to write auth token: \(error.localizedDescription)")
        }
    }
}

// MARK: - Bearer Auth Middleware

/// Middleware that checks Authorization: Bearer <token> on protected routes.
/// /health is unauthenticated. All /v1/ and /docs routes require the token.
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(
        _ input: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let path = input.uri.path

        // /health is unauthenticated
        if path == "/health" {
            return try await next(input, context)
        }

        // All other routes require auth
        let authHeader = input.headers[.authorization]
        guard let authHeader, authHeader == "Bearer \(token)" else {
            let error = APIErrorResponse(
                error: "unauthorized",
                detail: "Missing or invalid Authorization: Bearer <token> header"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(error)
            return Response(
                status: .unauthorized,
                headers: [
                    .contentType: "application/json",
                    .wwwAuthenticate: "Bearer",
                ],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        return try await next(input, context)
    }
}

// MARK: - Request Logging Middleware

/// Logs method, path, status code, and response time for every request.
struct RequestLoggingMiddleware<Context: RequestContext>: RouterMiddleware {
    private let logger = DualLogger(category: "HTTP")

    func handle(
        _ input: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let start = ContinuousClock.now
        let method = input.method.rawValue
        let path = input.uri.path

        do {
            let response = try await next(input, context)
            let elapsed = ContinuousClock.now - start
            let ms = elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            logger.info("\(method) \(path) -> \(response.status.code) (\(ms)ms)")
            return response
        } catch {
            let elapsed = ContinuousClock.now - start
            let ms = elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            logger.error("\(method) \(path) -> ERROR (\(ms)ms): \(error.localizedDescription)")
            throw error
        }
    }
}
