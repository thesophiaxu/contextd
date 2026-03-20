import Foundation
import GRDB

/// Provides high-level query and storage operations over the database.
/// Thread-safe: all operations go through GRDB's DatabasePool.
/// Keyframe grouping, token usage, cleanup, and stats are in
/// StorageManager+Extensions.swift.
final class StorageManager: Sendable {
    let database: AppDatabase
    private let logger = DualLogger(category: "Storage")

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Insert

    /// Insert a new capture record from a CaptureFrame.
    @discardableResult
    func insertCapture(_ frame: CaptureFrame) throws -> CaptureRecord {
        var record = CaptureRecord(frame: frame)
        try database.dbPool.write { db in
            try record.insert(db)
        }
        logger.debug("Inserted capture id=\(record.id ?? -1) app=\(frame.appName)")
        return record
    }

    /// Insert a new summary record.
    @discardableResult
    func insertSummary(_ summary: SummaryRecord) throws -> SummaryRecord {
        var record = summary
        try database.dbPool.write { db in
            try record.insert(db)
        }
        logger.debug("Inserted summary id=\(record.id ?? -1)")
        return record
    }

    // MARK: - Queries

    /// Get the most recent capture's text hash for deduplication.
    func lastCaptureTextHash() throws -> String? {
        try database.dbPool.read { db in
            try CaptureRecord
                .order(CaptureRecord.Columns.timestamp.desc)
                .limit(1)
                .fetchOne(db)?
                .textHash
        }
    }

    /// Fetch captures in a time range, with optional pagination and app filtering.
    func captures(
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil,
        offset: Int = 0,
        appName: String? = nil
    ) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            var query = CaptureRecord
                .filter(CaptureRecord.Columns.timestamp >= startDate.timeIntervalSince1970)
                .filter(CaptureRecord.Columns.timestamp <= endDate.timeIntervalSince1970)
                .order(CaptureRecord.Columns.timestamp.desc)

            if let appName = appName, !appName.isEmpty {
                query = query.filter(CaptureRecord.Columns.appName == appName)
            }

            if let limit = limit {
                query = query.limit(limit, offset: offset)
            } else if offset > 0 {
                query = query.limit(-1, offset: offset)
            }

            return try query.fetchAll(db)
        }
    }

    /// Fetch captures by their IDs.
    func captures(ids: [Int64]) throws -> [CaptureRecord] {
        guard !ids.isEmpty else { return [] }
        return try database.dbPool.read { db in
            try CaptureRecord
                .filter(ids.contains(CaptureRecord.Columns.id))
                .order(CaptureRecord.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    /// Fetch unsummarized captures older than a given age, for progressive summarization.
    func unsummarizedCaptures(olderThan age: TimeInterval = 300, limit: Int = 500) throws -> [CaptureRecord] {
        let cutoff = Date().timeIntervalSince1970 - age
        return try database.dbPool.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.isSummarized == false)
                .filter(CaptureRecord.Columns.timestamp <= cutoff)
                .order(CaptureRecord.Columns.timestamp.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fetch unsummarized captures within a time range, ordered by timestamp descending.
    func unsummarizedCaptures(from startDate: Date, to endDate: Date, limit: Int = 500) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.isSummarized == false)
                .filter(CaptureRecord.Columns.timestamp >= startDate.timeIntervalSince1970)
                .filter(CaptureRecord.Columns.timestamp <= endDate.timeIntervalSince1970)
                .order(CaptureRecord.Columns.timestamp.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Mark captures as summarized using parameterized queries.
    func markCapturesAsSummarized(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try database.dbPool.write { db in
            try CaptureRecord
                .filter(ids.contains(CaptureRecord.Columns.id))
                .updateAll(db, CaptureRecord.Columns.isSummarized.set(to: true))
        }
    }

    // MARK: - Summaries

    /// Fetch summaries in a time range, with optional pagination and app filtering.
    func summaries(
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil,
        offset: Int = 0,
        appName: String? = nil
    ) throws -> [SummaryRecord] {
        try database.dbPool.read { db in
            if let appName = appName, !appName.isEmpty {
                // Use raw SQL for JSON LIKE filtering on appNames
                var sql = """
                    SELECT * FROM summaries
                    WHERE endTimestamp >= ?
                      AND startTimestamp <= ?
                      AND appNames LIKE ?
                    ORDER BY startTimestamp DESC
                    """
                var args: [DatabaseValueConvertible] = [
                    startDate.timeIntervalSince1970,
                    endDate.timeIntervalSince1970,
                    "%\(appName)%",
                ]
                if let limit = limit {
                    sql += "\nLIMIT ? OFFSET ?"
                    args.append(limit)
                    args.append(offset)
                } else if offset > 0 {
                    sql += "\nLIMIT -1 OFFSET ?"
                    args.append(offset)
                }
                return try SummaryRecord.fetchAll(
                    db, sql: sql, arguments: StatementArguments(args)
                )
            }

            var query = SummaryRecord
                .filter(SummaryRecord.Columns.endTimestamp >= startDate.timeIntervalSince1970)
                .filter(SummaryRecord.Columns.startTimestamp <= endDate.timeIntervalSince1970)
                .order(SummaryRecord.Columns.startTimestamp.desc)

            if let limit = limit {
                query = query.limit(limit, offset: offset)
            } else if offset > 0 {
                query = query.limit(-1, offset: offset)
            }

            return try query.fetchAll(db)
        }
    }

    /// Fetch summaries by their IDs.
    func summaries(ids: [Int64]) throws -> [SummaryRecord] {
        guard !ids.isEmpty else { return [] }
        return try database.dbPool.read { db in
            try SummaryRecord
                .filter(ids.contains(SummaryRecord.Columns.id))
                .order(SummaryRecord.Columns.startTimestamp.desc)
                .fetchAll(db)
        }
    }

    /// Fetch the most recent summaries.
    func recentSummaries(limit: Int = 20) throws -> [SummaryRecord] {
        try database.dbPool.read { db in
            try SummaryRecord
                .order(SummaryRecord.Columns.endTimestamp.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Full-Text Search

    /// Search captures using FTS5 full-text search.
    func searchCaptures(query: String, limit: Int = 50) throws -> [CaptureRecord] {
        let ftsQuery = sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try database.dbPool.read { db in
            let sql = """
                SELECT captures.*
                FROM captures
                JOIN captures_fts ON captures.id = captures_fts.rowid
                WHERE captures_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try CaptureRecord.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
        }
    }

    /// Search summaries via FTS5, with optional time and app filtering applied in SQL.
    func searchSummaries(
        query: String,
        limit: Int = 20,
        from: Date? = nil,
        appName: String? = nil
    ) throws -> [SummaryRecord] {
        let ftsQuery = sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try database.dbPool.read { db in
            var sql = """
                SELECT summaries.*
                FROM summaries
                JOIN summaries_fts ON summaries.id = summaries_fts.rowid
                WHERE summaries_fts MATCH ?
                """
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let from = from {
                sql += "\n    AND summaries.endTimestamp >= ?"
                arguments.append(from.timeIntervalSince1970)
            }

            if let appName = appName, !appName.isEmpty {
                sql += "\n    AND summaries.appNames LIKE ?"
                arguments.append("%\(appName)%")
            }

            sql += "\nORDER BY rank\nLIMIT ?"
            arguments.append(limit)

            return try SummaryRecord.fetchAll(
                db, sql: sql, arguments: StatementArguments(arguments)
            )
        }
    }

    // MARK: - Helpers

    /// Sanitize a user query string for FTS5 matching.
    /// Wraps each word in quotes to prevent FTS5 syntax errors.
    /// Uses AND semantics (FTS5 default implicit AND when words are space-separated).
    func sanitizeFTSQuery(_ query: String) -> String {
        // FTS5 special characters and operators that need escaping
        let ftsOperators: Set<String> = ["AND", "OR", "NOT", "NEAR"]

        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .compactMap { word -> String? in
                // Skip bare FTS5 boolean operators
                if ftsOperators.contains(word.uppercased()) {
                    return nil
                }
                // Strip quotes, asterisks, carets, parentheses, hyphens at start
                var cleaned = word
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "^", with: "")
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                // Remove leading minus (FTS5 NOT prefix)
                while cleaned.hasPrefix("-") {
                    cleaned = String(cleaned.dropFirst())
                }
                guard !cleaned.isEmpty else { return nil }
                return "\"\(cleaned)\""
            }
        // Space-separated quoted terms use FTS5 implicit AND
        return words.joined(separator: " ")
    }
}
