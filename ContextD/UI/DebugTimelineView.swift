import SwiftUI

/// Debug window showing live database contents: captures, summaries, and stats.
/// Auto-refreshes on a timer so you can watch data flow in real time.
struct DebugTimelineView: View {
    let storageManager: StorageManager

    @State private var captures: [CaptureRecord] = []
    @State private var summaries: [SummaryRecord] = []
    @State private var captureCount: Int = 0
    @State private var summaryCount: Int = 0
    @State private var dbSizeBytes: Int64 = 0
    @State private var searchQuery: String = ""
    @State private var searchResults: [CaptureRecord] = []
    @State private var selectedTab: Tab = .captures
    @State private var selectedCapture: CaptureRecord?
    @State private var autoRefresh: Bool = true
    @State private var refreshError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case captures = "Captures"
        case summaries = "Summaries"
        case search = "Search"
        case stats = "Stats"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            // Tab content
            TabView(selection: $selectedTab) {
                capturesTab
                    .tabItem { Label("Captures", systemImage: "list.bullet") }
                    .tag(Tab.captures)

                summariesTab
                    .tabItem { Label("Summaries", systemImage: "doc.text") }
                    .tag(Tab.summaries)

                searchTab
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)

                statsTab
                    .tabItem { Label("Stats", systemImage: "chart.bar") }
                    .tag(Tab.stats)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .task(id: autoRefresh) {
            refresh()
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack {
            Text("Database Debug")
                .font(.headline)

            Spacer()

            Text("\(captureCount) captures, \(summaryCount) summaries")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formatBytes(dbSizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Toggle("Auto-refresh", isOn: $autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        if let error = refreshError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Captures Tab

    private var capturesTab: some View {
        HSplitView {
            // Left: capture list
            captureList

            // Right: detail pane
            captureDetail
        }
    }

    private var captureList: some View {
        List(captures, id: \.id, selection: $selectedCapture) { capture in
            CaptureRowView(capture: capture)
                .tag(capture)
        }
        .frame(minWidth: 320)
    }

    private var captureDetail: some View {
        Group {
            if let capture = selectedCapture {
                CaptureDetailView(capture: capture)
            } else {
                VStack {
                    Spacer()
                    Text("Select a capture to view details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 300)
    }

    // MARK: - Summaries Tab

    private var summariesTab: some View {
        List(summaries, id: \.id) { summary in
            SummaryRowView(summary: summary)
        }
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Full-text search across all captures...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; searchResults = [] }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.bar)

            Divider()

            if searchResults.isEmpty && !searchQuery.isEmpty {
                VStack {
                    Spacer()
                    Text("No results")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(searchResults, id: \.id) { capture in
                    CaptureRowView(capture: capture)
                }
            }
        }
    }

    // MARK: - Stats Tab

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsSection("Overview") {
                    statRow("Total captures", "\(captureCount)")
                    statRow("Total summaries", "\(summaryCount)")
                    statRow("Database size", formatBytes(dbSizeBytes))
                    if let oldest = captures.last {
                        statRow("Oldest capture", oldest.date.relativeString)
                    }
                    if let newest = captures.first {
                        statRow("Newest capture", newest.date.relativeString)
                    }
                }

                statsSection("Top Applications") {
                    let appGroups = Dictionary(grouping: captures, by: \.appName)
                        .mapValues(\.count)
                        .sorted { $0.value > $1.value }
                        .prefix(10)
                    ForEach(Array(appGroups), id: \.key) { app, count in
                        HStack {
                            Text(app)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            ProgressView(value: Double(count), total: Double(captures.count))
                                .frame(width: 100)
                        }
                    }
                }

                statsSection("Frame Types") {
                    let keyframes = captures.filter(\.isKeyframe)
                    let deltas = captures.filter(\.isDelta)
                    statRow("Keyframes", "\(keyframes.count)")
                    statRow("Deltas", "\(deltas.count)")
                    if !deltas.isEmpty {
                        let avgChange = deltas.map(\.changePercentage).reduce(0, +) / Double(deltas.count)
                        statRow("Avg delta change", "\(Int(avgChange * 100))%")
                        let avgKFSize = keyframes.isEmpty ? 0 : keyframes.map { $0.ocrText.count }.reduce(0, +) / keyframes.count
                        let avgDeltaSize = deltas.map { $0.ocrText.count }.reduce(0, +) / deltas.count
                        statRow("Avg keyframe text", "\(avgKFSize) chars")
                        statRow("Avg delta text", "\(avgDeltaSize) chars")
                        if avgKFSize > 0 {
                            statRow("Compression", "\(Int(100 - Double(avgDeltaSize) / Double(avgKFSize) * 100))%")
                        }
                    }
                }

                statsSection("Summarization") {
                    let summarized = captures.filter(\.isSummarized).count
                    let unsummarized = captureCount - summarized
                    statRow("Summarized", "\(summarized)")
                    statRow("Pending", "\(unsummarized)")
                    if captureCount > 0 {
                        ProgressView(
                            value: Double(summarized),
                            total: Double(captureCount)
                        ) {
                            Text("Progress")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func statsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }

    // MARK: - Data Loading

    private func refresh() {
        do {
            let last24h = Date.now.addingTimeInterval(-24 * 60 * 60)
            captures = try storageManager.captures(
                from: last24h,
                to: Date(),
                limit: 200
            )
            summaries = try storageManager.recentSummaries(limit: 50)
            captureCount = try storageManager.captureCount()
            summaryCount = try storageManager.summaryCount()
            dbSizeBytes = try storageManager.databaseSizeBytes()
            refreshError = nil
        } catch {
            refreshError = "Refresh failed: \(error.localizedDescription)"
        }
    }

    private func performSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        do {
            searchResults = try storageManager.searchCaptures(query: searchQuery, limit: 100)
            refreshError = nil
        } catch {
            searchResults = []
            refreshError = "Search failed: \(error.localizedDescription)"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Row Views

private struct CaptureRowView: View {
    let capture: CaptureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                // Frame type badge
                Text(capture.isKeyframe ? "K" : "D")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(capture.isKeyframe ? Color.green : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(capture.appName)
                    .font(.caption.bold())
                    .foregroundStyle(.blue)

                if let window = capture.windowTitle {
                    Text("- \(window)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(capture.date.shortTimestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(capture.fullOcrText.prefix(150).replacingOccurrences(of: "\n", with: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label("full: \(capture.fullOcrText.count)", systemImage: "character.cursor.ibeam")
                if capture.isDelta {
                    Label("delta: \(capture.ocrText.count)", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("\(Int(capture.changePercentage * 100))% changed")
                if capture.isSummarized {
                    Label("Summarized", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct CaptureDetailView: View {
    let capture: CaptureRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Metadata
                Group {
                    detailRow("ID", "\(capture.id ?? -1)")
                    detailRow("Timestamp", capture.date.shortTimestamp + " (\(capture.date.relativeString))")
                    detailRow("App", capture.appName)
                    if let bundleID = capture.appBundleID {
                        detailRow("Bundle ID", bundleID)
                    }
                    if let window = capture.windowTitle {
                        detailRow("Window", window)
                    }
                    detailRow("Frame Type", capture.frameType.uppercased())
                    if let kfId = capture.keyframeId {
                        detailRow("Keyframe ID", "\(kfId)")
                    }
                    detailRow("Change %", "\(Int(capture.changePercentage * 100))%")
                    detailRow("Text Hash", String(capture.textHash.prefix(16)) + "...")
                    detailRow("Summarized", capture.isSummarized ? "Yes" : "No")
                    detailRow("Full Text", "\(capture.fullOcrText.count) characters")
                    if capture.isDelta {
                        detailRow("Delta Text", "\(capture.ocrText.count) characters")
                    }
                }

                // Visible windows
                let windows = capture.decodedVisibleWindows
                if !windows.isEmpty {
                    Divider()
                    Text("Visible Windows (\(windows.count))")
                        .font(.caption.bold())
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        HStack {
                            Text(window.appName)
                                .font(.caption.bold())
                            Text(window.windowTitle ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Full OCR text (primary display)
                Text("Full OCR Text")
                    .font(.caption.bold())

                Text(capture.fullOcrText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Delta-only text for delta frames
                if capture.isDelta && capture.ocrText != capture.fullOcrText {
                    Divider()

                    Text("Delta Text (changed regions only)")
                        .font(.caption.bold())

                    Text(capture.ocrText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.orange.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(12)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

private struct SummaryRowView: View {
    let summary: SummaryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.decodedAppNames.joined(separator: ", "))
                    .font(.caption.bold())
                    .foregroundStyle(.purple)

                Spacer()

                Text("\(summary.startDate.shortTimestamp) - \(summary.endDate.shortTimestamp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(summary.summary)
                .font(.caption)
                .lineLimit(3)

            if !summary.decodedKeyTopics.isEmpty {
                HStack(spacing: 4) {
                    ForEach(summary.decodedKeyTopics.prefix(5), id: \.self) { topic in
                        Text(topic)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }

            Text("\(summary.decodedCaptureIds.count) captures")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Equatable conformance for selection

extension CaptureRecord: Equatable {
    public static func == (lhs: CaptureRecord, rhs: CaptureRecord) -> Bool {
        lhs.id == rhs.id
    }
}

extension CaptureRecord: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
