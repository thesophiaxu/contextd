import Foundation
import AppKit

/// Manages checking and requesting macOS permissions required by ContextD.
/// Required permissions: Screen Recording (ScreenCaptureKit) and Accessibility (AXUIElement).
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = DualLogger(category: "Permissions")

    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    /// Active periodic re-check task. Cancelled on deinit.
    private var periodicCheckTask: Task<Void, Never>?

    /// Active polling task used after requesting screen recording permission.
    private var screenRecordingPollTask: Task<Void, Never>?

    var allPermissionsGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    private init() {
        refreshStatus()
        startPeriodicCheck()
    }

    deinit {
        periodicCheckTask?.cancel()
        screenRecordingPollTask?.cancel()
    }

    /// Re-check all permission statuses.
    func refreshStatus() {
        let newScreen = checkScreenRecording()
        let newAccessibility = checkAccessibility()
        // Only publish changes when values actually differ to avoid unnecessary UI updates.
        if newScreen != screenRecordingGranted {
            screenRecordingGranted = newScreen
        }
        if newAccessibility != accessibilityGranted {
            accessibilityGranted = newAccessibility
        }
        logger.info("Permissions - Screen Recording: \(self.screenRecordingGranted), Accessibility: \(self.accessibilityGranted)")
    }

    // MARK: - Periodic Re-check

    /// Poll permissions every 30 seconds so revocations are detected promptly.
    private func startPeriodicCheck() {
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Screen Recording

    /// Check if Screen Recording permission is granted (does not prompt).
    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission. Shows the system prompt on first call only.
    /// After the system dialog, polls CGPreflightScreenCaptureAccess() every 2 seconds
    /// for up to 60 seconds so the UI updates once the user grants permission.
    func requestScreenRecording() {
        // CGRequestScreenCaptureAccess() opens the system dialog but always returns false
        // on first call. We must poll CGPreflightScreenCaptureAccess() to detect the grant.
        CGRequestScreenCaptureAccess()
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<30 { // 30 x 2s = 60s max
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let granted = CGPreflightScreenCaptureAccess()
                if granted {
                    self?.screenRecordingGranted = true
                    self?.logger.info("Screen Recording permission granted after polling.")
                    return
                }
            }
            self?.logger.warning("Screen Recording permission not granted within polling window.")
        }
    }

    // MARK: - Accessibility

    /// Check if Accessibility permission is granted (does not prompt).
    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Request Accessibility permission. Shows the system dialog directing user to System Settings.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
        if !granted {
            logger.warning("Accessibility permission not granted. User must enable manually.")
        }
    }

    // MARK: - Open System Settings

    /// Open System Settings to the Screen Recording privacy pane.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
