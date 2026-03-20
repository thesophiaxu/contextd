import SwiftUI

@main
struct ContextDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// All services live in the singleton -- not in @State on this struct.
    private let services = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    init() {
        // Skip Keychain migration - using claude -p proxy, no API key needed

        // Register the global hotkey
        HotkeyManager.shared.onHotkey = {
            Task { @MainActor in
                ServiceContainer.shared.panelController?.toggle()
            }
        }
        HotkeyManager.shared.register()
    }
}

// MARK: - Menu Bar Label (Icon)

/// Dynamic menu bar icon that reflects capture engine state.
/// Observes the CaptureEngine so the icon updates in real time.
private struct MenuBarLabel: View {

    var body: some View {
        if let engine = ServiceContainer.shared.captureEngine {
            MenuBarIconView(captureEngine: engine)
        } else {
            Image(systemName: "eye.slash.circle")
                .symbolRenderingMode(.hierarchical)
        }
    }
}

/// Inner view that holds the @ObservedObject for the capture engine.
/// Separated so the optional unwrap in MenuBarLabel stays clean.
private struct MenuBarIconView: View {
    @ObservedObject var captureEngine: CaptureEngine

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
    }

    private var iconName: String {
        guard captureEngine.isRunning else {
            return "eye.slash"
        }
        switch captureEngine.state {
        case .recording:
            return "eye.fill"
        case .paused:
            return "eye.slash"
        case .privacyPaused:
            return "lock.shield"
        case .sleeping:
            return "moon.fill"
        }
    }
}

// MARK: - Menu Bar Content

/// Rich menu bar dropdown panel.
private struct MenuBarContent: View {
    @ObservedObject private var permissionManager = PermissionManager.shared

    private var services: ServiceContainer { ServiceContainer.shared }

    var body: some View {
        Group {
            if let captureEngine = services.captureEngine {
                MenuBarView(
                    captureEngine: captureEngine,
                    permissionManager: permissionManager,
                    storageManager: services.storageManager,
                    onOpenEnrichment: {
                        services.panelController?.toggle()
                    },
                    onOpenDebug: {
                        services.debugController?.toggle()
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Failed to initialize.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }
}
