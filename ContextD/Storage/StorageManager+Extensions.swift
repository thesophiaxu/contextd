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

// MARK: - Keyframe/Delta Queries, Token Usage, Cleanup, Stats

extension StorageManager {

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

        // Batch-fetch preceding keyframes for orphaned deltas at the start
        // of the range. Avoids N+1 queries when the window begins mid-sequence.
        let orphanedKFIds = collectOrphanedKeyframeIds(allCaptures)
        let prefetchedKeyframes = try batchFetchKeyframes(ids: orphanedKFIds)

        var groups: [KeyframeGroup] = []
        var currentKeyframe: CaptureRecord?
        var currentDeltas: [CaptureRecord] = []

        for capture in allCaptures {
            if capture.isKeyframe {
                if let kf = currentKeyframe {
                    groups.append(KeyframeGroup(keyframe: kf, deltas: currentDeltas))
                }
                currentKeyframe = capture
                currentDeltas = []
            } else {
                if currentKeyframe != nil {
                    currentDeltas.append(capture)
                } else {
                    // Range starts mid-sequence -- use prefetched keyframe lookup
                    if let kfId = capture.keyframeId,
                       let kf = prefetchedKeyframes[kfId] {
                        currentKeyframe = kf
                        currentDeltas = [capture]
                    } else {
                        // Keyframe was pruned or no keyframeId -- standalone.
                        groups.append(KeyframeGroup(keyframe: capture, deltas: []))
                    }
                }
            }
        }

        if let kf = currentKeyframe {
            groups.append(KeyframeGroup(keyframe: kf, deltas: currentDeltas))
        }

        return groups
    }

    /// Collect keyframeIds from leading delta captures before the first keyframe.
    private func collectOrphanedKeyframeIds(_ captures: [CaptureRecord]) -> Set<Int64> {
        var ids = Set<Int64>()
        for capture in captures {
            if capture.isKeyframe { break }
            if let kfId = capture.keyframeId {
                ids.insert(kfId)
            }
        }
        return ids
    }

    /// Batch-fetch keyframe records by IDs, returning a dictionary keyed by ID.
    private func batchFetchKeyframes(ids: Set<Int64>) throws -> [Int64: CaptureRecord] {
        guard !ids.isEmpty else { return [:] }
        let records = try database.dbPool.read { db in
            try CaptureRecord
                .filter(ids.contains(CaptureRecord.Columns.id))
                .fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: records.compactMap { record in
            guard let id = record.id else { return nil }
            return (id, record)
        })
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

    // MARK: - Embeddings

    /// Update the embedding BLOB for a summary record.
    func updateSummaryEmbedding(id: Int64, embedding: [Float]) throws {
        let data = EmbeddingStore.floatsToData(embedding)
        try database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE summaries SET embedding = ? WHERE id = ?",
                arguments: [data, id]
            )
        }
    }

    /// Fetch summaries with their embeddings in a time range.
    /// Returns tuples of (SummaryRecord, deserialized embedding or nil).
    func summariesWithEmbeddings(
        from startDate: Date,
        to endDate: Date,
        limit: Int = 500
    ) throws -> [(SummaryRecord, [Float]?)] {
        let records = try database.dbPool.read { db in
            try SummaryRecord
                .filter(SummaryRecord.Columns.endTimestamp >= startDate.timeIntervalSince1970)
                .filter(SummaryRecord.Columns.startTimestamp <= endDate.timeIntervalSince1970)
                .order(SummaryRecord.Columns.endTimestamp.desc)
                .limit(limit)
                .fetchAll(db)
        }

        return records.map { record in
            let vector: [Float]? = record.embedding.flatMap {
                EmbeddingStore.dataToFloats($0)
            }
            return (record, vector)
        }
    }

    // MARK: - Cleanup

    /// Delete captures that have already been summarized and are older than
    /// the given number of hours. This keeps the captures table lean while
    /// preserving unsummarized captures that still need processing.
    @discardableResult
    func pruneProcessedCaptures(olderThan hours: Int = 24) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - Double(hours * 3600)
        return try database.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM captures WHERE isSummarized = 1 AND timestamp < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

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

    // MARK: - Stats

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

    /// Get the total database file size in bytes (main DB + WAL + SHM).
    func databaseSizeBytes() throws -> Int64 {
        let path = database.dbPool.path
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let filePath = path + suffix
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// Run incremental vacuum and optimizer after bulk deletions.
    func performMaintenance() throws {
        try database.dbPool.write { db in
            try db.execute(sql: "PRAGMA incremental_vacuum")
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    // MARK: - Menu Bar Stats

    /// Number of captures in the last 24 hours.
    func captureCount24h() throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - 86400
        return try database.dbPool.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.timestamp >= cutoff)
                .fetchCount(db)
        }
    }

    /// Number of summaries in the last 24 hours.
    func summaryCount24h() throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - 86400
        return try database.dbPool.read { db in
            try SummaryRecord
                .filter(SummaryRecord.Columns.endTimestamp >= cutoff)
                .fetchCount(db)
        }
    }

    /// Fetch the most recent N captures for the menu bar activity feed.
    func recentCaptures(limit: Int = 3) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            try CaptureRecord
                .order(CaptureRecord.Columns.timestamp.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Aggregated token usage across all callers in the last 24 hours.
    func totalTokenUsage24h() throws -> TokenUsageTotals {
        let cutoff = Date().timeIntervalSince1970 - 86400
        return try database.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(inputTokens), 0) AS totalInput,
                       COALESCE(SUM(outputTokens), 0) AS totalOutput
                FROM token_usage
                WHERE timestamp >= ?
                """, arguments: [cutoff])
            let totalInput = row?["totalInput"] as? Int64 ?? 0
            let totalOutput = row?["totalOutput"] as? Int64 ?? 0
            return TokenUsageTotals(inputTokens: totalInput, outputTokens: totalOutput)
        }
    }
}
