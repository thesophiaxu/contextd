import AppKit
import SwiftUI

// MARK: - AppDelegate

/// NSApplicationDelegate for handling lifecycle events that SwiftUI App can't.
/// Handles: onboarding window on first launch, starting services when ready.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DualLogger(category: "AppDelegate")
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps default to .prohibited activation policy, which prevents
        // windows from coming to the foreground and receiving keyboard input.
        // Set .accessory so windows can be activated on demand while staying out of the Dock.
        NSApp.setActivationPolicy(.accessory)

        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let permissionsOK = PermissionManager.shared.allPermissionsGranted

        if !hasOnboarded && !permissionsOK {
            logger.info("First launch - opening onboarding window")
            showOnboardingWindow()
        } else {
            logger.info("Starting services (onboarded=\(hasOnboarded), permissions=\(permissionsOK))")
            // Always start services if user has been through onboarding at least once.
            // Permissions may report false after restart even when granted on macOS 15+.
            ServiceContainer.shared.startServices()
        }
    }

    private func showOnboardingWindow() {
        let permissionManager = PermissionManager.shared

        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                ServiceContainer.shared.startServices()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to ContextD"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        // Bring to front even though we're an LSUIElement app
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startServices = Notification.Name("com.contextd.startServices")
}

// MARK: - Debug Window Controller

/// Manages the debug timeline window for inspecting database contents.
@MainActor
final class DebugWindowController {
    private var window: NSWindow?
    private let storageManager: StorageManager

    init(storageManager: StorageManager) {
        self.storageManager = storageManager
    }

    func toggle() {
        if let window = window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            createWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let contentView = DebugTimelineView(storageManager: storageManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "ContextD - Database Debug"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DebugWindow")

        self.window = window
    }
}

// MARK: - Enrichment Panel Controller

/// Manages the floating enrichment panel as an NSPanel.
/// NSPanel with .floating level stays above other windows.
@MainActor
final class EnrichmentPanelController {
    private var panel: NSPanel?
    private let enrichmentEngine: EnrichmentEngine

    init(enrichmentEngine: EnrichmentEngine) {
        self.enrichmentEngine = enrichmentEngine
    }

    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let contentView = EnrichmentPanel(enrichmentEngine: enrichmentEngine)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "ContextD - Enrich Prompt"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isReleasedWhenClosed = false
        // becomesKeyOnlyIfNeeded must be false so the panel accepts keyboard input
        panel.becomesKeyOnlyIfNeeded = false

        self.panel = panel
    }
}
