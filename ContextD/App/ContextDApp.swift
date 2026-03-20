import SwiftUI

@main
struct ContextDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// All services live in the singleton — not in @State on this struct.
    private let services = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra("ContextD", systemImage: "eye.circle") {
            MenuBarContent()
        }

        Settings {
            SettingsView()
        }
    }

    init() {
        // Register the global hotkey
        HotkeyManager.shared.onHotkey = {
            Task { @MainActor in
                ServiceContainer.shared.panelController?.toggle()
            }
        }
        HotkeyManager.shared.register()
    }
}

// MARK: - Menu Bar Content

/// Menu bar dropdown. Listens for .startServices notification from AppDelegate.
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
                VStack {
                    Text("Failed to initialize.")
                        .padding()
                }
            }
        }
        // Services are started directly by AppDelegate — no notification needed.
    }
}
