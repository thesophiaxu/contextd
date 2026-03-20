import AppKit
import CoreGraphics
import Foundation

/// The overall state of the capture engine, observable by UI.
enum CaptureState: String {
    case recording
    case paused
    case privacyPaused
    case sleeping
}

/// Coordinates the capture pipeline: screenshot -> pixel diff -> selective OCR -> store.
/// Runs on a configurable timer (default 5s) with keyframe/delta compression.
/// Supports adaptive capture intervals that back off during idle periods.
///
/// Pipeline flow:
/// 1. Check privacy exclusion (skip if excluded app is frontmost)
/// 2. Capture screenshot + accessibility metadata
/// 3. If first capture or no previous image: KEYFRAME (full OCR)
/// 4. Pixel diff against previous screenshot
/// 5. 0% tiles changed -> skip entirely (adaptive interval backs off)
/// 6. >=50% tiles changed, app switch, or time cap -> KEYFRAME (full OCR)
/// 7. Otherwise -> DELTA (OCR only changed regions)
@MainActor
final class CaptureEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var captureCount: Int = 0
    @Published var lastCaptureTime: Date?
    @Published var lastError: String?
    @Published var state: CaptureState = .paused
    @Published var isPrivacyPaused: Bool = false

    private let screenCapture = ScreenCapture()
    private let ocrProcessor = OCRProcessor()
    private let accessibilityReader = AccessibilityReader()
    private let storageManager: StorageManager

    let logger = DualLogger(category: "CaptureEngine")

    /// The base interval between captures in seconds (used when adaptive is off).
    var captureInterval: TimeInterval = 10.0

    /// Maximum time between keyframes in seconds.
    var maxKeyframeInterval: TimeInterval = 60

    /// The pixel diff engine.
    let imageDiffer = ImageDiffer()

    /// The previous captured screenshot for pixel diffing (~8MB).
    var previousImage: CGImage?

    /// DB ID of the current keyframe.
    private var currentKeyframeId: Int64?

    /// Full OCR text of the current keyframe.
    private var currentKeyframeText: String?

    /// OCR regions of the current keyframe.
    private var currentKeyframeRegions: [OCRRegion]?

    /// Timestamp of the last keyframe.
    private var lastKeyframeTime: Date?

    /// App name of the last keyframe (for detecting app switches).
    private var lastKeyframeAppName: String?

    /// The last captured text hash for deduplication.
    private var lastTextHash: String?

    /// The background capture task.
    private var captureTask: Task<Void, Never>?

    /// Whether the system is sleeping (pauses capture without stopping).
    var isSleeping = false

    // MARK: - Adaptive Capture Interval

    /// Whether adaptive interval scaling is enabled. Stored in UserDefaults.
    var adaptiveIntervalEnabled: Bool = true

    /// Capture speed preset. Controls base interval and adaptive tier scaling.
    enum CaptureSpeed: String, CaseIterable, Sendable {
        case fast   // 5/10/20/40s  - frequent captures, higher battery
        case medium // 10/20/30/45s - balanced (default)
        case slow   // 30/60/90/180s - minimal captures, lowest battery

        var baseInterval: TimeInterval {
            switch self {
            case .fast:   return 5.0
            case .medium: return 10.0
            case .slow:   return 30.0
            }
        }

        var tiers: (tier1: TimeInterval, tier2: TimeInterval, tier3: TimeInterval) {
            switch self {
            case .fast:   return (10.0, 20.0, 40.0)
            case .medium: return (20.0, 30.0, 45.0)
            case .slow:   return (60.0, 90.0, 180.0)
            }
        }

        var label: String {
            switch self {
            case .fast:   return "Fast"
            case .medium: return "Medium"
            case .slow:   return "Slow"
            }
        }
    }

    /// Current capture speed preset. Stored in UserDefaults.
    /// @Published so SwiftUI observes changes from the speed picker.
    @Published var captureSpeed: CaptureSpeed = .medium {
        didSet {
            captureInterval = captureSpeed.baseInterval
            UserDefaults.standard.set(captureSpeed.rawValue, forKey: "captureSpeed")
        }
    }

    /// Count of consecutive skipped frames (no pixel change detected).
    internal(set) var consecutiveSkips: Int = 0

    /// The current effective capture interval, accounting for adaptive backoff,
    /// low power mode, and thermal state.
    var currentInterval: TimeInterval {
        var interval = adaptiveIntervalEnabled ? adaptiveInterval : captureInterval

        // Low Power Mode: enforce minimum 5s
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            interval = max(interval, 5.0)
        }

        // Thermal throttling: enforce minimum 10s for serious/critical
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            interval = max(interval, 10.0)
        }

        return interval
    }

    /// Compute the adaptive interval from consecutive skip count using current speed preset.
    private var adaptiveInterval: TimeInterval {
        let tiers = captureSpeed.tiers
        switch consecutiveSkips {
        case 0...2:   return captureInterval    // active work
        case 3...5:   return tiers.tier1        // slowing down
        case 6...10:  return tiers.tier2        // mostly static
        default:      return tiers.tier3        // reading/idle
        }
    }

    // MARK: - App Privacy Exclusion

    /// Default set of apps excluded from capture (password managers, system settings).
    static let defaultExcludedApps: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
    ]

    /// Bundle IDs of apps that should pause capture when frontmost.
    var excludedAppBundleIDs: Set<String> = []

    init(storageManager: StorageManager) {
        self.storageManager = storageManager

        // Load the last text hash from the database for dedup continuity across restarts
        self.lastTextHash = try? storageManager.lastCaptureTextHash()
        self.captureCount = (try? storageManager.captureCount()) ?? 0

        // Load the last keyframe from DB for continuity
        if let lastKF = try? storageManager.lastKeyframe() {
            self.currentKeyframeId = lastKF.id
            self.currentKeyframeText = lastKF.ocrText
            self.lastKeyframeTime = lastKF.date
            self.lastKeyframeAppName = lastKF.appName
        }

        // Load excluded apps from UserDefaults (fall back to defaults)
        if let savedApps = UserDefaults.standard.stringArray(forKey: "excludedApps") {
            self.excludedAppBundleIDs = Set(savedApps)
        } else {
            self.excludedAppBundleIDs = Self.defaultExcludedApps
        }

        // Load adaptive interval preference (default: enabled)
        let hasKey = UserDefaults.standard.object(forKey: "adaptiveIntervalEnabled") != nil
        self.adaptiveIntervalEnabled = hasKey
            ? UserDefaults.standard.bool(forKey: "adaptiveIntervalEnabled")
            : true

        // Load capture speed preset (default: medium)
        if let rawSpeed = UserDefaults.standard.string(forKey: "captureSpeed"),
           let speed = CaptureSpeed(rawValue: rawSpeed) {
            self.captureSpeed = speed
            self.captureInterval = speed.baseInterval
        }
    }

    /// Start the capture loop.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isSleeping = false
        consecutiveSkips = 0
        lastError = nil
        state = .recording
        logger.info("Capture engine started (base interval: \(self.captureInterval)s, adaptive: \(self.adaptiveIntervalEnabled), keyframe cap: \(self.maxKeyframeInterval)s)")

        registerSleepWakeObservers()

        captureTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled && self.isRunning {
                if !self.isSleeping {
                    let cycleStart = ContinuousClock.now
                    await self.performCapture()
                    let interval = self.currentInterval
                    let elapsed = ContinuousClock.now - cycleStart
                    let remaining = Duration.seconds(interval) - elapsed
                    if remaining > .zero {
                        try? await Task.sleep(for: remaining)
                    }
                } else {
                    // While sleeping, poll infrequently instead of busy-waiting
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Stop the capture loop.
    func stop() {
        isRunning = false
        captureTask?.cancel()
        captureTask = nil
        consecutiveSkips = 0
        state = .paused
        removeSleepWakeObservers()
        logger.info("Capture engine stopped")
    }

    /// Perform a single capture cycle.
    ///
    /// Note: No screen-sharing check is needed here. CGDisplayCreateImage is
    /// a read-only API that coexists with Zoom/Teams/FaceTime screen sharing
    /// without interference. See ScreenCapture.swift for details.
    private func performCapture() async {
        // Belt-and-suspenders guard: do not capture during sleep/lock
        // even if the loop check was somehow bypassed.
        guard !isSleeping else { return }

        do {
            // Step 0: Check privacy exclusion before any screenshot
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               let bundleID = frontApp.bundleIdentifier,
               excludedAppBundleIDs.contains(bundleID) {
                if !isPrivacyPaused {
                    isPrivacyPaused = true
                    state = .privacyPaused
                    logger.debug("Privacy pause: excluded app \(bundleID) is frontmost")
                }
                return
            }
            if isPrivacyPaused {
                isPrivacyPaused = false
                state = .recording
                logger.debug("Privacy pause ended, resuming capture")
            }

            // Step 1: Read accessibility metadata
            let metadata = accessibilityReader.readCurrentState()

            // Step 2: Capture screenshot
            guard let image = try screenCapture.captureMainDisplay() else {
                logger.warning("Screenshot capture returned nil")
                return
            }

            // Step 3: Determine frame type via pixel diff
            let frameDecision = await determineFrameType(
                currentImage: image,
                appName: metadata.appName
            )

            switch frameDecision {
            case .skip:
                recordSkip()
                return

            case .keyframe(let diffResult):
                recordActivity()
                try await handleKeyframe(
                    image: image,
                    metadata: metadata,
                    changePercentage: diffResult?.tileDiff.changePercentage ?? 1.0
                )

            case .delta(let diffResult):
                recordActivity()
                try await handleDelta(
                    image: image,
                    metadata: metadata,
                    diffResult: diffResult
                )
            }

            // Update previous image for next diff
            previousImage = image

        } catch {
            lastError = error.localizedDescription
            logger.error("Capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Frame Type Decision

    private enum FrameDecision {
        case skip
        case keyframe(DiffResult?)    // nil diffResult means forced keyframe (no diff computed)
        case delta(DiffResult)
    }

    private func determineFrameType(currentImage: CGImage, appName: String) async -> FrameDecision {
        // First capture / after restart -> force keyframe
        guard let prevImage = previousImage else {
            logger.debug("No previous image, forcing keyframe")
            return .keyframe(nil)
        }

        // Compute pixel diff off MainActor (CPU-intensive work).
        // Safe: only one diff runs at a time (sequential capture loop).
        nonisolated(unsafe) let differ = imageDiffer
        let diffResult = await Task.detached(priority: .userInitiated) {
            differ.diff(current: currentImage, previous: prevImage)
        }.value

        // 0% tiles changed -> skip entirely
        if diffResult.tileDiff.changedTiles.isEmpty {
            return .skip
        }

        // Check if keyframe is needed
        let isSignificantChange = diffResult.isSignificantChange
        let isAppSwitch = appName != lastKeyframeAppName
        let timeSinceLastKeyframe = lastKeyframeTime.map { Date().timeIntervalSince($0) } ?? .infinity
        let isTimeCap = timeSinceLastKeyframe >= maxKeyframeInterval

        if isSignificantChange || isAppSwitch || isTimeCap {
            if isSignificantChange {
                logger.debug("Keyframe: \(String(format: "%.0f", diffResult.tileDiff.changePercentage * 100))% tiles changed")
            } else if isAppSwitch {
                logger.debug("Keyframe: app switch to \(appName)")
            } else {
                logger.debug("Keyframe: time cap (\(String(format: "%.0f", timeSinceLastKeyframe))s since last)")
            }
            return .keyframe(diffResult)
        }

        return .delta(diffResult)
    }

    // MARK: - Keyframe Handling

    private func handleKeyframe(
        image: CGImage,
        metadata: AccessibilityReader.ScreenMetadata,
        changePercentage: Double
    ) async throws {
        // Full-screen OCR
        let ocrResult = try await Task.detached(priority: .userInitiated) { [ocrProcessor] in
            try ocrProcessor.recognizeText(in: image)
        }.value

        // Hash dedup against last stored hash
        let normalizedText = ocrResult.fullText.normalizedForDedup
        let textHash = normalizedText.sha256Hash

        if let lastHash = lastTextHash, textHash == lastHash {
            logger.debug("Skipping duplicate keyframe (identical hash)")
            return
        }

        // Build CaptureFrame
        let frame = CaptureFrame(
            timestamp: Date(),
            appName: metadata.appName,
            appBundleID: metadata.appBundleID,
            windowTitle: metadata.windowTitle,
            visibleWindows: metadata.visibleWindows,
            ocrText: ocrResult.fullText,
            fullOcrText: ocrResult.fullText,
            ocrRegions: ocrResult.regions,
            textHash: textHash,
            frameType: .keyframe,
            keyframeId: nil,
            changePercentage: changePercentage
        )

        // Store in database
        let record = try storageManager.insertCapture(frame)

        // Update keyframe state
        currentKeyframeId = record.id
        currentKeyframeText = ocrResult.fullText
        currentKeyframeRegions = ocrResult.regions
        lastKeyframeTime = frame.timestamp
        lastKeyframeAppName = metadata.appName
        lastTextHash = textHash
        captureCount += 1
        lastCaptureTime = frame.timestamp
        lastError = nil

        logger.debug("Keyframe: app=\(metadata.appName) window=\(metadata.windowTitle ?? "nil") chars=\(ocrResult.fullText.count) change=\(String(format: "%.0f", changePercentage * 100))%")
    }

    // MARK: - Delta Handling

    private func handleDelta(
        image: CGImage,
        metadata: AccessibilityReader.ScreenMetadata,
        diffResult: DiffResult
    ) async throws {
        // OCR only changed regions (or full OCR if >8 regions)
        let ocrResult = try await Task.detached(priority: .userInitiated) { [ocrProcessor] in
            try ocrProcessor.recognizeText(
                inRegions: diffResult.changedRegions,
                fullImage: image,
                fullImageSize: CGSize(width: image.width, height: image.height)
            )
        }.value

        let deltaText = ocrResult.fullText
        // Store only the delta text, not keyframe+delta concatenated.
        // The keyframe text is already stored in the keyframe record.
        let fullOcrText = deltaText.isEmpty ? (currentKeyframeText ?? "") : deltaText

        // Hash dedup on fullOcrText
        let normalizedText = fullOcrText.normalizedForDedup
        let textHash = normalizedText.sha256Hash

        if let lastHash = lastTextHash, textHash == lastHash {
            logger.debug("Skipping duplicate delta (identical hash)")
            return
        }

        // Build CaptureFrame
        let frame = CaptureFrame(
            timestamp: Date(),
            appName: metadata.appName,
            appBundleID: metadata.appBundleID,
            windowTitle: metadata.windowTitle,
            visibleWindows: metadata.visibleWindows,
            ocrText: deltaText,
            fullOcrText: fullOcrText,
            ocrRegions: ocrResult.regions,
            textHash: textHash,
            frameType: .delta,
            keyframeId: currentKeyframeId,
            changePercentage: diffResult.tileDiff.changePercentage
        )

        // Store in database
        try storageManager.insertCapture(frame)

        // Update state
        lastTextHash = textHash
        captureCount += 1
        lastCaptureTime = frame.timestamp
        lastError = nil

        logger.debug("Delta: app=\(metadata.appName) change=\(String(format: "%.0f", diffResult.tileDiff.changePercentage * 100))% regions=\(diffResult.changedRegions.count) deltaChars=\(deltaText.count)")
    }
}
