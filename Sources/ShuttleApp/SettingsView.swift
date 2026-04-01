import SwiftUI
import AppKit
import ShuttleKit

private enum ShuttleSettingsTab: Hashable {
    case general
    case paths
    case layouts
    case advanced
}

struct ShuttleSettingsView: View {
    @State private var selectedTab: ShuttleSettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView {
                selectedTab = .layouts
            }
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(ShuttleSettingsTab.general)

            PathsSettingsView()
                .tabItem {
                    Label("Paths", systemImage: "folder.badge.gearshape")
                }
                .tag(ShuttleSettingsTab.paths)

            LayoutsSettingsView()
                .tabItem {
                    Label("Layouts", systemImage: "square.grid.2x2")
                }
                .tag(ShuttleSettingsTab.layouts)

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(ShuttleSettingsTab.advanced)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

private struct GeneralSettingsView: View {
    let onOpenLayouts: () -> Void

    @AppStorage(ShuttlePreferenceKey.reopenPreviousSelectionOnLaunch) private var reopenPreviousSelectionOnLaunch = true
    @AppStorage(ShuttlePreferenceKey.restoreScrollbackOnReopen) private var restoreScrollbackOnReopen = true
    @AppStorage(ShuttlePreferenceKey.seedMultiProjectAgentGuide) private var seedMultiProjectAgentGuide = true

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Reopen previous selection on launch",
                    isOn: Binding(
                        get: { reopenPreviousSelectionOnLaunch },
                        set: { newValue in
                            reopenPreviousSelectionOnLaunch = newValue
                            if !newValue {
                                ShuttleSessionSnapshotStore.remove()
                            }
                        }
                    )
                )

                Toggle("Restore scrollback when reopening sessions", isOn: $restoreScrollbackOnReopen)
            } header: {
                Text("Restore")
            } footer: {
                Text("Shuttle saves a lightweight session snapshot for relaunch. Disabling relaunch restore clears the saved snapshot immediately.")
            }

            Section {
                Toggle("Seed AGENTS.md for sessions", isOn: $seedMultiProjectAgentGuide)
                    .shuttleHint("Seed an AGENTS.md guide inside Shuttle session roots.")
            } header: {
                Text("Agent workflows")
            } footer: {
                Text("When enabled, Shuttle seeds `AGENTS.md` into session roots so agents can discover the active source checkout and any project-specific guidance files.")
            }

            Section {
                Button("Open Layout Defaults") {
                    onOpenLayouts()
                }
                .shuttleHint("Jump to the Layouts tab to choose separate defaults for new sessions and try sessions.")

                Text("Choose separate defaults for new sessions and try sessions in the Layouts tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Layouts")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct PathsSettingsView: View {
    @State private var config: ShuttleConfig?
    @State private var loadError: String?

    private var configURL: URL {
        ShuttleExternalPaths.shuttlePaths.configURL
    }

    private var ghosttyConfigLocations: [GhosttyConfigLocation] {
        ShuttleExternalPaths.ghosttyConfigLocations
    }

    var body: some View {
        Form {
            Section {
                SettingsPathRow(
                    title: "Config file",
                    path: configURL.path,
                    kind: .file,
                    onOpen: {
                        ShuttleExternalPaths.ensureShuttleConfigExists()
                        ShuttleExternalPaths.open(configURL)
                    },
                    onReveal: {
                        ShuttleExternalPaths.ensureShuttleConfigExists()
                        ShuttleExternalPaths.reveal(configURL)
                    }
                )

                if let config {
                    SettingsPathRow(
                        title: "Session root",
                        path: config.expandedSessionRoot,
                        kind: .directory
                    )

                    SettingsPathRow(
                        title: "Tries root",
                        path: config.expandedTriesRoot,
                        kind: .directory
                    )
                } else if let loadError {
                    SettingsMessageRow(
                        title: "Couldn’t load Shuttle config",
                        message: loadError
                    )
                } else {
                    ProgressView("Loading Shuttle config…")
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("Shuttle reads its session roots and project discovery settings from this config file.")
            }

            if let config {
                Section {
                    if config.expandedProjectRoots.isEmpty {
                        Text("No project discovery roots configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(config.expandedProjectRoots, id: \.self) { root in
                            SettingsPathRow(
                                title: nil,
                                path: root,
                                kind: .directory
                            )
                        }
                    }
                } header: {
                    Text("Project discovery roots")
                } footer: {
                    Text("Shuttle scans these directories for projects.")
                }

                Section {
                    if config.ignoredPaths.isEmpty {
                        Text("No ignored path patterns configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(config.ignoredPaths, id: \.self) { pattern in
                            Text(pattern)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Ignored paths")
                } footer: {
                    Text("These glob patterns are skipped during project discovery.")
                }
            }

            Section {
                Text("Shuttle reuses your Ghostty configuration for terminal theme, font, colors, and other appearance details.")
                    .foregroundStyle(.secondary)

                ForEach(ghosttyConfigLocations) { location in
                    SettingsPathRow(
                        title: location.title,
                        note: location.note,
                        path: location.url.path,
                        kind: .file
                    )
                }
            } header: {
                Text("Ghostty")
            } footer: {
                Text("Ghostty loads these files in order. Later files override earlier ones. `config.ghostty` is the current filename, while `config` remains supported for older setups. When `XDG_CONFIG_HOME` is unset, the XDG path falls back to `~/.config`.")
            }

            Section {
                Button("Reload Config") {
                    loadConfig()
                }
                .shuttleHint("Reload Shuttle config from disk.")
            } header: {
                Text("Actions")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task {
            loadConfig()
        }
    }

    private func loadConfig() {
        do {
            let config = try ConfigManager(paths: ShuttleExternalPaths.shuttlePaths).load()
            self.config = config
            self.loadError = nil
        } catch {
            self.config = nil
            self.loadError = error.localizedDescription
        }
    }
}

private struct LayoutsSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var layouts: LayoutLibraryModel
    @AppStorage(ShuttlePreferenceKey.defaultSessionLayoutID) private var defaultSessionLayoutID = LayoutPresetStore.defaultPresetID
    @AppStorage(ShuttlePreferenceKey.defaultTryLayoutID) private var defaultTryLayoutID = LayoutPresetStore.defaultPresetID

    private var defaultSessionPreset: LayoutPreset? {
        layouts.preset(id: defaultSessionLayoutID)
    }

    private var defaultTryPreset: LayoutPreset? {
        layouts.preset(id: defaultTryLayoutID)
    }

    var body: some View {
        Form {
            Section {
                Picker("Default layout for new sessions", selection: $defaultSessionLayoutID) {
                    ForEach(layouts.presets, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }

                Picker("Default layout for new try sessions", selection: $defaultTryLayoutID) {
                    ForEach(layouts.presets, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Toolbar session creation uses these presets automatically. CLI invocations can still override the layout explicitly.")
            }

            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        DefaultLayoutPreviewCard(
                            title: "New sessions",
                            subtitle: "Used when you create a session from the app.",
                            preset: defaultSessionPreset
                        )

                        DefaultLayoutPreviewCard(
                            title: "New try sessions",
                            subtitle: "Used when you create a try session from the app.",
                            preset: defaultTryPreset
                        )
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        DefaultLayoutPreviewCard(
                            title: "New sessions",
                            subtitle: "Used when you create a session from the app.",
                            preset: defaultSessionPreset
                        )

                        DefaultLayoutPreviewCard(
                            title: "New try sessions",
                            subtitle: "Used when you create a try session from the app.",
                            preset: defaultTryPreset
                        )
                    }
                }
            } header: {
                Text("Default previews")
            }

            Section {
                ForEach(layouts.presets, id: \.id) { preset in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(preset.name)
                                    .fontWeight(.medium)

                                if preset.isBuiltIn {
                                    SettingsBadge("Built-in")
                                }

                                if preset.id == defaultSessionLayoutID {
                                    SettingsBadge("Sessions default", tone: .accent)
                                }

                                if preset.id == defaultTryLayoutID {
                                    SettingsBadge("Try default", tone: .accent)
                                }
                            }

                            if let description = preset.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(preset.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Preset library")
            }

            Section {
                HStack {
                    Button("Edit Layouts…") {
                        openWindow(id: ShuttleLayoutBuilderWindow.id)
                    }
                    .shuttleHint("Open Layout Builder to edit layout presets.")

                    Button("New Layout…") {
                        layouts.createPreset()
                        openWindow(id: ShuttleLayoutBuilderWindow.id)
                    }
                    .shuttleHint("Create a new custom layout preset and open it in Layout Builder.")
                }

                if let error = layouts.lastErrorMessage {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Actions")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            defaultSessionLayoutID = layouts.resolvedPresetID(preferred: defaultSessionLayoutID)
            defaultTryLayoutID = layouts.resolvedPresetID(preferred: defaultTryLayoutID)
        }
    }
}

private struct AdvancedSettingsView: View {
    @EnvironmentObject private var layouts: LayoutLibraryModel
    @State private var isConfirmingClearRestoreState = false
    @State private var isConfirmingResetDefaults = false

    private var profile: ShuttleProfile {
        ShuttleProfile.current
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current profile") {
                    HStack(spacing: 8) {
                        Text(profile.appDisplayName)
                        if profile == .dev {
                            SettingsBadge("DEV", tone: .warning)
                        }
                    }
                }

                LabeledContent("Preferences suite") {
                    Text(profile.userDefaultsSuiteName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Profile")
            } footer: {
                Text(profile == .dev ? "Shuttle Dev keeps its config, Application Support, and preferences separate from the production app." : "This profile uses Shuttle’s standard config, Application Support, and preferences locations.")
            }

            Section {
                Button("Clear Saved Restore State", role: .destructive) {
                    isConfirmingClearRestoreState = true
                }
                .shuttleHint("Delete Shuttle’s saved next-launch restore snapshot.")
                .confirmationDialog(
                    "Clear Saved Restore State?",
                    isPresented: $isConfirmingClearRestoreState,
                    titleVisibility: .visible
                ) {
                    Button("Clear Saved Restore State", role: .destructive) {
                        ShuttleSessionSnapshotStore.remove()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes Shuttle’s saved next-launch restore snapshot. It does not delete your config file, session data, or custom layouts.")
                }

                Button("Reveal Application Support Folder") {
                    ShuttleExternalPaths.reveal(ShuttleExternalPaths.shuttlePaths.appSupportURL)
                }
                .shuttleHint("Show Shuttle’s Application Support folder in Finder.")

                Button("Reveal Layout Presets Folder") {
                    let url = LayoutPresetStore(paths: ShuttleExternalPaths.shuttlePaths).layoutsDirectoryURL()
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    ShuttleExternalPaths.reveal(url)
                }
                .shuttleHint("Show the folder that stores custom layout presets.")
            } header: {
                Text("State")
            } footer: {
                Text("Saved restore state only affects what Shuttle tries to reopen on the next launch.")
            }

            Section {
                Button("Reset Shuttle App Defaults", role: .destructive) {
                    isConfirmingResetDefaults = true
                }
                .shuttleHint("Reset Shuttle’s app-level defaults. Your config file and saved custom layouts stay untouched.")
                .confirmationDialog(
                    "Reset Shuttle App Defaults?",
                    isPresented: $isConfirmingResetDefaults,
                    titleVisibility: .visible
                ) {
                    Button("Reset Shuttle App Defaults", role: .destructive) {
                        ShuttlePreferences.resetToDefaults()
                        layouts.reload()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This resets Shuttle’s app-level defaults only. Your config file, session data, and saved custom layouts are left untouched.")
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Use this when you want to restore Shuttle’s default app preferences without changing on-disk project or layout data.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private enum SettingsPathKind {
    case file
    case directory
}

private enum SettingsBadgeTone {
    case secondary
    case accent
    case positive
    case warning
}

private struct SettingsBadge: View {
    let text: String
    var tone: SettingsBadgeTone = .secondary

    init(_ text: String, tone: SettingsBadgeTone = .secondary) {
        self.text = text
        self.tone = tone
    }

    private var foregroundColor: Color {
        switch tone {
        case .secondary:
            return .secondary
        case .accent:
            return .accentColor
        case .positive:
            return .green
        case .warning:
            return .orange
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .secondary:
            return Color.secondary.opacity(0.12)
        case .accent:
            return Color.accentColor.opacity(0.12)
        case .positive:
            return Color.green.opacity(0.12)
        case .warning:
            return Color.orange.opacity(0.14)
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
    }
}

private enum SettingsPathStatus {
    case exists
    case missing
    case notConfigured

    var title: String {
        switch self {
        case .exists:
            return "Exists"
        case .missing:
            return "Missing"
        case .notConfigured:
            return "Not configured"
        }
    }

    var tone: SettingsBadgeTone {
        switch self {
        case .exists:
            return .positive
        case .missing:
            return .warning
        case .notConfigured:
            return .secondary
        }
    }
}

private struct SettingsPathRow: View {
    let title: String?
    let note: String?
    let path: String?
    let kind: SettingsPathKind
    var onOpen: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil

    init(
        title: String?,
        note: String? = nil,
        path: String?,
        kind: SettingsPathKind,
        onOpen: (() -> Void)? = nil,
        onReveal: (() -> Void)? = nil
    ) {
        self.title = title
        self.note = note
        self.path = path
        self.kind = kind
        self.onOpen = onOpen
        self.onReveal = onReveal
    }

    private var trimmedPath: String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var pathURL: URL? {
        trimmedPath.map { URL(fileURLWithPath: $0) }
    }

    private var exists: Bool {
        guard let trimmedPath else { return false }
        return FileManager.default.fileExists(atPath: trimmedPath)
    }

    private var status: SettingsPathStatus {
        guard trimmedPath != nil else {
            return .notConfigured
        }
        return exists ? .exists : .missing
    }

    private var canOpen: Bool {
        onOpen != nil || exists
    }

    private var canReveal: Bool {
        trimmedPath != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.medium))
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(trimmedPath ?? "Not configured")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    SettingsBadge(status.title, tone: status.tone)
                    Spacer(minLength: 0)
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    SettingsBadge(status.title, tone: status.tone)
                    actionButtons
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let trimmedPath {
            HStack(spacing: 8) {
                Button("Copy") {
                    copyToPasteboard(trimmedPath)
                }
                .shuttleHint("Copy this path to the clipboard.")

                Button("Open") {
                    performOpen()
                }
                .disabled(!canOpen)
                .shuttleHint("Open this \(kind == .directory ? "folder" : "file").")

                Button("Reveal") {
                    performReveal()
                }
                .disabled(!canReveal)
                .shuttleHint("Reveal this \(kind == .directory ? "folder" : "file") in Finder.")
            }
        }
    }

    private func performOpen() {
        if let onOpen {
            onOpen()
            return
        }

        guard let pathURL, exists else { return }
        ShuttleExternalPaths.open(pathURL)
    }

    private func performReveal() {
        if let onReveal {
            onReveal()
            return
        }

        guard let pathURL else { return }
        revealBestEffort(url: pathURL, kind: kind)
    }
}

private struct SettingsMessageRow: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

private struct DefaultLayoutPreviewCard: View {
    let title: String
    let subtitle: String
    let preset: LayoutPreset?

    var body: some View {
        GroupBox {
            PresetSummaryCard(preset: preset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

private func revealBestEffort(url: URL, kind: SettingsPathKind) {
    let target: URL
    switch kind {
    case .file:
        if FileManager.default.fileExists(atPath: url.path) {
            target = url
        } else {
            target = nearestExistingAncestor(of: url.deletingLastPathComponent())
        }
    case .directory:
        target = nearestExistingAncestor(of: url)
    }

    ShuttleExternalPaths.reveal(target)
}

private func nearestExistingAncestor(of url: URL) -> URL {
    var candidate = url.standardizedFileURL
    let fileManager = FileManager.default

    while !fileManager.fileExists(atPath: candidate.path) {
        let parent = candidate.deletingLastPathComponent()
        if parent.path == candidate.path {
            return parent
        }
        candidate = parent
    }

    return candidate
}

struct PresetSummaryCard: View {
    let preset: LayoutPreset?
    var badges: [String] = []

    var body: some View {
        if let preset {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(preset.name)
                        .font(.headline)

                    if preset.isBuiltIn {
                        SettingsBadge("Built-in")
                    }

                    ForEach(badges, id: \.self) { badge in
                        SettingsBadge(badge, tone: .accent)
                    }
                }

                Text(preset.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let description = preset.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else {
            Text("No preset selected")
                .foregroundStyle(.secondary)
        }
    }
}
