import Foundation
import GRDB

/// Database record for tracking LLM token usage per API call.
struct TokenUsageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// Auto-incremented primary key
    var id: Int64?

    /// Unix timestamp of the API call
    var timestamp: Double

    /// Which caller produced this usage (e.g. "summarizer", "enrichment_pass1")
    var caller: String

    /// Model used for the call
    var model: String

    /// Number of input tokens consumed
    var inputTokens: Int

    /// Number of output tokens consumed
    var outputTokens: Int

    // MARK: - Table mapping

    static let databaseTableName = "token_usage"

    enum Columns: String, ColumnExpression {
        case id, timestamp, caller, model, inputTokens, outputTokens
    }

    // MARK: - Record lifecycle

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Aggregated usage

/// Aggregated token usage totals.
struct TokenUsageTotals: Sendable {
    let inputTokens: Int64
    let outputTokens: Int64

    /// Input tokens in millions (Mtok).
    var inputMtok: Double {
        Double(inputTokens) / 1_000_000.0
    }

    /// Output tokens in millions (Mtok).
    var outputMtok: Double {
        Double(outputTokens) / 1_000_000.0
    }
}
