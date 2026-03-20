import Foundation
import GRDB

/// A keyframe and its associated delta frames, in chronological order.
struct KeyframeGroup: Sendable {
    let keyframe: CaptureRecord
    let deltas: [CaptureRecord]

    /// All captures in chronological order (keyframe first, then deltas).
    var allCaptures: [CaptureRecord] { [keyframe] + deltas }

    /// Total number of captures in this group.
    var count: Int { 1 + deltas.count }
}

/// Provides high-level query and storage operations over the database.
/// Thread-safe: all operations go through GRDB's DatabasePool.
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

    /// Fetch captures within a time range, ordered by timestamp descending.
    func captures(from startDate: Date, to endDate: Date, limit: Int? = nil) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            var query = CaptureRecord
                .filter(CaptureRecord.Columns.timestamp >= startDate.timeIntervalSince1970)
                .filter(CaptureRecord.Columns.timestamp <= endDate.timeIntervalSince1970)
                .order(CaptureRecord.Columns.timestamp.desc)

            if let limit = limit {
                query = query.limit(limit)
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

    /// Mark captures as summarized.
    func markCapturesAsSummarized(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE captures SET isSummarized = 1 WHERE id IN (\(ids.map { "\($0)" }.joined(separator: ",")))"
            )
        }
    }

    // MARK: - Summaries

    /// Fetch summaries within a time range.
    func summaries(from startDate: Date, to endDate: Date, limit: Int? = nil) throws -> [SummaryRecord] {
        try database.dbPool.read { db in
            var query = SummaryRecord
                .filter(SummaryRecord.Columns.endTimestamp >= startDate.timeIntervalSince1970)
                .filter(SummaryRecord.Columns.startTimestamp <= endDate.timeIntervalSince1970)
                .order(SummaryRecord.Columns.startTimestamp.desc)

            if let limit = limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db)
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

    /// Search summaries using FTS5 full-text search.
    /// Time filter and app_name filter are applied in SQL BEFORE the LIMIT so
    /// pagination (offset) returns correct results.
    func searchSummaries(
        query: String,
        limit: Int = 20,
        timeRangeMinutes: Int? = nil,
        appName: String? = nil
    ) throws -> [SummaryRecord] {
        let ftsQuery = sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try database.dbPool.read { db in
            var conditions = ["summaries_fts MATCH ?"]
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let minutes = timeRangeMinutes {
                let cutoff = Date().addingTimeInterval(-Double(minutes * 60)).timeIntervalSince1970
                conditions.append("summaries.endTimestamp >= ?")
                arguments.append(cutoff)
            }

            if let app = appName, !app.isEmpty {
                // appNames is a JSON array string; use LIKE for substring match
                conditions.append("summaries.appNames LIKE ?")
                arguments.append("%\(app)%")
            }

            let whereClause = conditions.joined(separator: " AND ")
            arguments.append(limit)

            let sql = """
                SELECT summaries.*
                FROM summaries
                JOIN summaries_fts ON summaries.id = summaries_fts.rowid
                WHERE \(whereClause)
                ORDER BY rank
                LIMIT ?
                """
            return try SummaryRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Keyframe/Delta Queries

    /// Fetch the most recent keyframe.
    func lastKeyframe() throws -> CaptureRecord? {
        try database.dbPool.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.frameType == "keyframe")
                .order(CaptureRecord.Columns.timestamp.desc)
                .limit(1)
                .fetchOne(db)
        }
    }

    /// Fetch only keyframes in a time range.
    func keyframes(from startDate: Date, to endDate: Date, limit: Int? = nil) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            var query = CaptureRecord
                .filter(CaptureRecord.Columns.frameType == "keyframe")
                .filter(CaptureRecord.Columns.timestamp >= startDate.timeIntervalSince1970)
                .filter(CaptureRecord.Columns.timestamp <= endDate.timeIntervalSince1970)
                .order(CaptureRecord.Columns.timestamp.desc)

            if let limit = limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db)
        }
    }

    /// Fetch all deltas belonging to a specific keyframe.
    func deltasForKeyframe(id: Int64) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.keyframeId == id)
                .order(CaptureRecord.Columns.timestamp.asc)
                .fetchAll(db)
        }
    }

    /// Fetch captures in a time range, grouped into keyframe->delta sequences.
    /// Returns an ordered array of KeyframeGroup, each containing a keyframe
    /// and its subsequent deltas.
    func captureGroups(from startDate: Date, to endDate: Date, limit: Int? = nil) throws -> [KeyframeGroup] {
        // Fetch all captures in range ordered by timestamp ASC
        let allCaptures = try database.dbPool.read { db in
            var query = CaptureRecord
                .filter(CaptureRecord.Columns.timestamp >= startDate.timeIntervalSince1970)
                .filter(CaptureRecord.Columns.timestamp <= endDate.timeIntervalSince1970)
                .order(CaptureRecord.Columns.timestamp.asc)

            if let limit = limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db)
        }

        guard !allCaptures.isEmpty else { return [] }

        var groups: [KeyframeGroup] = []
        var currentKeyframe: CaptureRecord?
        var currentDeltas: [CaptureRecord] = []

        for capture in allCaptures {
            if capture.isKeyframe {
                // Close previous group if exists
                if let kf = currentKeyframe {
                    groups.append(KeyframeGroup(keyframe: kf, deltas: currentDeltas))
                }
                currentKeyframe = capture
                currentDeltas = []
            } else {
                // Delta frame
                if currentKeyframe != nil {
                    currentDeltas.append(capture)
                } else {
                    // Range starts mid-sequence — try to fetch the preceding keyframe
                    if let kfId = capture.keyframeId {
                        let precedingKF = try database.dbPool.read { db in
                            try CaptureRecord
                                .filter(CaptureRecord.Columns.id == kfId)
                                .fetchOne(db)
                        }
                        if let kf = precedingKF {
                            currentKeyframe = kf
                            currentDeltas = [capture]
                        } else {
                            // Keyframe was pruned — treat delta as standalone
                            // It has fullOcrText, so it's self-contained
                            groups.append(KeyframeGroup(keyframe: capture, deltas: []))
                        }
                    } else {
                        // Orphaned delta with no keyframeId — standalone
                        groups.append(KeyframeGroup(keyframe: capture, deltas: []))
                    }
                }
            }
        }

        // Close the last group
        if let kf = currentKeyframe {
            groups.append(KeyframeGroup(keyframe: kf, deltas: currentDeltas))
        }

        return groups
    }

    // MARK: - Token Usage

    /// Insert a token usage record.
    @discardableResult
    func insertTokenUsage(_ record: TokenUsageRecord) throws -> TokenUsageRecord {
        var record = record
        try database.dbPool.write { db in
            try record.insert(db)
        }
        return record
    }

    /// Get aggregated token usage for a caller within the last N seconds.
    func tokenUsageTotals(caller: String, withinLast seconds: TimeInterval = 86400) throws -> TokenUsageTotals {
        let cutoff = Date().timeIntervalSince1970 - seconds
        return try database.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(inputTokens), 0) AS totalInput,
                       COALESCE(SUM(outputTokens), 0) AS totalOutput
                FROM token_usage
                WHERE caller = ? AND timestamp >= ?
                """, arguments: [caller, cutoff])
            let totalInput = row?["totalInput"] as? Int64 ?? 0
            let totalOutput = row?["totalOutput"] as? Int64 ?? 0
            return TokenUsageTotals(inputTokens: totalInput, outputTokens: totalOutput)
        }
    }

    /// Delete token usage records older than the given number of days.
    func pruneOldTokenUsage(olderThanDays days: Int = 7) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - Double(days * 86400)
        return try database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM token_usage WHERE timestamp < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    // MARK: - Cleanup

    /// Delete captures older than the given number of days.
    func pruneOldCaptures(olderThanDays days: Int = 7) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - Double(days * 86400)
        return try database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM captures WHERE timestamp < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    /// Delete summaries older than the given number of days.
    func pruneOldSummaries(olderThanDays days: Int = 7) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - Double(days * 86400)
        return try database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM summaries WHERE endTimestamp < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    /// Get the total number of captures in the database.
    func captureCount() throws -> Int {
        try database.dbPool.read { db in
            try CaptureRecord.fetchCount(db)
        }
    }

    /// Get the total number of summaries in the database.
    func summaryCount() throws -> Int {
        try database.dbPool.read { db in
            try SummaryRecord.fetchCount(db)
        }
    }

    /// Get the database file size in bytes.
    func databaseSizeBytes() throws -> Int64 {
        let path = database.dbPool.path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return attrs[.size] as? Int64 ?? 0
    }

    // MARK: - Helpers

    /// Sanitize a user query string for FTS5 matching.
    /// Wraps each word in quotes and joins with AND so all terms must match.
    private func sanitizeFTSQuery(_ query: String) -> String {
        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { word in
                // Remove any existing quotes and wrap in quotes for safety
                let cleaned = word.replacingOccurrences(of: "\"", with: "")
                return "\"\(cleaned)\""
            }
        return words.joined(separator: " AND ")
    }
}
