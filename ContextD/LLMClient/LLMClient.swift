import Foundation

/// A message in a conversation with an LLM.
struct LLMMessage: Sendable {
    let role: String  // "user" or "assistant"
    let content: String
}

/// Token usage reported by the LLM API.
struct LLMTokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

/// Full response from an LLM completion, including token usage.
struct LLMResponse: Sendable {
    let text: String
    let usage: LLMTokenUsage?
}

/// Protocol for LLM API clients.
/// Implementations handle authentication, request formatting, and response parsing.
protocol LLMClient: Sendable {
    /// Send a completion request to the LLM.
    /// - Parameters:
    ///   - messages: The conversation messages.
    ///   - model: The model identifier (e.g., "anthropic/claude-haiku-4-5").
    ///   - maxTokens: Maximum tokens in the response.
    ///   - systemPrompt: Optional system prompt.
    ///   - temperature: Sampling temperature (0.0 = deterministic).
    ///   - responseFormat: Optional response format (e.g., "json_object").
    /// - Returns: The LLM's response text.
    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> String

    /// Send a completion request and return the full response including token usage.
    func completeWithUsage(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> LLMResponse
}

/// Default parameter values.
extension LLMClient {
    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int = 4096,
        systemPrompt: String? = nil,
        temperature: Double = 0.0,
        responseFormat: String? = nil
    ) async throws -> String {
        try await complete(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature,
            responseFormat: responseFormat
        )
    }

    func completeWithUsage(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int = 4096,
        systemPrompt: String? = nil,
        temperature: Double = 0.0,
        responseFormat: String? = nil
    ) async throws -> LLMResponse {
        try await completeWithUsage(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature,
            responseFormat: responseFormat
        )
    }
}

/// Errors from the LLM client.
enum LLMError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case rateLimited(retryAfter: TimeInterval?)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Please add your OpenRouter API key in Settings."
        case .invalidResponse:
            return "Invalid response from the LLM API."
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds."
            }
            return "Rate limited. Please try again later."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
