import Foundation
import os.log

/// Default and configurable prompt templates for summarization and enrichment.
/// All templates use simple {placeholder} substitution.
enum PromptTemplates {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ContextD",
        category: "PromptTemplates"
    )

    // MARK: - Summarization

    static let summarizationSystem = """
        You summarize computer screen activity captured via OCR. The screen data \
        is organized as keyframes (full screen snapshots) and deltas (only text \
        that changed between snapshots).

        For key_topics, extract ONLY:
        - Project names (e.g., "contextd", "fp8-training", "brain-imaging-review")
        - Tool/app names ONLY if they are the focus, not just visible \
        (e.g., "Obsidian" if configuring it, NOT "Terminal" just because it was open)
        - Concepts being researched (e.g., "Monte Carlo photon transport", NOT "research")
        - People or organizations mentioned
        - Specific technologies being used (e.g., "PyTorch", "SwiftUI", NOT "code editing")

        NEVER include:
        - Generic descriptions ("Activity Monitoring", "Screen Capture", "Text Editing")
        - Variations of the same concept ("Database Stats" AND "Database Metrics")
        - The tool "contextd" itself unless the user is actively developing it
        - Obvious container apps (Terminal, Chrome, Finder, Safari) unless they are \
        the subject of the work
        - Action words as topics ("Debugging", "Browsing", "Coding", "Reading")

        Constraints:
        - Summary: 2-3 sentences maximum, under 100 words
        - Topics: 2-5 maximum. Prefer fewer, more specific topics over many vague ones
        - Exclude passwords, personal messages, financial account numbers, and \
        other sensitive data from both the summary and topics

        Respond ONLY in this JSON format (no markdown, no explanation):
        {"summary": "...", "key_topics": ["topic1", "topic2"]}
        """

    static let summarizationUser = """
        Summarize this computer activity segment:

        Time: {start_time} to {end_time}
        Duration: {duration}
        Application: {app_name}
        Window: {window_title}

        Screen activity (keyframes show full screen, deltas show only what changed):
        {ocr_samples}
        """

    // MARK: - Enrichment Pass 1: Relevance Judging

    static let enrichmentPass1System = """
        You are a relevance judge for a context enrichment system. The user has written \
        a prompt they want to send to an AI, and you need to identify which of their recent \
        computer activities are relevant to that prompt.

        The user's prompt likely references things they recently saw on their screen. Your job \
        is to find those references.

        Respond ONLY in this JSON format (no markdown, no explanation):
        [{"id": 42, "reason": "brief explanation of relevance"}, ...]

        Example -- given summaries [12], [37], [42] and a prompt about "fix the login bug":
        [{"id": 42, "reason": "Shows the login error traceback in Terminal"}, \
        {"id": 37, "reason": "Has the auth.py file open with the login handler"}]

        If nothing is relevant, respond with an empty array: []
        """

    static let enrichmentPass1User = """
        ## User's Prompt
        {query}

        ## Recent Activity Summaries
        {summaries}

        Which summaries contain information the user might be referring to or that would \
        provide useful context for their prompt?
        """

    // MARK: - Enrichment Pass 2: Context Synthesis

    static let enrichmentPass2System = """
        You are a context enrichment assistant. Given a user's prompt and detailed screen \
        captures from their recent computer activity, produce contextual references that \
        should be appended to the user's prompt to give an AI full context.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific -- include exact names, values, code snippets, etc.
        - Order by relevance (most relevant first)
        - Maximum 10 references
        - Exclude passwords, tokens, and other credentials

        Format each reference as a structured line:
        - [HH:MM, AppName - WindowTitle] Description of what was on screen...

        Respond ONLY with the reference lines under a heading, nothing else. Example:

        ## Recent Screen Context
        - [14:30, Xcode - main.swift] User was editing the processData function, adding a nil check on line 42
        - [14:25, Chrome - Stack Overflow] User was reading about async/await error handling patterns in Swift
        - [14:20, Terminal - zsh] Build failed with "cannot find type DataProcessor in scope" on line 87
        """

    static let enrichmentPass2User = """
        ## User's Prompt
        {query}

        ## Detailed Screen Activity
        {captures}

        Produce structured context references for the user's prompt.
        """

    // MARK: - Citation Pass 2 (API / structured JSON output)

    static let citationPass2System = """
        You are a context retrieval system. Given a user's query and detailed screen \
        captures from their recent computer activity, extract structured citations that \
        are relevant to the query.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific -- include exact names, values, code snippets, etc.
        - Order by relevance (most relevant first)
        - Maximum 10 citations
        - Each citation must include the timestamp, app name, and window title from the capture data
        - Exclude passwords, tokens, and other credentials from citations

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

    static let citationPass2User = """
        ## User's Query
        {query}

        ## Detailed Screen Activity
        {captures}

        Extract structured JSON citations with relevant context for the user's query.
        """

    // MARK: - Template Rendering

    /// Render a template by replacing {placeholder} tokens with values.
    ///
    /// Uses a single-pass scan to avoid double-substitution when replacement
    /// values themselves contain placeholder-like text (e.g., OCR text with "{query}").
    /// Logs a warning for any unreplaced {placeholder} tokens found after substitution.
    static func render(_ template: String, values: [String: String]) -> String {
        var result = ""
        var index = template.startIndex

        while index < template.endIndex {
            if template[index] == "{" {
                // Look for matching closing brace
                if let closeBrace = template[index...].firstIndex(of: "}") {
                    let key = String(template[template.index(after: index)..<closeBrace])
                    if let replacement = values[key] {
                        result += replacement
                        index = template.index(after: closeBrace)
                        continue
                    }
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }

        // Validate: warn about unreplaced placeholders
        let unresolved = findUnresolvedPlaceholders(result)
        if !unresolved.isEmpty {
            logger.warning(
                "Unreplaced placeholders in rendered template: \(unresolved.joined(separator: ", "))"
            )
        }

        return result
    }

    /// Scan text for {placeholder} tokens that were not substituted.
    private static func findUnresolvedPlaceholders(_ text: String) -> [String] {
        var placeholders: [String] = []
        var searchStart = text.startIndex
        while let openBrace = text.range(of: "{", range: searchStart..<text.endIndex) {
            guard let closeBrace = text.range(
                of: "}",
                range: openBrace.upperBound..<text.endIndex
            ) else {
                break
            }
            let name = String(text[openBrace.upperBound..<closeBrace.lowerBound])
            // Only flag simple identifiers (word chars), skip JSON or nested braces
            if name.range(of: #"^\w+$"#, options: .regularExpression) != nil {
                placeholders.append("{\(name)}")
            }
            searchStart = closeBrace.upperBound
        }
        return placeholders
    }
}

// MARK: - UserDefaults Keys for Custom Templates

extension PromptTemplates {
    /// UserDefaults keys for user-customized prompt templates.
    enum SettingsKey: String {
        case summarizationSystem = "prompt_summarization_system"
        case summarizationUser = "prompt_summarization_user"
        case enrichmentPass1System = "prompt_enrichment_pass1_system"
        case enrichmentPass1User = "prompt_enrichment_pass1_user"
        case enrichmentPass2System = "prompt_enrichment_pass2_system"
        case enrichmentPass2User = "prompt_enrichment_pass2_user"
        case citationPass2System = "prompt_citation_pass2_system"
        case citationPass2User = "prompt_citation_pass2_user"
    }

    /// Get a template, preferring the user's custom version from UserDefaults.
    static func template(for key: SettingsKey) -> String {
        if let custom = UserDefaults.standard.string(forKey: key.rawValue), !custom.isEmpty {
            return custom
        }
        switch key {
        case .summarizationSystem: return summarizationSystem
        case .summarizationUser: return summarizationUser
        case .enrichmentPass1System: return enrichmentPass1System
        case .enrichmentPass1User: return enrichmentPass1User
        case .enrichmentPass2System: return enrichmentPass2System
        case .enrichmentPass2User: return enrichmentPass2User
        case .citationPass2System: return citationPass2System
        case .citationPass2User: return citationPass2User
        }
    }
}

// MARK: - Model Pricing and Cost Estimation

extension PromptTemplates {
    /// Per-million-token pricing for models routed through OpenRouter.
    /// Updated 2026-03. Check https://openrouter.ai/models for current prices.
    struct ModelPricing {
        let inputPerMtok: Double
        let outputPerMtok: Double
    }

    static let pricing: [String: ModelPricing] = [
        "anthropic/claude-haiku-4-5": ModelPricing(inputPerMtok: 0.80, outputPerMtok: 4.00),
        "anthropic/claude-sonnet-4-6": ModelPricing(inputPerMtok: 3.00, outputPerMtok: 15.00),
        "anthropic/claude-opus-4-5": ModelPricing(inputPerMtok: 15.00, outputPerMtok: 75.00),
    ]

    /// Estimate the dollar cost of a single LLM call.
    /// Returns a formatted string like "$0.0023 (1,234 tok)".
    static func estimateCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> String {
        let totalTokens = inputTokens + outputTokens
        guard let price = pricing[model] else {
            return "$?.?? (\(totalTokens.formatted()) tok, unknown model)"
        }
        let cost = Double(inputTokens) / 1_000_000 * price.inputPerMtok
            + Double(outputTokens) / 1_000_000 * price.outputPerMtok
        return "$\(String(format: "%.4f", cost)) (\(totalTokens.formatted()) tok)"
    }
}
