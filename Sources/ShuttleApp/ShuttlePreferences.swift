import Foundation
import AppKit
import ShuttleKit

enum ShuttlePreferenceKey {
    static let reopenPreviousSelectionOnLaunch = "Shuttle.reopenPreviousSelectionOnLaunch"
    static let restoreScrollbackOnReopen = "Shuttle.restoreScrollbackOnReopen"
    static let defaultSessionLayoutID = "Shuttle.defaultSessionLayoutID"
    static let defaultTryLayoutID = "Shuttle.defaultTryLayoutID"
    static let seedMultiProjectAgentGuide = "Shuttle.seedMultiProjectAgentGuide"
    static let workspaceSidebarPinnedExpanded = "Shuttle.workspaceSidebarPinnedExpanded"
    static let workspaceSidebarRecentExpanded = "Shuttle.workspaceSidebarRecentExpanded"
    static let workspaceSidebarProjectExpanded = "Shuttle.workspaceSidebarProjectExpanded"
    static let workspaceSidebarTryExpanded = "Shuttle.workspaceSidebarTryExpanded"
    static let pinnedWorkspaceKeys = "Shuttle.pinnedWorkspaceKeys"
    static let sessionSidebarArchivedExpanded = "Shuttle.sessionSidebarArchivedExpanded"
    static let sessionSidebarProjectsExpanded = "Shuttle.sessionSidebarProjectsExpanded"
    static let bellMarksAttention = "Shuttle.bellMarksAttention"
}

enum ShuttlePreferences {
    static let emptyPinnedWorkspaceKeysStorage = "[]"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ShuttleProfile.current.userDefaultsSuiteName) ?? .standard
    }

    static var userDefaults: UserDefaults {
        defaults
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            ShuttlePreferenceKey.reopenPreviousSelectionOnLaunch: true,
            ShuttlePreferenceKey.restoreScrollbackOnReopen: true,
            ShuttlePreferenceKey.defaultSessionLayoutID: LayoutPresetStore.defaultPresetID,
            ShuttlePreferenceKey.defaultTryLayoutID: LayoutPresetStore.defaultPresetID,
            ShuttlePreferenceKey.seedMultiProjectAgentGuide: true,
            ShuttlePreferenceKey.workspaceSidebarPinnedExpanded: true,
            ShuttlePreferenceKey.workspaceSidebarRecentExpanded: true,
            ShuttlePreferenceKey.workspaceSidebarProjectExpanded: true,
            ShuttlePreferenceKey.workspaceSidebarTryExpanded: true,
            ShuttlePreferenceKey.pinnedWorkspaceKeys: emptyPinnedWorkspaceKeysStorage,
            ShuttlePreferenceKey.sessionSidebarArchivedExpanded: false,
            ShuttlePreferenceKey.sessionSidebarProjectsExpanded: false,
            ShuttlePreferenceKey.bellMarksAttention: true,
        ])
    }

    static var reopenPreviousSelectionOnLaunch: Bool {
        defaults.object(forKey: ShuttlePreferenceKey.reopenPreviousSelectionOnLaunch) as? Bool ?? true
    }

    static var restoreScrollbackOnReopen: Bool {
        defaults.object(forKey: ShuttlePreferenceKey.restoreScrollbackOnReopen) as? Bool ?? true
    }

    static var defaultSessionLayoutID: String {
        defaults.string(forKey: ShuttlePreferenceKey.defaultSessionLayoutID) ?? LayoutPresetStore.defaultPresetID
    }

    static var defaultTryLayoutID: String {
        defaults.string(forKey: ShuttlePreferenceKey.defaultTryLayoutID) ?? LayoutPresetStore.defaultPresetID
    }

    static var seedMultiProjectAgentGuide: Bool {
        defaults.object(forKey: ShuttlePreferenceKey.seedMultiProjectAgentGuide) as? Bool ?? true
    }

    static var bellMarksAttention: Bool {
        defaults.object(forKey: ShuttlePreferenceKey.bellMarksAttention) as? Bool ?? true
    }

    static func sanitizeLayoutDefaults(validPresetIDs: Set<String>) {
        if !validPresetIDs.contains(defaultSessionLayoutID) {
            defaults.set(LayoutPresetStore.defaultPresetID, forKey: ShuttlePreferenceKey.defaultSessionLayoutID)
        }
        if !validPresetIDs.contains(defaultTryLayoutID) {
            defaults.set(LayoutPresetStore.defaultPresetID, forKey: ShuttlePreferenceKey.defaultTryLayoutID)
        }
    }

    static func replaceLayoutReference(from oldID: String, to newID: String) {
        if defaultSessionLayoutID == oldID {
            defaults.set(newID, forKey: ShuttlePreferenceKey.defaultSessionLayoutID)
        }
        if defaultTryLayoutID == oldID {
            defaults.set(newID, forKey: ShuttlePreferenceKey.defaultTryLayoutID)
        }
    }

    static func resetToDefaults() {
        defaults.set(true, forKey: ShuttlePreferenceKey.reopenPreviousSelectionOnLaunch)
        defaults.set(true, forKey: ShuttlePreferenceKey.restoreScrollbackOnReopen)
        defaults.set(LayoutPresetStore.defaultPresetID, forKey: ShuttlePreferenceKey.defaultSessionLayoutID)
        defaults.set(LayoutPresetStore.defaultPresetID, forKey: ShuttlePreferenceKey.defaultTryLayoutID)
        defaults.set(true, forKey: ShuttlePreferenceKey.seedMultiProjectAgentGuide)
        defaults.set(true, forKey: ShuttlePreferenceKey.bellMarksAttention)
        defaults.set(true, forKey: ShuttlePreferenceKey.workspaceSidebarPinnedExpanded)
        defaults.set(true, forKey: ShuttlePreferenceKey.workspaceSidebarRecentExpanded)
        defaults.set(true, forKey: ShuttlePreferenceKey.workspaceSidebarProjectExpanded)
        defaults.set(true, forKey: ShuttlePreferenceKey.workspaceSidebarTryExpanded)
        defaults.set(emptyPinnedWorkspaceKeysStorage, forKey: ShuttlePreferenceKey.pinnedWorkspaceKeys)
        defaults.set(false, forKey: ShuttlePreferenceKey.sessionSidebarArchivedExpanded)
        defaults.set(false, forKey: ShuttlePreferenceKey.sessionSidebarProjectsExpanded)
    }

    static func decodePinnedWorkspaceKeys(from storage: String) -> Set<String> {
        guard let data = storage.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(keys)
    }

    static func encodePinnedWorkspaceKeys(_ keys: Set<String>) -> String {
        let sortedKeys = Array(keys).sorted()
        guard let data = try? JSONEncoder().encode(sortedKeys),
              let storage = String(data: data, encoding: .utf8) else {
            return emptyPinnedWorkspaceKeysStorage
        }
        return storage
    }
}

struct GhosttyConfigLocation: Identifiable, Hashable {
    let title: String
    let note: String
    let url: URL

    var id: String { url.path }
}

enum ShuttleExternalPaths {
    static var shuttlePaths: ShuttlePaths {
        ShuttlePaths()
    }

    static var ghosttyConfigLocations: [GhosttyConfigLocation] {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let macOSBaseURL = homeURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "com.mitchellh.ghostty", directoryHint: .isDirectory)
        let xdgBaseURL = ghosttyXDGConfigHomeURL
            .appending(path: "ghostty", directoryHint: .isDirectory)

        let locations = [
            GhosttyConfigLocation(
                title: "macOS config.ghostty",
                note: "Load order 1 · macOS-specific · current filename",
                url: macOSBaseURL.appending(path: "config.ghostty")
            ),
            GhosttyConfigLocation(
                title: "macOS config",
                note: "Load order 2 · macOS-specific · legacy filename",
                url: macOSBaseURL.appending(path: "config")
            ),
            GhosttyConfigLocation(
                title: "XDG config.ghostty",
                note: "Load order 3 · XDG path · current filename",
                url: xdgBaseURL.appending(path: "config.ghostty")
            ),
            GhosttyConfigLocation(
                title: "XDG config",
                note: "Load order 4 · XDG path · legacy filename",
                url: xdgBaseURL.appending(path: "config")
            ),
        ]

        var seen = Set<String>()
        return locations.filter { seen.insert($0.url.path).inserted }
    }

    static var ghosttyXDGConfigHomeURL: URL {
        if let configured = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            return URL(fileURLWithPath: expandedPath(configured), isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config", directoryHint: .isDirectory)
    }

    static func ensureShuttleConfigExists() {
        try? ConfigManager(paths: shuttlePaths).ensureDefaultConfigExists()
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
