import Foundation
import AppKit

/// Sleep/wake and screen-lock observer management for CaptureEngine.
/// Pauses capture on system sleep or screen lock and resumes after
/// wake/unlock with a display-init delay.
extension CaptureEngine {

    /// Well-known distributed notification names for screen lock/unlock.
    /// These fire on both password-lock and fast-user-switch.
    private static let screenLockedName = NSNotification.Name(
        "com.apple.screenIsLocked"
    )
    private static let screenUnlockedName = NSNotification.Name(
        "com.apple.screenIsUnlocked"
    )

    func registerSleepWakeObservers() {
        // Workspace notifications for sleep/wake and display power
        let wsCenter = NSWorkspace.shared.notificationCenter
        let wsNames: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in wsNames {
            wsCenter.addObserver(
                self, selector: #selector(handleSleepWake(_:)),
                name: name, object: nil
            )
        }

        // Distributed notifications for explicit screen lock/unlock
        let distCenter = DistributedNotificationCenter.default()
        distCenter.addObserver(
            self, selector: #selector(handleScreenLock(_:)),
            name: Self.screenLockedName, object: nil
        )
        distCenter.addObserver(
            self, selector: #selector(handleScreenLock(_:)),
            name: Self.screenUnlockedName, object: nil
        )
    }

    func removeSleepWakeObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func handleSleepWake(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.willSleepNotification,
             NSWorkspace.screensDidSleepNotification,
             NSWorkspace.sessionDidResignActiveNotification:
            enterSleepState(reason: notification.name.rawValue)

        case NSWorkspace.didWakeNotification,
             NSWorkspace.screensDidWakeNotification,
             NSWorkspace.sessionDidBecomeActiveNotification:
            exitSleepState(reason: notification.name.rawValue)

        default:
            break
        }
    }

    @objc func handleScreenLock(_ notification: Notification) {
        if notification.name == Self.screenLockedName {
            enterSleepState(reason: "screenIsLocked")
        } else if notification.name == Self.screenUnlockedName {
            exitSleepState(reason: "screenIsUnlocked")
        }
    }

    // MARK: - Internal helpers

    private func enterSleepState(reason: String) {
        guard !isSleeping else { return }
        logger.info("Pausing capture (\(reason))")
        isSleeping = true
        state = .sleeping
        // Discard previous image so first post-wake capture is a keyframe
        previousImage = nil
    }

    private func exitSleepState(reason: String) {
        logger.info("Resuming capture after delay (\(reason))")
        // Delay resume to let displays initialize
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.isSleeping = false
            if self.isRunning {
                self.state = .recording
            }
        }
    }
}
