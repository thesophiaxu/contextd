import Foundation
import AppKit

/// Reads basic accessibility metadata: frontmost app, focused window title,
/// and list of visible windows. Uses AXUIElement API and CGWindowList.
final class AccessibilityReader: Sendable {
    private let logger = DualLogger(category: "Accessibility")

    /// Metadata about the current screen state.
    struct ScreenMetadata: Sendable {
        let appName: String
        let appBundleID: String?
        let windowTitle: String?
        let visibleWindows: [VisibleWindow]
    }

    /// Read current screen metadata. Safe to call from any thread.
    @MainActor
    func readCurrentState() -> ScreenMetadata {
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        let appName = frontmostApp?.localizedName ?? "Unknown"
        let appBundleID = frontmostApp?.bundleIdentifier
        let windowTitle = getWindowTitle(for: frontmostApp)
        let visibleWindows = getVisibleWindows()

        return ScreenMetadata(
            appName: appName,
            appBundleID: appBundleID,
            windowTitle: windowTitle,
            visibleWindows: visibleWindows
        )
    }

    /// Get the focused window title using the Accessibility API.
    @MainActor
    private func getWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app = app else { return nil }
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility not trusted, cannot read window title")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        )

        guard result == .success, let windowElement = windowValue else {
            return nil
        }

        // AXUIElement is a CFTypeRef; CFTypeID check is the safe pattern
        let axWindow = windowElement as! AXUIElement

        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(
            axWindow,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        guard titleResult == .success, let title = titleValue as? String else {
            return nil
        }

        return title
    }

    /// Get a list of all visible windows using CGWindowListCopyWindowInfo.
    private func getVisibleWindows() -> [VisibleWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var windows: [VisibleWindow] = []

        for windowInfo in windowList {
            // Only include normal windows (layer 0)
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }

            guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String else {
                continue
            }

            // Window name requires Screen Recording permission on macOS 10.15+
            let windowName = windowInfo[kCGWindowName as String] as? String

            windows.append(VisibleWindow(appName: ownerName, windowTitle: windowName))
        }

        return windows
    }
}
