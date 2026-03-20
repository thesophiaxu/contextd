import SwiftUI

// MARK: - Status Header

/// App name + state indicator with colored dot.
struct StatusHeaderView: View {
    let state: CaptureState
    let isRunning: Bool

    var body: some View {
        HStack {
            Text("contextd")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dotColor: Color {
        guard isRunning else { return .gray }
        switch state {
        case .recording:     return .green
        case .paused:        return .gray
        case .privacyPaused: return .orange
        case .sleeping:      return .blue
        }
    }

    private var statusLabel: String {
        guard isRunning else { return "Paused" }
        switch state {
        case .recording:     return "Recording"
        case .paused:        return "Paused"
        case .privacyPaused: return "Privacy Mode"
        case .sleeping:      return "Sleeping"
        }
    }
}

// MARK: - Stats Cards

/// Three stat cards in a horizontal row: captures, summaries, cost.
struct StatsCardsView: View {
    let captureCount: Int
    let summaryCount: Int
    let estimatedCost: Double

    var body: some View {
        HStack(spacing: 8) {
            StatCard(
                value: formatCount(captureCount),
                label: "Captures",
                icon: "camera.fill",
                accentColor: .blue
            )
            StatCard(
                value: formatCount(summaryCount),
                label: "Summaries",
                icon: "text.alignleft",
                accentColor: .purple
            )
            StatCard(
                value: formatCost(estimatedCost),
                label: "Cost 24h",
                icon: "dollarsign.circle",
                accentColor: .green
            )
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 10_000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return NumberFormatter.localizedString(
            from: NSNumber(value: count),
            number: .decimal
        )
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return "$0.00"
        }
        return String(format: "$%.2f", cost)
    }
}

/// A single stat card with value, label, and SF Symbol icon.
private struct StatCard: View {
    let value: String
    let label: String
    let icon: String
    var accentColor: Color = .secondary

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColor)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - Interval Indicator

/// Shows capture speed picker and current interval status.
struct IntervalIndicatorView: View {
    @ObservedObject var captureEngine: CaptureEngine

    var body: some View {
        VStack(spacing: 6) {
            // Speed picker - segmented control
            HStack(spacing: 0) {
                ForEach(CaptureEngine.CaptureSpeed.allCases, id: \.self) { speed in
                    Button {
                        captureEngine.captureSpeed = speed
                    } label: {
                        Text(speed.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(captureEngine.captureSpeed == speed ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(captureEngine.captureSpeed == speed ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            // Current status line
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text("\(String(format: "%.0f", captureEngine.currentInterval))s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if captureEngine.consecutiveSkips > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 10))
                        Text("idle")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text("active")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.green.opacity(0.8))
                }
            }
        }
    }
}

// MARK: - Recent Activity

/// Last 3 captures with app name, timestamp, and window title.
struct RecentActivityView: View {
    let captures: [CaptureRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Activity")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if captures.isEmpty {
                HStack {
                    Spacer()
                    Text("No recent captures")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(captures, id: \.id) { capture in
                        RecentCaptureRow(capture: capture)
                    }
                }
            }
        }
    }
}

/// A single row in the recent activity feed.
private struct RecentCaptureRow: View {
    let capture: CaptureRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(capture.date.shortTimestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)

            Image(systemName: appIcon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(capture.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let title = capture.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(capture.isKeyframe ? "KF" : "D")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(capture.isKeyframe ? .orange : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    (capture.isKeyframe ? Color.orange : Color.secondary)
                        .opacity(0.12)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.vertical, 3)
    }

    private var appIcon: String {
        let name = capture.appName.lowercased()
        if name.contains("terminal") || name.contains("iterm") || name.contains("warp") {
            return "terminal"
        } else if name.contains("safari") || name.contains("chrome")
                    || name.contains("firefox") || name.contains("arc") {
            return "globe"
        } else if name.contains("xcode") {
            return "hammer"
        } else if name.contains("finder") {
            return "folder"
        } else if name.contains("mail") {
            return "envelope"
        } else if name.contains("messages") || name.contains("slack") || name.contains("discord") {
            return "bubble.left.and.bubble.right"
        } else if name.contains("notes") || name.contains("obsidian") {
            return "note.text"
        } else if name.contains("preview") || name.contains("pdf") {
            return "doc.richtext"
        } else if name.contains("music") || name.contains("spotify") {
            return "music.note"
        } else {
            return "app.fill"
        }
    }
}

// MARK: - Warning Banner

/// Shows errors or missing permissions with a subtle warning style.
struct WarningBannerView: View {
    let error: String?
    let permissionsOK: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !permissionsOK {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Missing permissions")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            if let error = error {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

