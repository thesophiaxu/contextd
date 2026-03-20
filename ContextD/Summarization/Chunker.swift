import Foundation

/// Groups capture records into time-based chunks for progressive summarization.
enum Chunker {

    /// A chunk of captures covering a contiguous time window.
    struct Chunk: Sendable {
        let captures: [CaptureRecord]
        let startTime: Date
        let endTime: Date

        /// The primary app name for this chunk (most frequent, ties broken alphabetically).
        var primaryApp: String {
            let appCounts = Dictionary(grouping: captures, by: \.appName)
                .mapValues { $0.count }
            // Sort by count descending, then alphabetically ascending to break ties deterministically
            return appCounts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .first?.key ?? "Unknown"
        }

        /// All unique app names in this chunk.
        var appNames: [String] {
            Array(Set(captures.map(\.appName))).sorted()
        }

        /// The primary window title: most frequent window title for the primary app,
        /// with ties broken alphabetically for determinism.
        var primaryWindowTitle: String? {
            let app = primaryApp
            let appCaptures = captures.filter { $0.appName == app }
            let titleCounts = Dictionary(
                grouping: appCaptures.compactMap(\.windowTitle),
                by: { $0 }
            ).mapValues { $0.count }

            guard !titleCounts.isEmpty else {
                return appCaptures.last?.windowTitle
            }

            return titleCounts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .first?.key
        }

        /// Capture IDs in this chunk.
        var captureIds: [Int64] {
            captures.compactMap(\.id)
        }
    }

    /// Chunk captures into time-based windows.
    /// - Parameters:
    ///   - captures: Captures sorted by timestamp ascending.
    ///   - windowDuration: Duration of each chunk in seconds (default: 300 = 5 minutes).
    /// - Returns: Array of chunks.
    static func chunkByTime(
        captures: [CaptureRecord],
        windowDuration: TimeInterval = 300
    ) -> [Chunk] {
        guard !captures.isEmpty else { return [] }

        var chunks: [Chunk] = []
        var currentChunk: [CaptureRecord] = []
        var windowStart: Double = captures[0].timestamp

        for capture in captures {
            if capture.timestamp - windowStart >= windowDuration && !currentChunk.isEmpty {
                // Close current chunk
                let chunk = Chunk(
                    captures: currentChunk,
                    startTime: Date(timeIntervalSince1970: windowStart),
                    endTime: Date(timeIntervalSince1970: currentChunk.last!.timestamp)
                )
                chunks.append(chunk)

                // Start new chunk
                currentChunk = [capture]
                windowStart = capture.timestamp
            } else {
                currentChunk.append(capture)
            }
        }

        // Don't forget the last chunk
        if !currentChunk.isEmpty {
            let chunk = Chunk(
                captures: currentChunk,
                startTime: Date(timeIntervalSince1970: windowStart),
                endTime: Date(timeIntervalSince1970: currentChunk.last!.timestamp)
            )
            chunks.append(chunk)
        }

        return chunks
    }

    /// Chunk captures by app-switch boundaries.
    /// A new chunk starts whenever the frontmost app changes.
    static func chunkByAppSwitch(captures: [CaptureRecord]) -> [Chunk] {
        guard !captures.isEmpty else { return [] }

        var chunks: [Chunk] = []
        var currentChunk: [CaptureRecord] = [captures[0]]
        var currentApp = captures[0].appName

        for capture in captures.dropFirst() {
            if capture.appName != currentApp {
                // App changed - close current chunk
                let chunk = Chunk(
                    captures: currentChunk,
                    startTime: Date(timeIntervalSince1970: currentChunk.first!.timestamp),
                    endTime: Date(timeIntervalSince1970: currentChunk.last!.timestamp)
                )
                chunks.append(chunk)

                currentChunk = [capture]
                currentApp = capture.appName
            } else {
                currentChunk.append(capture)
            }
        }

        // Last chunk
        if !currentChunk.isEmpty {
            let chunk = Chunk(
                captures: currentChunk,
                startTime: Date(timeIntervalSince1970: currentChunk.first!.timestamp),
                endTime: Date(timeIntervalSince1970: currentChunk.last!.timestamp)
            )
            chunks.append(chunk)
        }

        return chunks
    }

    /// Hybrid chunking: first splits by time windows, then subdivides each window
    /// at app-switch boundaries. This produces semantically coherent chunks where
    /// each chunk covers a single app's activity within a time window.
    ///
    /// Sub-chunks shorter than `minimumChunkDuration` are merged into the previous
    /// chunk to avoid micro-chunks from rapid app switching (e.g., quick alt-tabs).
    ///
    /// - Parameters:
    ///   - captures: Captures sorted by timestamp ascending.
    ///   - windowDuration: Maximum duration of each time window in seconds (default: 300).
    ///   - minimumChunkDuration: Sub-chunks shorter than this are merged into their
    ///     neighbor (default: 15 seconds). Set to 0 to disable merging.
    /// - Returns: Array of chunks, each covering a single app within a time window.
    static func chunkHybrid(
        captures: [CaptureRecord],
        windowDuration: TimeInterval = 300,
        minimumChunkDuration: TimeInterval = 15
    ) -> [Chunk] {
        guard !captures.isEmpty else { return [] }

        // Step 1: Split into time windows (same as chunkByTime).
        let timeChunks = chunkByTime(captures: captures, windowDuration: windowDuration)

        // Step 2: Subdivide each time window at app-switch boundaries.
        var result: [Chunk] = []

        for timeChunk in timeChunks {
            let subChunks = chunkByAppSwitch(captures: timeChunk.captures)

            // Step 3: Merge sub-chunks that are too short into their predecessor.
            let merged = mergeShortChunks(subChunks, minimumDuration: minimumChunkDuration)
            result.append(contentsOf: merged)
        }

        return result
    }

    /// Merge chunks shorter than `minimumDuration` into the previous chunk.
    /// The first chunk is never merged away (it has no predecessor).
    /// When merging, captures are combined and the time range is extended.
    private static func mergeShortChunks(
        _ chunks: [Chunk],
        minimumDuration: TimeInterval
    ) -> [Chunk] {
        guard !chunks.isEmpty else { return [] }
        guard minimumDuration > 0 else { return chunks }

        var merged: [Chunk] = [chunks[0]]

        for chunk in chunks.dropFirst() {
            let duration = chunk.endTime.timeIntervalSince(chunk.startTime)

            if duration < minimumDuration, let last = merged.last {
                // Merge into previous chunk: combine captures and extend time range.
                let combinedCaptures = last.captures + chunk.captures
                let combinedChunk = Chunk(
                    captures: combinedCaptures,
                    startTime: last.startTime,
                    endTime: chunk.endTime
                )
                merged[merged.count - 1] = combinedChunk
            } else {
                merged.append(chunk)
            }
        }

        return merged
    }
}
