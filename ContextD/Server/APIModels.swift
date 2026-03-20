import Foundation

// MARK: - Request Models

/// Request body for POST /v1/search
struct SearchRequest: Codable, Sendable {
    /// The search text (used for FTS5 full-text search over summaries).
    let text: String

    /// How far back to search, in minutes. Defaults to 1440 (24 hours).
    let time_range_minutes: Int?

    /// Maximum number of results to return. Defaults to 20.
    let limit: Int?

    /// Filter results to a specific application name.
    let app_name: String?
}

// MARK: - Response Models

/// A single citation from the user's screen activity.
struct Citation: Codable, Sendable {
    /// ISO 8601 timestamp of the source capture.
    let timestamp: String

    /// Application that was active.
    let app_name: String

    /// Window title visible at the time.
    let window_title: String?

    /// The specific text/content relevant to the query.
    let relevant_text: String

    /// Why this citation is relevant to the query.
    let relevance_explanation: String

    /// Source of this citation: "capture" or "summary".
    let source: String
}

/// Metadata about how the query was processed.
struct QueryResponseMetadata: Codable, Sendable {
    /// The original query text.
    let query: String

    /// Time range searched, in minutes.
    let time_range_minutes: Int

    /// Wall-clock processing time in milliseconds.
    let processing_time_ms: Int

    /// Number of captures examined during retrieval.
    let captures_examined: Int

    /// Number of summaries searched during retrieval.
    let summaries_searched: Int
}

/// Response body for POST /v1/search
struct QueryResponse: Codable, Sendable {
    /// Array of citations from the user's recent activity.
    let citations: [Citation]

    /// Processing metadata.
    let metadata: QueryResponseMetadata
}

/// Health check response for GET /health
struct HealthResponse: Codable, Sendable {
    let status: String
    let capture_count: Int?
    let summary_count: Int?
}

// MARK: - Summaries Endpoint

/// A single activity summary.
struct SummaryItem: Codable, Sendable {
    /// ISO 8601 start of the summarized window.
    let start_timestamp: String

    /// ISO 8601 end of the summarized window.
    let end_timestamp: String

    /// Applications involved in this activity window.
    let app_names: [String]

    /// LLM-generated summary text.
    let summary: String

    /// Key topics/entities extracted from this activity.
    let key_topics: [String]
}

/// Response body for GET /v1/summaries
struct SummariesResponse: Codable, Sendable {
    let summaries: [SummaryItem]
    let time_range_minutes: Int
    let total: Int
}

// MARK: - Activity Endpoint

/// A single activity entry (either a raw capture or a summary).
struct ActivityItem: Codable, Sendable {
    /// ISO 8601 timestamp.
    let timestamp: String

    /// Application name.
    let app_name: String

    /// Window title (available for captures, nil for summaries).
    let window_title: String?

    /// The content: OCR text for captures, summary text for summaries.
    let text: String

    /// "capture" or "summary"
    let kind: String

    /// For captures: "keyframe" or "delta". Nil for summaries.
    let frame_type: String?

    /// For captures: percentage of screen that changed (0.0-1.0). Nil for summaries.
    let change_percentage: Double?
}

/// Response body for GET /v1/activity
struct ActivityResponse: Codable, Sendable {
    let activities: [ActivityItem]
    let center_timestamp: String
    let window_minutes: Int
    let kind: String
    let total: Int
}

/// Error response body.
struct APIErrorResponse: Codable, Sendable {
    let error: String
    let detail: String?
}
