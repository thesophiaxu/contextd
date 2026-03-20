import SwiftUI

/// A running application entry for the picker UI.
private struct AppEntry: Identifiable {
    let id: String  // bundle ID
    let name: String
    let icon: NSImage
}

/// Privacy tab for the Settings window.
/// Shows a running-apps picker with toggles and a saved exclusions section.
struct SettingsPrivacyTab: View {
    @AppStorage("adaptiveIntervalEnabled") private var adaptiveIntervalEnabled: Bool = true
    @State private var excludedApps: Set<String> = []
    @State private var runningApps: [AppEntry] = []
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                adaptiveIntervalSection
            }
            .frame(height: 155)

            Divider()

            appExclusionContent
        }
        .onAppear {
            loadExcludedApps()
            loadRunningApps()
        }
    }

    // MARK: - Adaptive Interval

    private var adaptiveIntervalSection: some View {
        Section("Adaptive Capture Interval") {
            Toggle("Enable adaptive interval", isOn: $adaptiveIntervalEnabled)
                .onChange(of: adaptiveIntervalEnabled) { _, enabled in
                    ServiceContainer.shared.captureEngine?.adaptiveIntervalEnabled = enabled
                }

            Text(
                "Interval increases during low activity (2s to 15s), snaps "
                + "back when changes are detected. Minimum 5s in Low Power "
                + "Mode, 10s under thermal throttling."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - App Exclusion Content

    private var appExclusionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("App Privacy Exclusions").font(.headline)
                    Spacer()
                    Button { loadRunningApps() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh running apps")
                }
                Text("Capture pauses when excluded apps are in the foreground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            appList

            footerSection
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var appList: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Filter apps...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)

            List {
                if !filteredRunningApps.isEmpty {
                    Section("Running Apps") {
                        ForEach(filteredRunningApps) { app in
                            appRow(app: app)
                        }
                    }
                }

                if !savedNonRunningApps.isEmpty {
                    Section("Excluded (Not Running)") {
                        ForEach(savedNonRunningApps, id: \.self) { bundleID in
                            savedExclusionRow(bundleID: bundleID)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footerSection: some View {
        HStack {
            Text("\(excludedApps.count) app\(excludedApps.count == 1 ? "" : "s") excluded")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset to Defaults") {
                resetToDefaults()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Row Views

    private func appRow(app: AppEntry) -> some View {
        let isExcluded = excludedApps.contains(app.id)
        return HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(app.id)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isExcluded },
                set: { newValue in
                    toggleApp(bundleID: app.id, excluded: newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func savedExclusionRow(bundleID: String) -> some View {
        HStack(spacing: 8) {
            appIcon(for: bundleID)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text(appName(for: bundleID))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(bundleID)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                removeApp(bundleID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Remove from exclusion list")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Computed Properties

    private var filteredRunningApps: [AppEntry] {
        if searchText.isEmpty { return runningApps }
        let query = searchText.lowercased()
        return runningApps.filter { app in
            app.name.lowercased().contains(query)
            || app.id.lowercased().contains(query)
        }
    }

    /// Excluded bundle IDs that are not among the currently running apps.
    private var savedNonRunningApps: [String] {
        let runningIDs = Set(runningApps.map(\.id))
        return excludedApps
            .filter { !runningIDs.contains($0) }
            .sorted()
    }

    // MARK: - Actions

    private func toggleApp(bundleID: String, excluded: Bool) {
        if excluded {
            excludedApps.insert(bundleID)
        } else {
            excludedApps.remove(bundleID)
        }
        saveExcludedApps()
    }

    private func removeApp(_ bundleID: String) {
        excludedApps.remove(bundleID)
        saveExcludedApps()
    }

    private func resetToDefaults() {
        excludedApps = CaptureEngine.defaultExcludedApps
        saveExcludedApps()
    }

    private func loadExcludedApps() {
        if let saved = UserDefaults.standard.stringArray(forKey: "excludedApps") {
            excludedApps = Set(saved)
        } else {
            excludedApps = CaptureEngine.defaultExcludedApps
        }
    }

    private func saveExcludedApps() {
        let sorted = excludedApps.sorted()
        UserDefaults.standard.set(sorted, forKey: "excludedApps")
        ServiceContainer.shared.captureEngine?.excludedAppBundleIDs = excludedApps
    }

    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppEntry? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                let icon = app.icon ?? NSImage(
                    systemSymbolName: "app.dashed",
                    accessibilityDescription: "Application"
                ) ?? NSImage()
                return AppEntry(id: bundleID, name: name, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        runningApps = apps
    }

    // MARK: - Helpers

    private func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func appName(for bundleID: String) -> String {
        if let url = appURL(for: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    private func appIcon(for bundleID: String) -> Image {
        if let url = appURL(for: bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "app.dashed")
    }
}
