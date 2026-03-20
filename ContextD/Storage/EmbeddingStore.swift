import Accelerate
import Foundation
import GRDB

/// TF-IDF based embedding store for semantic similarity search over summaries.
/// Uses Accelerate/vDSP for fast cosine similarity computation.
/// Vocabulary is built from the corpus of summaries itself, giving
/// semantic-ish search without any external API calls.
final class EmbeddingStore: Sendable {
    let database: AppDatabase
    private let logger = DualLogger(category: "EmbeddingStore")

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Store / Load

    /// Store a precomputed embedding vector for a summary.
    func storeEmbedding(summaryId: Int64, embedding: [Float]) throws {
        let blob = Self.floatsToData(embedding)
        try database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE summaries SET embedding = ? WHERE id = ?",
                arguments: [blob, summaryId]
            )
        }
    }

    /// Load all summaries with embeddings in a time range.
    func loadEmbeddings(
        from startDate: Date,
        to endDate: Date
    ) throws -> [(summaryId: Int64, embedding: [Float])] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, embedding FROM summaries
                WHERE endTimestamp >= ? AND startTimestamp <= ?
                  AND embedding IS NOT NULL
                """, arguments: [
                    startDate.timeIntervalSince1970,
                    endDate.timeIntervalSince1970,
                ])

            return rows.compactMap { row -> (Int64, [Float])? in
                guard let id = row["id"] as? Int64,
                      let data = row["embedding"] as? Data else { return nil }
                let floats = Self.dataToFloats(data)
                guard !floats.isEmpty else { return nil }
                return (id, floats)
            }
        }
    }

    // MARK: - Similarity Search

    /// Find summaries most similar to a query embedding, ranked by cosine similarity.
    ///
    /// Parameters
    /// - queryEmbedding: TF-IDF vector for the query text
    /// - from: Start of time range
    /// - to: End of time range
    /// - limit: Maximum results to return
    ///
    /// Returns array of (SummaryRecord, similarity score) tuples, descending by score.
    func similarSummaries(
        to queryEmbedding: [Float],
        from startDate: Date,
        to endDate: Date,
        limit: Int
    ) throws -> [(SummaryRecord, Float)] {
        let allRecords = try database.dbPool.read { db in
            try SummaryRecord.fetchAll(db, sql: """
                SELECT * FROM summaries
                WHERE endTimestamp >= ? AND startTimestamp <= ?
                  AND embedding IS NOT NULL
                """, arguments: [
                    startDate.timeIntervalSince1970,
                    endDate.timeIntervalSince1970,
                ])
        }

        var scored: [(SummaryRecord, Float)] = []
        for record in allRecords {
            guard let data = record.embedding else { continue }
            let stored = Self.dataToFloats(data)
            guard stored.count == queryEmbedding.count else { continue }
            let sim = Self.cosineSimilarity(queryEmbedding, stored)
            if sim > 0.01 {  // skip near-zero matches
                scored.append((record, sim))
            }
        }

        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(limit))
    }

    // MARK: - Cosine Similarity (vDSP accelerated)

    /// Compute cosine similarity between two vectors using Accelerate/vDSP.
    /// Returns 0 if either vector has zero magnitude.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dotProduct / denom : 0
    }

    // MARK: - Serialization

    /// Convert a Float array to raw bytes for BLOB storage.
    static func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Convert raw BLOB bytes back to a Float array.
    static func dataToFloats(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Float.self)
            return Array(bound)
        }
    }
}
