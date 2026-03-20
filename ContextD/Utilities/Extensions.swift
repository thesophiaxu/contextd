import Foundation
import CryptoKit

extension String {
    /// Compute SHA256 hash of this string, returned as a hex string.
    var sha256Hash: String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Normalize text for deduplication: lowercase, collapse whitespace, trim.
    var normalizedForDedup: String {
        self.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension Date {
    /// Shared formatters (static let = created once, thread-safe for reads).
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let shortTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Format as a human-readable relative time (e.g., "2 min ago").
    var relativeString: String {
        Date.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }

    /// Format as a short timestamp string.
    var shortTimestamp: String {
        Date.shortTimestampFormatter.string(from: self)
    }
}

extension Array {
    /// Safely access an element at the given index, returning nil if out of bounds.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
