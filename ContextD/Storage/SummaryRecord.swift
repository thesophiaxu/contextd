import Foundation
import GRDB

/// Database record for a progressive summary covering a chunk of captures.
struct SummaryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// Auto-incremented primary key
    var id: Int64?

    /// Start of the time window (Unix timestamp)
    var startTimestamp: Double

    /// End of the time window (Unix timestamp)
    var endTimestamp: Double

    /// JSON array of app names involved in this chunk
    var appNames: String?

    /// LLM-generated summary text
    var summary: String

    /// JSON array of key topics/entities extracted by the LLM
    var keyTopics: String?

    /// JSON array of capture IDs covered by this summary
    var captureIds: String

    /// TF-IDF vector stored as serialized Float BLOB.
    /// Nullable: existing summaries are backfilled lazily on first search.
    var embedding: Data?

    // MARK: - Table mapping

    static let databaseTableName = "summaries"

    enum Columns: String, ColumnExpression {
        case id, startTimestamp, endTimestamp, appNames
        case summary, keyTopics, captureIds, embedding
    }

    // MARK: - Record lifecycle

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Convenience accessors

extension SummaryRecord {
    /// Decode the capture IDs JSON to an array of Int64.
    var decodedCaptureIds: [Int64] {
        guard let data = captureIds.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else {
            return []
        }
        return ids
    }

    /// Decode the app names JSON to an array of strings.
    var decodedAppNames: [String] {
        guard let json = appNames,
              let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names
    }

    /// Decode the key topics JSON to an array of strings.
    var decodedKeyTopics: [String] {
        guard let json = keyTopics,
              let data = json.data(using: .utf8),
              let topics = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return topics
    }

    /// Start date
    var startDate: Date {
        Date(timeIntervalSince1970: startTimestamp)
    }

    /// End date
    var endDate: Date {
        Date(timeIntervalSince1970: endTimestamp)
    }
}
