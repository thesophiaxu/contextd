import Foundation

/// Adaptive capture interval logic for CaptureEngine.
/// Backs off the capture frequency during idle periods to save CPU/battery,
/// then snaps back to the base interval when screen activity resumes.
///
/// Tier table:
///   consecutive skips 0-2:   10s  (active work, base interval)
///   consecutive skips 3-5:   20s  (slowing down)
///   consecutive skips 6-10:  30s  (mostly static)
///   consecutive skips 11+:   45s  (reading/idle)
///
/// Additional constraints:
///   Low Power Mode:  minimum 5s
///   Thermal .serious or .critical: minimum 10s
extension CaptureEngine {

    /// Record a skipped frame and log the resulting interval change.
    func recordSkip() {
        consecutiveSkips += 1
        if adaptiveIntervalEnabled {
            let newInterval = currentInterval
            logger.debug(
                "Skip #\(self.consecutiveSkips), "
                + "next interval: \(String(format: "%.1f", newInterval))s"
            )
        } else {
            logger.debug("Skipping capture (0% change)")
        }
    }

    /// Reset adaptive interval state when screen activity is detected.
    func recordActivity() {
        if consecutiveSkips > 0 && adaptiveIntervalEnabled {
            logger.debug(
                "Activity detected, resetting interval to "
                + "\(String(format: "%.1f", self.captureInterval))s "
                + "(was \(String(format: "%.1f", self.currentInterval))s "
                + "after \(self.consecutiveSkips) skips)"
            )
        }
        consecutiveSkips = 0
    }
}
