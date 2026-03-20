import Accelerate
import Foundation

/// Builds TF-IDF vectors from a corpus of text documents.
/// The vocabulary is derived from the documents themselves, giving
/// term-frequency/inverse-document-frequency weighting for semantic search
/// without any external API or ML model.
///
/// Thread-safe: builds vocabulary once, then produces vectors immutably.
struct TFIDFEmbedder: Sendable {

    /// Mapping from token to its index in the embedding vector.
    let vocabulary: [String: Int]

    /// Inverse document frequency weight per vocabulary term.
    let idfWeights: [Float]

    /// Dimensionality of produced vectors.
    var dimensions: Int { vocabulary.count }

    // MARK: - Construction

    /// Build a TF-IDF embedder from a corpus of documents.
    ///
    /// Parameters
    /// - documents: Array of text documents (e.g. summary strings).
    /// - minDocFreq: Minimum number of documents a term must appear in (default 1).
    /// - maxDocFreqRatio: Maximum fraction of documents a term may appear in (default 0.95).
    ///   Terms appearing in more than this fraction are considered stop-words.
    /// - maxVocabularySize: Cap on vocabulary size to bound vector dimensions (default 2048).
    init(
        documents: [String],
        minDocFreq: Int = 1,
        maxDocFreqRatio: Double = 0.95,
        maxVocabularySize: Int = 2048
    ) {
        let docCount = documents.count
        guard docCount > 0 else {
            vocabulary = [:]
            idfWeights = []
            return
        }

        // Tokenize each document and count document frequency per term
        let tokenizedDocs = documents.map { Self.tokenize($0) }
        var docFreq: [String: Int] = [:]
        for tokens in tokenizedDocs {
            let unique = Set(tokens)
            for token in unique {
                docFreq[token, default: 0] += 1
            }
        }

        // Filter by doc frequency bounds
        let maxDF = Int(Double(docCount) * maxDocFreqRatio)
        var filteredTerms = docFreq.filter { (_, df) in
            df >= minDocFreq && df <= max(maxDF, 1)
        }

        // If vocabulary is too large, keep the most informative terms
        // (highest IDF, i.e. lowest document frequency)
        if filteredTerms.count > maxVocabularySize {
            let sorted = filteredTerms.sorted { $0.value < $1.value }
            filteredTerms = Dictionary(uniqueKeysWithValues: sorted.prefix(maxVocabularySize).map { ($0.key, $0.value) })
        }

        // Build deterministic vocabulary ordering (sorted alphabetically for stability)
        let sortedTerms = filteredTerms.keys.sorted()
        var vocab: [String: Int] = [:]
        vocab.reserveCapacity(sortedTerms.count)
        for (idx, term) in sortedTerms.enumerated() {
            vocab[term] = idx
        }

        // Compute IDF weights: log(N / df) with smoothing
        let n = Float(docCount)
        var idf = [Float](repeating: 0, count: sortedTerms.count)
        for (idx, term) in sortedTerms.enumerated() {
            let df = Float(docFreq[term] ?? 1)
            // Smooth IDF: log((1 + N) / (1 + df)) + 1
            idf[idx] = log((1.0 + n) / (1.0 + df)) + 1.0
        }

        self.vocabulary = vocab
        self.idfWeights = idf
    }

    // MARK: - Embedding

    /// Compute the TF-IDF embedding vector for a text string.
    /// Returns a Float array of length `dimensions`, L2-normalized.
    func embed(_ text: String) -> [Float] {
        guard !vocabulary.isEmpty else { return [] }

        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else {
            return [Float](repeating: 0, count: dimensions)
        }

        // Term frequency (count per token)
        var tf: [String: Float] = [:]
        for token in tokens {
            tf[token, default: 0] += 1.0
        }

        // Sub-linear TF: 1 + log(tf) for tf > 0
        var vector = [Float](repeating: 0, count: dimensions)
        let tokenCount = Float(tokens.count)
        for (term, count) in tf {
            guard let idx = vocabulary[term] else { continue }
            let normalizedTF = count / tokenCount
            vector[idx] = (1.0 + log(max(count, 1.0))) * normalizedTF * idfWeights[idx]
        }

        // L2 normalize using vDSP
        var norm: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        if norm > 0 {
            var divisor = norm
            vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(vector.count))
        }

        return vector
    }

    // MARK: - Tokenization

    /// Tokenize text into lowercase alphanumeric words.
    /// Strips punctuation, splits on whitespace, filters short tokens.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}
