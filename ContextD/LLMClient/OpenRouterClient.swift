import Foundation

/// OpenRouter API client. Hand-rolled using URLSession.
/// Supports any model available on OpenRouter via the /api/v1/chat/completions endpoint.
final class OpenRouterClient: LLMClient, Sendable {
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let logger = DualLogger(category: "OpenRouterClient")

    /// Maximum number of retry attempts for transient errors.
    private let maxRetries = 3

    // MARK: - API Key (macOS Keychain via KeychainHelper)

    private static let keychainKey = "openrouter_api_key"

    /// Path to the legacy plaintext API key file, used only for migration.
    private static var legacyAPIKeyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ContextD", isDirectory: true)
            .appendingPathComponent("api_key")
    }

    /// Migrate the API key from the legacy plaintext file to the Keychain.
    /// Deletes the plaintext file after a successful migration.
    static func migrateAPIKeyToKeychainIfNeeded() {
        // If already in Keychain, nothing to do
        guard !KeychainHelper.exists(key: keychainKey) else { return }

        // Check for legacy plaintext file
        guard let raw = try? String(contentsOf: legacyAPIKeyFileURL, encoding: .utf8) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try KeychainHelper.save(key: keychainKey, value: trimmed)
            try FileManager.default.removeItem(at: legacyAPIKeyFileURL)
        } catch {
            // Migration failed — key remains in the plaintext file for next attempt
        }
    }

    /// Read the API key from the Keychain. Returns nil if not stored.
    static func readAPIKey() -> String? {
        KeychainHelper.read(key: keychainKey)
    }

    /// Save the API key to the Keychain.
    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: keychainKey, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Delete the API key from the Keychain.
    static func deleteAPIKey() {
        KeychainHelper.delete(key: keychainKey)
    }

    /// Check whether an API key exists in the Keychain.
    static func hasAPIKey() -> Bool {
        KeychainHelper.exists(key: keychainKey)
    }

    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double
    ) async throws -> String {
        guard let apiKey = Self.readAPIKey() else {
            throw LLMError.noAPIKey
        }

        let requestBody = buildRequestBody(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature
        )

        var lastError: Error = LLMError.invalidResponse

        for attempt in 0..<maxRetries {
            do {
                let response = try await sendRequest(body: requestBody, apiKey: apiKey)
                return response
            } catch LLMError.rateLimited(let retryAfter) {
                let delay = retryAfter ?? Double(pow(2.0, Double(attempt))) // exponential backoff
                logger.warning("Rate limited, retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.rateLimited(retryAfter: retryAfter)
            } catch LLMError.httpError(let code, let body) where code >= 500 {
                let delay = Double(pow(2.0, Double(attempt)))
                logger.warning("Server error \(code), retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.httpError(statusCode: code, body: body)
            } catch {
                throw error
            }
        }

        throw lastError
    }

    // MARK: - Private

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double
    ) -> [String: Any] {
        // OpenRouter uses the OpenAI chat completions format.
        // The system prompt is a message with role "system".
        var allMessages: [[String: String]] = []

        if let system = systemPrompt {
            allMessages.append(["role": "system", "content": system])
        }

        allMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": allMessages,
        ]

        return body
    }

    func completeWithUsage(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double
    ) async throws -> LLMResponse {
        guard let apiKey = Self.readAPIKey() else {
            throw LLMError.noAPIKey
        }

        let requestBody = buildRequestBody(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature
        )

        var lastError: Error = LLMError.invalidResponse

        for attempt in 0..<maxRetries {
            do {
                let response = try await sendRequestFull(body: requestBody, apiKey: apiKey)
                return response
            } catch LLMError.rateLimited(let retryAfter) {
                let delay = retryAfter ?? Double(pow(2.0, Double(attempt)))
                logger.warning("Rate limited, retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.rateLimited(retryAfter: retryAfter)
            } catch LLMError.httpError(let code, let body) where code >= 500 {
                let delay = Double(pow(2.0, Double(attempt)))
                logger.warning("Server error \(code), retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.httpError(statusCode: code, body: body)
            } catch {
                throw error
            }
        }

        throw lastError
    }

    private func sendRequest(body: [String: Any], apiKey: String) async throws -> String {
        let response = try await sendRequestFull(body: body, apiKey: apiKey)
        return response.text
    }

    private func sendRequestFull(body: [String: Any], apiKey: String) async throws -> LLMResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        switch httpResponse.statusCode {
        case 200:
            return try parseResponseFull(data: data)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: responseBody)
        }
    }

    /// Parse an OpenAI-compatible chat completions response.
    private func parseResponseFull(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.invalidResponse
        }

        var usage: LLMTokenUsage? = nil
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["prompt_tokens"] as? Int,
           let outputTokens = usageDict["completion_tokens"] as? Int {
            usage = LLMTokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        }

        return LLMResponse(text: text, usage: usage)
    }
}
