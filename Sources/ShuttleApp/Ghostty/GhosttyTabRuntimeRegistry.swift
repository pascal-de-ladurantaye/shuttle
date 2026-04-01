import AppKit
import Foundation
import ShuttleKit

struct GhosttyTabRuntimeSnapshotState {
    let tabRawID: Int64
    let title: String
    let currentWorkingDirectory: String?
    let scrollback: String?
}

struct GhosttyTabOutputCursorHandle {
    let token: String
    let capturedAt: Date
}

struct GhosttyTabReadCapture {
    let text: String
    let lineCount: Int
    let afterCursor: GhosttyTabOutputCursorHandle?
    let cursor: GhosttyTabOutputCursorHandle
    let isIncremental: Bool
}

@MainActor
final class GhosttyTabRuntime: ObservableObject {
    struct HostLease: Equatable {
        let hostId: ObjectIdentifier
        let instanceSerial: UInt64
    }

    let runtimeKey: String
    let surfaceView: GhosttyNSView

    private let tabRawID: Int64?
    private let initialWorkingDirectory: String?
    private let initialCommand: String?
    private let initialEnvironmentVariables: [String: String]
    private var observers: [NSObjectProtocol] = []
    private var activeHostLease: HostLease?
    private var queuedInitialCommand = false

    @Published private(set) var title: String
    @Published private(set) var currentWorkingDirectory: String?

    var runtimeTabRawID: Int64? { tabRawID }

    init(
        runtimeKey: String,
        workingDirectory: String?,
        command: String?,
        environmentVariables: [String: String]
    ) {
        self.runtimeKey = runtimeKey
        self.tabRawID = Self.parseTabRawID(from: runtimeKey)
        self.initialWorkingDirectory = workingDirectory
        self.initialCommand = command
        self.initialEnvironmentVariables = environmentVariables
        self.surfaceView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.title = Self.initialTitle(
            workingDirectory: workingDirectory,
            command: command,
            environmentVariables: environmentVariables
        )
        self.currentWorkingDirectory = workingDirectory
        installObservers()
    }

    func ensureSurface() {
        if surfaceView.surface == nil {
            guard GhosttyRuntime.shared.isReady else { return }
            surfaceView.createSurface(
                workingDirectory: initialWorkingDirectory,
                environmentVariables: initialEnvironmentVariables
            )
        }

        guard !queuedInitialCommand,
              let initialCommand,
              !initialCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              surfaceView.surface != nil else {
            return
        }

        queuedInitialCommand = true
        surfaceView.queueStartupText(initialCommand)
    }

    private static func parseTabRawID(from runtimeKey: String) -> Int64? {
        let components = runtimeKey.split(separator: ":", maxSplits: 1)
        guard components.count == 2, components[0] == "tab", let rawID = Int64(components[1]) else {
            return nil
        }
        return rawID
    }

    private static func initialTitle(
        workingDirectory: String?,
        command: String?,
        environmentVariables: [String: String]
    ) -> String {
        if let command {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return idleTitle(for: workingDirectory, environmentVariables: environmentVariables)
    }

    private static func idleTitle(
        for workingDirectory: String?,
        environmentVariables: [String: String]
    ) -> String {
        let fallbackTitle = environmentVariables["SHUTTLE_SESSION_NAME"] ?? "shell"
        guard let normalizedCwd = normalizedPath(workingDirectory) else {
            return fallbackTitle
        }

        if let sessionRoot = normalizedPath(environmentVariables["SHUTTLE_SESSION_ROOT"]),
           let relative = relativePath(from: sessionRoot, to: normalizedCwd) {
            if !relative.isEmpty {
                return relative
            }
            let rootName = URL(fileURLWithPath: sessionRoot).lastPathComponent
            return rootName.isEmpty ? fallbackTitle : rootName
        }

        if let projectPath = normalizedPath(environmentVariables["SHUTTLE_PROJECT_PATH"]),
           let relative = relativePath(from: projectPath, to: normalizedCwd) {
            let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
            if relative.isEmpty {
                return projectName.isEmpty ? fallbackTitle : projectName
            }
            if !projectName.isEmpty {
                return "\(projectName)/\(relative)"
            }
            return relative
        }

        let basename = URL(fileURLWithPath: normalizedCwd).lastPathComponent
        return basename.isEmpty ? fallbackTitle : basename
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    private static func relativePath(from root: String, to path: String) -> String? {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let normalizedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path

        if normalizedPath == normalizedRoot {
            return ""
        }
        let prefix = normalizedRoot + "/"
        guard normalizedPath.hasPrefix(prefix) else {
            return nil
        }
        return String(normalizedPath.dropFirst(prefix.count))
    }

    func claimHost(hostId: ObjectIdentifier, instanceSerial: UInt64) -> Bool {
        let newLease = HostLease(hostId: hostId, instanceSerial: instanceSerial)
        if let current = activeHostLease {
            if current == newLease {
                return true
            }
            if current.instanceSerial > newLease.instanceSerial {
                return false
            }
        }
        activeHostLease = newLease
        return true
    }

    func releaseHost(hostId: ObjectIdentifier) {
        guard activeHostLease?.hostId == hostId else { return }
        activeHostLease = nil
    }

    func captureSnapshotState(includeScrollback: Bool) -> GhosttyTabRuntimeSnapshotState? {
        guard let tabRawID else { return nil }
        return GhosttyTabRuntimeSnapshotState(
            tabRawID: tabRawID,
            title: title,
            currentWorkingDirectory: currentWorkingDirectory,
            scrollback: includeScrollback ? surfaceView.captureScrollback() : nil
        )
    }

    func matches(tabRawID: Int64) -> Bool {
        self.tabRawID == tabRawID
    }

    func captureScrollbackCheckpoint() async {
        guard let tabRawID else { return }
        await GhosttyCheckpointWriter.shared.schedule(
            tabRawID: tabRawID,
            title: title,
            cwd: currentWorkingDirectory
        )
        guard let scrollback = surfaceView.captureScrollback() else { return }
        await GhosttyCheckpointWriter.shared.scheduleScrollback(tabRawID: tabRawID, scrollback: scrollback)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttySurfaceTitleChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
            let title = note.userInfo?["title"] as? String
            Task { @MainActor [weak self] in
                guard let self,
                      let surfaceId,
                      surfaceId == self.surfaceView.surfaceId,
                      let title,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                self.title = title
                if let tabRawID = self.tabRawID {
                    GhosttyTabRuntimeRegistry.shared.noteLiveTitle(title, for: tabRawID)
                    Task {
                        await GhosttyCheckpointWriter.shared.schedule(tabRawID: tabRawID, title: title)
                    }
                }
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttySurfacePwdChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
            let pwd = note.userInfo?["pwd"] as? String
            Task { @MainActor [weak self] in
                guard let self,
                      let surfaceId,
                      surfaceId == self.surfaceView.surfaceId,
                      let pwd,
                      !pwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                self.currentWorkingDirectory = pwd
                if let tabRawID = self.tabRawID {
                    GhosttyTabRuntimeRegistry.shared.noteLiveWorkingDirectory(pwd, for: tabRawID)
                    // Shuttle emits OSC 7 on each prompt return, so this path gives
                    // us a post-exec/prompt checkpoint without coupling scrollback
                    // capture to live title updates.
                    let scrollback = ShuttlePreferences.restoreScrollbackOnReopen
                        ? self.surfaceView.captureScrollback()
                        : nil
                    Task {
                        await GhosttyCheckpointWriter.shared.schedule(tabRawID: tabRawID, cwd: pwd)
                        if let scrollback {
                            await GhosttyCheckpointWriter.shared.scheduleScrollback(tabRawID: tabRawID, scrollback: scrollback)
                        }
                    }
                }
            }
        })
    }
}

@MainActor
final class GhosttyTabRuntimeRegistry: ObservableObject {
    static let shared = GhosttyTabRuntimeRegistry()
    private static let maxStoredCursorSnapshots = 512

    @Published private(set) var liveTitlesByTabRawID: [Int64: String] = [:]
    @Published private(set) var liveWorkingDirectoryByTabRawID: [Int64: String] = [:]

    private var runtimes: [String: GhosttyTabRuntime] = [:]
    private var cursorSnapshotsByToken: [String: CursorSnapshot] = [:]
    private var cursorSnapshotOrder: [String] = []

    private struct CursorSnapshot {
        let token: String
        let tabRawID: Int64
        let mode: ShuttleTabReadMode
        let text: String
        let capturedAt: Date
    }

    private init() {}

    func runtime(
        for runtimeKey: String,
        workingDirectory: String?,
        command: String?,
        environmentVariables: [String: String]
    ) -> GhosttyTabRuntime {
        if let existing = runtimes[runtimeKey] {
            return existing
        }

        let created = GhosttyTabRuntime(
            runtimeKey: runtimeKey,
            workingDirectory: workingDirectory,
            command: command,
            environmentVariables: environmentVariables
        )
        runtimes[runtimeKey] = created
        if let tabRawID = created.runtimeTabRawID {
            noteLiveTitle(created.title, for: tabRawID)
            noteLiveWorkingDirectory(created.currentWorkingDirectory, for: tabRawID)
        }
        return created
    }

    func remove(runtimeKey: String) {
        if let removed = runtimes.removeValue(forKey: runtimeKey),
           let tabRawID = removed.runtimeTabRawID {
            liveTitlesByTabRawID.removeValue(forKey: tabRawID)
            liveWorkingDirectoryByTabRawID.removeValue(forKey: tabRawID)
            discardCursorSnapshots(for: tabRawID)
        }
    }

    func noteLiveTitle(_ title: String, for tabRawID: Int64) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if liveTitlesByTabRawID[tabRawID] != trimmed {
            liveTitlesByTabRawID[tabRawID] = trimmed
        }
    }

    func noteLiveWorkingDirectory(_ workingDirectory: String?, for tabRawID: Int64) {
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if liveWorkingDirectoryByTabRawID[tabRawID] != trimmed {
            liveWorkingDirectoryByTabRawID[tabRawID] = trimmed
        }
    }

    func liveTitle(for tabRawID: Int64, fallbackTitle: String) -> String {
        let fallback = fallbackTitle.isEmpty ? "shell" : fallbackTitle
        if let live = liveTitlesByTabRawID[tabRawID], !live.isEmpty {
            return live
        }
        return fallback
    }

    func hasRuntime(tabRawID: Int64) -> Bool {
        runtimes.values.contains(where: { $0.matches(tabRawID: tabRawID) })
    }

    @discardableResult
    func send(text: String, submit: Bool, to tabRawID: Int64) -> Bool {
        guard let runtime = runtimes.values.first(where: { $0.matches(tabRawID: tabRawID) }) else {
            return false
        }
        runtime.ensureSurface()
        return runtime.surfaceView.sendText(text, submit: submit)
    }

    func captureCursor(tabRawID: Int64, mode: ShuttleTabReadMode, maxLines: Int) -> GhosttyTabOutputCursorHandle? {
        guard let text = read(tabRawID: tabRawID, mode: mode, maxLines: maxLines) else {
            return nil
        }
        return storeCursorSnapshot(tabRawID: tabRawID, mode: mode, text: text)
    }

    func readCapture(
        tabRawID: Int64,
        mode: ShuttleTabReadMode,
        maxLines: Int,
        afterCursorToken: String?
    ) throws -> GhosttyTabReadCapture {
        let captured = read(tabRawID: tabRawID, mode: mode, maxLines: maxLines) ?? ""
        let afterSnapshot = try afterCursorToken.map { try resolveCursorSnapshot(token: $0, tabRawID: tabRawID, mode: mode) }
        let returnedText: String
        if let afterSnapshot {
            returnedText = shuttleIncrementalTerminalText(previous: afterSnapshot.text, current: captured)
        } else {
            returnedText = captured
        }
        let cursor = storeCursorSnapshot(tabRawID: tabRawID, mode: mode, text: captured)
        let lineCount = returnedText.isEmpty ? 0 : returnedText.split(separator: "\n", omittingEmptySubsequences: false).count
        return GhosttyTabReadCapture(
            text: returnedText,
            lineCount: lineCount,
            afterCursor: afterSnapshot.map { GhosttyTabOutputCursorHandle(token: $0.token, capturedAt: $0.capturedAt) },
            cursor: cursor,
            isIncremental: afterSnapshot != nil
        )
    }

    func read(tabRawID: Int64, mode: ShuttleTabReadMode, maxLines: Int) -> String? {
        guard let runtime = runtimes.values.first(where: { $0.matches(tabRawID: tabRawID) }) else {
            return nil
        }
        runtime.ensureSurface()
        switch mode {
        case .screen:
            return runtime.surfaceView.captureVisibleScreen(maxLines: maxLines)
        case .scrollback:
            return runtime.surfaceView.captureScrollback(maxLines: maxLines)
        }
    }

    private func resolveCursorSnapshot(token: String, tabRawID: Int64, mode: ShuttleTabReadMode) throws -> CursorSnapshot {
        guard let snapshot = cursorSnapshotsByToken[token] else {
            throw ShuttleError.invalidArguments(
                "Cursor '\(token)' is no longer available; capture a fresh cursor with tab send/read/wait and retry"
            )
        }
        guard snapshot.tabRawID == tabRawID else {
            throw ShuttleError.invalidArguments("Cursor '\(token)' belongs to a different tab")
        }
        guard snapshot.mode == mode else {
            throw ShuttleError.invalidArguments(
                "Cursor '\(token)' was captured in \(snapshot.mode.rawValue) mode; retry with --mode \(snapshot.mode.rawValue)"
            )
        }
        return snapshot
    }

    private func storeCursorSnapshot(tabRawID: Int64, mode: ShuttleTabReadMode, text: String) -> GhosttyTabOutputCursorHandle {
        let token = UUID().uuidString
        let capturedAt = Date()
        let snapshot = CursorSnapshot(token: token, tabRawID: tabRawID, mode: mode, text: text, capturedAt: capturedAt)
        cursorSnapshotsByToken[token] = snapshot
        cursorSnapshotOrder.removeAll(where: { $0 == token })
        cursorSnapshotOrder.append(token)
        pruneCursorSnapshotsIfNeeded()
        return GhosttyTabOutputCursorHandle(token: token, capturedAt: capturedAt)
    }

    private func discardCursorSnapshots(for tabRawID: Int64) {
        let tokens = cursorSnapshotsByToken.values
            .filter { $0.tabRawID == tabRawID }
            .map(\.token)
        guard !tokens.isEmpty else { return }
        let tokenSet = Set(tokens)
        for token in tokens {
            cursorSnapshotsByToken.removeValue(forKey: token)
        }
        cursorSnapshotOrder.removeAll(where: { tokenSet.contains($0) })
    }

    private func pruneCursorSnapshotsIfNeeded() {
        while cursorSnapshotOrder.count > Self.maxStoredCursorSnapshots {
            let removedToken = cursorSnapshotOrder.removeFirst()
            cursorSnapshotsByToken.removeValue(forKey: removedToken)
        }
    }

    @discardableResult
    func focus(tabRawID: Int64) -> Bool {
        guard let runtime = runtimes.values.first(where: { $0.matches(tabRawID: tabRawID) }) else {
            return false
        }
        runtime.ensureSurface()
        guard let window = runtime.surfaceView.window else {
            return false
        }
        TerminalFocusCoordinator.shared.setActiveSurfaceView(runtime.surfaceView)
        window.makeFirstResponder(runtime.surfaceView)
        return true
    }

    func captureSnapshotStates(includeScrollback: Bool) -> [Int64: GhosttyTabRuntimeSnapshotState] {
        Dictionary(
            uniqueKeysWithValues: runtimes.values.compactMap { runtime in
                runtime.captureSnapshotState(includeScrollback: includeScrollback).map {
                    ($0.tabRawID, $0)
                }
            }
        )
    }

    func captureAllScrollbackSnapshots() async {
        for runtime in runtimes.values {
            await runtime.captureScrollbackCheckpoint()
        }
    }

    func removeAll() {
        runtimes.removeAll()
        liveTitlesByTabRawID.removeAll()
        liveWorkingDirectoryByTabRawID.removeAll()
        cursorSnapshotsByToken.removeAll()
        cursorSnapshotOrder.removeAll()
    }
}
