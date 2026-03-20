import Foundation
import CoreGraphics

/// Coordinates the capture pipeline: screenshot -> pixel diff -> selective OCR -> store.
/// Runs on a configurable timer (default 2s) with keyframe/delta compression.
///
/// Pipeline flow:
/// 1. Capture screenshot + accessibility metadata
/// 2. If first capture or no previous image: KEYFRAME (full OCR)
/// 3. Pixel diff against previous screenshot
/// 4. 0% tiles changed -> skip entirely
/// 5. >=50% tiles changed, app switch, or time cap -> KEYFRAME (full OCR)
/// 6. Otherwise -> DELTA (OCR only changed regions)
@MainActor
final class CaptureEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var captureCount: Int = 0
    @Published var lastCaptureTime: Date?
    @Published var lastError: String?

    private let screenCapture = ScreenCapture()
    private let ocrProcessor = OCRProcessor()
    private let accessibilityReader = AccessibilityReader()
    private let storageManager: StorageManager

    private let logger = DualLogger(category: "CaptureEngine")

    /// The interval between captures in seconds.
    var captureInterval: TimeInterval = 2.0

    /// Maximum time between keyframes in seconds.
    var maxKeyframeInterval: TimeInterval = 60

    /// The pixel diff engine.
    let imageDiffer = ImageDiffer()

    /// The previous captured screenshot for pixel diffing (~8MB).
    private var previousImage: CGImage?

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
    }

    /// Start the capture loop.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        logger.info("Capture engine started (interval: \(self.captureInterval)s, keyframe cap: \(self.maxKeyframeInterval)s)")

        captureTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled && self.isRunning {
                await self.performCapture()
                try? await Task.sleep(nanoseconds: UInt64(self.captureInterval * 1_000_000_000))
            }
        }
    }

    /// Stop the capture loop.
    func stop() {
        isRunning = false
        captureTask?.cancel()
        captureTask = nil
        logger.info("Capture engine stopped")
    }

    /// Perform a single capture cycle.
    private func performCapture() async {
        do {
            // Step 1: Read accessibility metadata
            let metadata = accessibilityReader.readCurrentState()

            // Step 2: Capture screenshot
            guard let image = try screenCapture.captureMainDisplay() else {
                logger.warning("Screenshot capture returned nil")
                return
            }

            // Step 3: Determine frame type via pixel diff
            let frameDecision = determineFrameType(
                currentImage: image,
                appName: metadata.appName
            )

            switch frameDecision {
            case .skip:
                logger.debug("Skipping capture (0% change)")
                return

            case .keyframe(let diffResult):
                try await handleKeyframe(
                    image: image,
                    metadata: metadata,
                    changePercentage: diffResult?.tileDiff.changePercentage ?? 1.0
                )

            case .delta(let diffResult):
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

    private func determineFrameType(currentImage: CGImage, appName: String) -> FrameDecision {
        // First capture / after restart -> force keyframe
        guard let prevImage = previousImage else {
            logger.debug("No previous image, forcing keyframe")
            return .keyframe(nil)
        }

        // Compute pixel diff
        let diffResult = imageDiffer.diff(current: currentImage, previous: prevImage)

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
        let fullOcrText = (currentKeyframeText ?? "") + (deltaText.isEmpty ? "" : "\n" + deltaText)

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
