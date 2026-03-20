import Foundation

/// Utilities for text comparison and deduplication.
enum TextDiff {

    /// Compute Jaccard similarity between two pre-normalized strings based on word sets.
    /// Returns a value between 0.0 (completely different) and 1.0 (identical).
    private static func jaccardSimilarityNormalized(_ normA: String, _ normB: String) -> Double {
        let wordsA = Set(normA.split(separator: " ").map(String.init))
        let wordsB = Set(normB.split(separator: " ").map(String.init))

        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        guard union > 0 else { return 1.0 }
        return Double(intersection) / Double(union)
    }

    /// Compute Jaccard similarity between two strings based on word sets.
    /// Returns a value between 0.0 (completely different) and 1.0 (identical).
    static func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        jaccardSimilarityNormalized(a.normalizedForDedup, b.normalizedForDedup)
    }

    /// Check if two OCR text outputs are similar enough to be considered duplicates.
    /// Default threshold is 0.9 (90% word overlap).
    ///
    /// Caches normalized strings to avoid recomputing normalization for both the
    /// hash comparison and the Jaccard similarity fallback.
    static func isDuplicate(_ a: String, _ b: String, threshold: Double = 0.9) -> Bool {
        let normA = a.normalizedForDedup
        let normB = b.normalizedForDedup

        // Fast path: exact hash match on normalized text
        if normA.sha256Hash == normB.sha256Hash {
            return true
        }

        // Slow path: Jaccard similarity using already-normalized strings
        return jaccardSimilarityNormalized(normA, normB) >= threshold
    }
}
