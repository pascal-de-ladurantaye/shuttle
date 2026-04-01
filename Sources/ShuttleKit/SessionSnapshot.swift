import Foundation

public enum ShuttleSessionSnapshotSchema {
    public static let currentVersion = 1
}

public struct ShuttleRestorableTabSnapshot: Codable, Hashable, Sendable {
    public var tabRawID: Int64
    public var title: String
    public var cwd: String
    public var scrollback: String?

    public init(tabRawID: Int64, title: String, cwd: String, scrollback: String?) {
        self.tabRawID = tabRawID
        self.title = title
        self.cwd = cwd
        self.scrollback = scrollback
    }
}

public struct ShuttlePaneSelectionSnapshot: Codable, Hashable, Sendable {
    public var paneRawID: Int64
    public var activeTabRawID: Int64

    public init(paneRawID: Int64, activeTabRawID: Int64) {
        self.paneRawID = paneRawID
        self.activeTabRawID = activeTabRawID
    }
}

public struct ShuttleSelectedSessionSnapshot: Codable, Hashable, Sendable {
    public var bundle: SessionBundle
    public var tabSnapshots: [ShuttleRestorableTabSnapshot]
    public var paneSelections: [ShuttlePaneSelectionSnapshot]
    public var focusedTabRawID: Int64?

    public init(
        bundle: SessionBundle,
        tabSnapshots: [ShuttleRestorableTabSnapshot],
        paneSelections: [ShuttlePaneSelectionSnapshot] = [],
        focusedTabRawID: Int64? = nil
    ) {
        self.bundle = bundle
        self.tabSnapshots = tabSnapshots
        self.paneSelections = paneSelections
        self.focusedTabRawID = focusedTabRawID
    }

    public func tabSnapshot(rawID: Int64) -> ShuttleRestorableTabSnapshot? {
        tabSnapshots.first(where: { $0.tabRawID == rawID })
    }

    public func applying(to liveBundle: SessionBundle) -> SessionBundle {
        guard bundle.session.rawID == liveBundle.session.rawID else { return liveBundle }

        var restored = liveBundle
        if !bundle.panes.isEmpty {
            restored.panes = bundle.panes
        }

        let snapshotStates = Dictionary(uniqueKeysWithValues: tabSnapshots.map { ($0.tabRawID, $0) })
        let baseTabs = bundle.tabs.isEmpty ? liveBundle.tabs : bundle.tabs
        restored.tabs = baseTabs.map { baseTab in
            var tab = baseTab
            if let snapshot = snapshotStates[tab.rawID] {
                tab.title = snapshot.title
                tab.cwd = snapshot.cwd
                tab.runtimeStatus = .idle
            }
            return tab
        }
        return restored
    }
}

public struct ShuttleAppSessionSnapshot: Codable, Hashable, Sendable {
    public var version: Int
    public var savedAt: Date
    public var selectedWorkspaceID: Int64?
    public var selectedSessionID: Int64?
    public var selectedSession: ShuttleSelectedSessionSnapshot?

    public init(
        version: Int = ShuttleSessionSnapshotSchema.currentVersion,
        savedAt: Date,
        selectedWorkspaceID: Int64?,
        selectedSessionID: Int64?,
        selectedSession: ShuttleSelectedSessionSnapshot?
    ) {
        self.version = version
        self.savedAt = savedAt
        self.selectedWorkspaceID = selectedWorkspaceID
        self.selectedSessionID = selectedSessionID
        self.selectedSession = selectedSession
    }
}

public enum ShuttleSessionSnapshotStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load(paths: ShuttlePaths = ShuttlePaths()) -> ShuttleAppSessionSnapshot? {
        let url = snapshotURL(paths: paths)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? decoder.decode(ShuttleAppSessionSnapshot.self, from: data) else {
            return nil
        }
        guard snapshot.version == ShuttleSessionSnapshotSchema.currentVersion else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    public static func save(_ snapshot: ShuttleAppSessionSnapshot, paths: ShuttlePaths = ShuttlePaths()) -> Bool {
        do {
            try paths.ensureDirectories()
            let url = snapshotURL(paths: paths)
            let data = try encoder.encode(snapshot)
            if let existing = try? Data(contentsOf: url), existing == data {
                return true
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func remove(paths: ShuttlePaths = ShuttlePaths()) {
        try? FileManager.default.removeItem(at: snapshotURL(paths: paths))
    }

    public static func snapshotURL(paths: ShuttlePaths = ShuttlePaths()) -> URL {
        paths.appSupportURL.appending(path: "session-snapshot.json")
    }
}
