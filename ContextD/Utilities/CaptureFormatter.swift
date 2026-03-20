import Foundation

/// Shared formatting utility for rendering captures as hierarchical keyframe+delta text
/// for LLM input. Used by both summarization and enrichment.
///
/// Output format:
///   --- Keyframe (HH:MM:SS) [AppName - WindowTitle] ---
///   <full screen text>
///
///   --- Delta (HH:MM:SS) [X% changed] ---
///   <changed-region text only>
enum CaptureFormatter {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Public API

    /// Format capture groups into hierarchical keyframe+delta text for LLM input.
    /// Keyframes include full ocrText; deltas include only their ocrText (changed regions).
    static func formatHierarchical(
        groups: [KeyframeGroup],
        maxKeyframes: Int = 10,
        maxDeltasPerKeyframe: Int = 5,
        maxKeyframeTextLength: Int = 3000,
        maxDeltaTextLength: Int = 500
    ) -> String {
        guard !groups.isEmpty else { return "" }

        // Select evenly spaced keyframe groups if we have more than maxKeyframes
        let selectedGroups: [KeyframeGroup]
        if groups.count > maxKeyframes {
            let indices = evenlySpacedIndices(count: groups.count, maxSamples: maxKeyframes)
            selectedGroups = indices.map { groups[$0] }
        } else {
            selectedGroups = groups
        }

        var sections: [String] = []

        for group in selectedGroups {
            // Format the keyframe
            let kf = group.keyframe
            let time = dateFormatter.string(from: kf.date)
            let app = kf.appName
            let window = kf.windowTitle ?? "Unknown"
            let text = truncate(kf.ocrText, maxLength: maxKeyframeTextLength)

            sections.append("--- Keyframe (\(time)) [\(app) - \(window)] ---\n\(text)")

            // Format selected deltas
            let deltas = group.deltas
            guard !deltas.isEmpty else { continue }

            let selectedDeltas: [CaptureRecord]
            if deltas.count > maxDeltasPerKeyframe {
                let indices = evenlySpacedIndices(count: deltas.count, maxSamples: maxDeltasPerKeyframe)
                selectedDeltas = indices.map { deltas[$0] }
            } else {
                selectedDeltas = deltas
            }

            for delta in selectedDeltas {
                let deltaTime = dateFormatter.string(from: delta.date)
                let changePct = Int(delta.changePercentage * 100)
                let deltaText = truncate(delta.ocrText, maxLength: maxDeltaTextLength)

                if !deltaText.isEmpty {
                    sections.append("--- Delta (\(deltaTime)) [\(changePct)% changed] ---\n\(deltaText)")
                }
            }
        }

        return sections.joined(separator: "\n\n")
    }

    /// Format a flat list of captures into hierarchical text.
    /// Internally groups them into KeyframeGroups first.
    static func formatHierarchical(
        captures: [CaptureRecord],
        maxKeyframes: Int = 10,
        maxDeltasPerKeyframe: Int = 5,
        maxKeyframeTextLength: Int = 3000,
        maxDeltaTextLength: Int = 500
    ) -> String {
        let groups = groupCaptures(captures)
        return formatHierarchical(
            groups: groups,
            maxKeyframes: maxKeyframes,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )
    }

    // MARK: - Internal Helpers

    /// Group a flat list of captures into KeyframeGroup sequences.
    /// Each keyframe starts a new group; subsequent deltas append to the current group.
    /// Legacy captures (all frameType='keyframe') become standalone groups.
    static func groupCaptures(_ captures: [CaptureRecord]) -> [KeyframeGroup] {
        // Sort by timestamp ascending for grouping
        let sorted = captures.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        var groups: [KeyframeGroup] = []
        var currentKeyframe: CaptureRecord?
        var currentDeltas: [CaptureRecord] = []

        for capture in sorted {
            if capture.isKeyframe {
                // Close previous group
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
                    // Orphaned delta - treat as standalone keyframe group
                    // (it has fullOcrText so it's self-contained)
                    groups.append(KeyframeGroup(keyframe: capture, deltas: []))
                }
            }
        }

        // Close the last group
        if let kf = currentKeyframe {
            groups.append(KeyframeGroup(keyframe: kf, deltas: currentDeltas))
        }

        return groups
    }

    /// Truncate text to a maximum character length, appending "..." if truncated.
    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "..."
    }

    /// Generate evenly spaced indices for sampling.
    private static func evenlySpacedIndices(count: Int, maxSamples: Int) -> [Int] {
        guard count > maxSamples else { return Array(0..<count) }
        let step = Double(count - 1) / Double(maxSamples - 1)
        return (0..<maxSamples).map { Int(Double($0) * step) }
    }
}
