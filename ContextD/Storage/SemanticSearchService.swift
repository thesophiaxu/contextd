import Foundation
import GRDB

/// Coordinates TF-IDF embedding generation and semantic similarity search.
/// Builds vocabulary from the summary corpus, computes/caches embeddings,
/// and ranks results by cosine similarity.
final class SemanticSearchService: Sendable {
    private let storageManager: StorageManager
    private let embeddingStore: EmbeddingStore
    private let logger = DualLogger(category: "SemanticSearch")

    init(storageManager: StorageManager) {
        self.storageManager = storageManager
        self.embeddingStore = EmbeddingStore(database: storageManager.database)
    }

    /// Run a semantic similarity search against summaries in the given time range.
    ///
    /// Parameters
    /// - query: Natural language query text.
    /// - from: Start of time range.
    /// - to: End of time range.
    /// - limit: Maximum number of results.
    ///
    /// Returns array of (SummaryRecord, similarity score) tuples sorted by relevance.
    func search(
        query: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int
    ) throws -> [(SummaryRecord, Float)] {
        // Step 1: Load all summaries in the time range (for corpus building)
        let summaries = try storageManager.summaries(
            from: startDate, to: endDate
        )

        guard !summaries.isEmpty else {
            logger.debug("No summaries in time range for semantic search")
            return []
        }

        // Step 2: Build TF-IDF vocabulary from the corpus
        let texts = summaries.map { compositeText(for: $0) }
        let embedder = TFIDFEmbedder(documents: texts)

        guard embedder.dimensions > 0 else {
            logger.debug("Empty vocabulary, skipping semantic search")
            return []
        }

        // Step 3: Compute embeddings for summaries that lack them, store in DB
        let backfillCount = try backfillEmbeddings(
            summaries: summaries,
            texts: texts,
            embedder: embedder
        )
        if backfillCount > 0 {
            logger.info("Backfilled \(backfillCount) summary embeddings")
        }

        // Step 4: Embed the query using the same vocabulary
        let queryVector = embedder.embed(query)

        // Step 5: Compute similarity against all summaries with embeddings
        let results = try embeddingStore.similarSummaries(
            to: queryVector,
            from: startDate,
            to: endDate,
            limit: limit
        )

        return results
    }

    // MARK: - Internals

    /// Combine summary text and key topics into a single string for embedding.
    private func compositeText(for summary: SummaryRecord) -> String {
        var parts = [summary.summary]
        if let topics = summary.keyTopics {
            parts.append(topics)
        }
        if let apps = summary.appNames {
            parts.append(apps)
        }
        return parts.joined(separator: " ")
    }

    /// Compute and store embeddings for summaries that do not have one yet.
    /// Returns the number of summaries that were backfilled.
    private func backfillEmbeddings(
        summaries: [SummaryRecord],
        texts: [String],
        embedder: TFIDFEmbedder
    ) throws -> Int {
        var count = 0
        for (idx, summary) in summaries.enumerated() {
            guard summary.embedding == nil, let summaryId = summary.id else { continue }
            let vector = embedder.embed(texts[idx])
            try embeddingStore.storeEmbedding(summaryId: summaryId, embedding: vector)
            count += 1
        }
        return count
    }
}
