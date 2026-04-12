import SwiftUI
import AppKit
import ShuttleKit

@MainActor
final class ShuttleAppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var workspaces: [WorkspaceDetails] = []
    @Published var configuredProjectRoots: [String] = []
    @Published var selectedWorkspaceID: Int64?
    @Published var selectedSessionID: Int64?
    @Published var sessionBundle: SessionBundle?
    @Published private(set) var attentionCountsBySessionRawID: [Int64: Int] = [:]
    @Published var toasts: [ShuttleToast] = []
    @Published var bootstrapHint = ""
    @Published private(set) var isScanningProjects = false
    @Published private(set) var focusedPaneRawID: Int64?
    @Published private(set) var focusedTabRawID: Int64?
    @Published private(set) var activeTabRawIDByPaneRawID: [Int64: Int64] = [:]
    @Published private var pendingRestoredSessionIDs: Set<Int64> = []

    private let paths: ShuttlePaths
    private let store: WorkspaceStore?
    private let controlService: ShuttleControlCommandService?
    private var controlServer: ShuttleControlServer?
    private var didPrepareForLaunch = false
    private var startupRestoreSnapshot: ShuttleAppSessionSnapshot?
    private var currentSessionSnapshot: ShuttleAppSessionSnapshot?
    private var activeTabRawIDBySessionRawID: [Int64: [Int64: Int64]] = [:]
    private var lastFocusedTabRawIDBySessionRawID: [Int64: Int64] = [:]
    private var pendingProgrammaticFocusRestore: (sessionRawID: Int64, tabRawID: Int64)?
    private var sessionRefreshGeneration: UInt64 = 0
    private var terminalFocusRequestGeneration: UInt64 = 0
    private var startupSnapshotAppliedSessionIDs: Set<Int64> = []
    private var snapshotAutosaveTask: Task<Void, Never>?
    private var toastDismissTasks: [UUID: Task<Void, Never>] = [:]
    private var replayEnvironmentByTabRawID: [Int64: [String: String]] = [:]
    // Note: observer tokens are declared as nonisolated(unsafe) above deinit.

    // Observer tokens are stored as nonisolated(unsafe) so they can be
    // cleaned up in deinit, which is nonisolated for @MainActor classes.
    // Safe because they are only written from @MainActor init/install methods.
    nonisolated(unsafe) private var _bellObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var _desktopNotificationObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var _surfaceCloseObserver: (any NSObjectProtocol)?

    deinit {
        if let _bellObserver {
            NotificationCenter.default.removeObserver(_bellObserver)
        }
        if let _desktopNotificationObserver {
            NotificationCenter.default.removeObserver(_desktopNotificationObserver)
        }
        if let _surfaceCloseObserver {
            NotificationCenter.default.removeObserver(_surfaceCloseObserver)
        }
    }

    init() {
        let paths = ShuttlePaths()
        self.paths = paths
        let snapshot = ShuttlePreferences.reopenPreviousSelectionOnLaunch
            ? ShuttleSessionSnapshotStore.load(paths: paths)
            : nil
        self.startupRestoreSnapshot = snapshot
        self.currentSessionSnapshot = snapshot
        self.selectedWorkspaceID = snapshot?.selectedWorkspaceID
        self.selectedSessionID = snapshot?.selectedSessionID
        if let selectedSession = snapshot?.selectedSession {
            let sessionRawID = selectedSession.bundle.session.rawID
            if !selectedSession.paneSelections.isEmpty {
                self.activeTabRawIDBySessionRawID[sessionRawID] = Dictionary(
                    uniqueKeysWithValues: selectedSession.paneSelections.map { ($0.paneRawID, $0.activeTabRawID) }
                )
            }
            if let focusedTabRawID = selectedSession.focusedTabRawID {
                self.lastFocusedTabRawIDBySessionRawID[sessionRawID] = focusedTabRawID
            }
        }

        do {
            let store = try WorkspaceStore(paths: paths)
            self.store = store
            self.controlService = ShuttleControlCommandService(store: store)
            Task {
                await GhosttyCheckpointWriter.shared.configure(store: store)
            }
            startControlServerIfNeeded()
        } catch {
            self.store = nil
            self.controlService = nil
            self.toasts = [ShuttleToast(kind: .error, message: "Failed to initialize Shuttle: \(error.localizedDescription)")]
        }
        installBellObserver()
        installDesktopNotificationObserver()
        installSurfaceCloseObserver()
    }

    private func installBellObserver() {
        _bellObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceBellRang,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
            Task { @MainActor [weak self] in
                self?.handleBellForSurface(surfaceId)
            }
        }
    }

    private func installSurfaceCloseObserver() {
        _surfaceCloseObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceDidClose,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
            Task { @MainActor [weak self] in
                self?.handleSurfaceClose(surfaceId)
            }
        }
    }

    private func handleSurfaceClose(_ surfaceId: UUID?) {
        guard let surfaceId else { return }

        let registry = GhosttyTabRuntimeRegistry.shared
        guard let store, let bundle = sessionBundle else { return }
        guard let tab = bundle.tabs.first(where: { registry.surfaceIdMatches(tabRawID: $0.rawID, surfaceId: surfaceId) }) else { return }

        // Mark the tab as exited so the CLI can report it accurately.
        Task {
            do {
                try await store.markTabExited(rawID: tab.rawID)
            } catch {
                // Best-effort — don't toast for background bookkeeping.
            }

            // Update the in-memory bundle so the UI reflects the change immediately.
            if var updatedBundle = self.sessionBundle,
               let idx = updatedBundle.tabs.firstIndex(where: { $0.rawID == tab.rawID }) {
                updatedBundle.tabs[idx].runtimeStatus = .exited
                self.sessionBundle = updatedBundle
            }
        }
    }

    private func installDesktopNotificationObserver() {
        _desktopNotificationObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceDesktopNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
            let title = note.userInfo?["title"] as? String
            let body = note.userInfo?["body"] as? String
            Task { @MainActor [weak self] in
                self?.handleDesktopNotificationForSurface(surfaceId, title: title, body: body)
            }
        }
    }

    private func handleDesktopNotificationForSurface(_ surfaceId: UUID?, title: String?, body: String?) {
        guard let surfaceId else { return }

        let registry = GhosttyTabRuntimeRegistry.shared
        guard let bundle = sessionBundle else { return }
        guard let tab = bundle.tabs.first(where: { registry.surfaceIdMatches(tabRawID: $0.rawID, surfaceId: surfaceId) }) else { return }
        guard focusedTabRawID != tab.rawID else { return }

        let message: String? = {
            let parts = [title, body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ": ")
        }()

        guard let store else { return }
        Task {
            do {
                try await store.markTabAttention(sessionToken: bundle.session.id, tabRawID: tab.rawID, message: message)
                if var updatedBundle = sessionBundle {
                    updatedBundle.tabs = updatedBundle.tabs.map { t in
                        var mutable = t
                        if mutable.rawID == tab.rawID {
                            mutable.needsAttention = true
                            mutable.attentionMessage = message
                        }
                        return mutable
                    }
                    sessionBundle = updatedBundle
                }
                refreshAttentionCounts()
            } catch {
                // Best-effort.
            }
        }
    }

    private func handleBellForSurface(_ surfaceId: UUID?) {
        guard ShuttlePreferences.bellMarksAttention else { return }
        guard let surfaceId else { return }

        let registry = GhosttyTabRuntimeRegistry.shared
        // Find the tab rawID for this surface
        guard let bundle = sessionBundle else { return }
        guard let tab = bundle.tabs.first(where: { registry.surfaceIdMatches(tabRawID: $0.rawID, surfaceId: surfaceId) }) else { return }

        // Don't mark the currently focused tab
        guard focusedTabRawID != tab.rawID else { return }
        guard !tab.needsAttention else { return }

        guard let store else { return }
        Task {
            do {
                try await store.markTabAttention(sessionToken: bundle.session.id, tabRawID: tab.rawID, message: nil)
                if var updatedBundle = sessionBundle {
                    updatedBundle.tabs = updatedBundle.tabs.map { t in
                        var mutable = t
                        if mutable.rawID == tab.rawID {
                            mutable.needsAttention = true
                            mutable.attentionMessage = nil
                        }
                        return mutable
                    }
                    sessionBundle = updatedBundle
                }
                refreshAttentionCounts()
            } catch {
                // Best-effort.
            }
        }
    }

    private func startControlServerIfNeeded() {
        guard controlServer == nil else { return }
        let server = ShuttleControlServer(paths: paths) { [weak self] command in
            guard let self else {
                throw ShuttleError.io("Shuttle app is no longer available to serve control requests")
            }
            return try await self.handleControlCommand(command)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            showErrorToast("Failed to start Shuttle control server: \(error.localizedDescription)")
        }
    }

    private func stopControlServer() {
        controlServer?.stop()
        controlServer = nil
    }

    var configFilePath: String {
        paths.configURL.path
    }

    private func normalizedConfiguredProjectRoots(from config: ShuttleConfig) -> [String] {
        let roots = config.expandedProjectRoots.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        return Array(NSOrderedSet(array: roots)) as? [String] ?? roots
    }

    func dismissToast(id: UUID) {
        toastDismissTasks[id]?.cancel()
        toastDismissTasks.removeValue(forKey: id)
        withAnimation(.easeInOut(duration: 0.18)) {
            toasts.removeAll { $0.id == id }
        }
    }

    private func showSuccessToast(_ message: String) {
        showToast(.success, message: message, autoDismissAfterNanoseconds: 3_000_000_000)
    }

    private func showInfoToast(_ message: String) {
        showToast(.info, message: message, autoDismissAfterNanoseconds: 8_000_000_000)
    }

    private func showErrorToast(_ message: String) {
        showToast(.error, message: message)
    }

    private func showToast(
        _ kind: ShuttleToast.Kind,
        message: String,
        autoDismissAfterNanoseconds: UInt64? = nil
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        let toast = ShuttleToast(kind: kind, message: trimmedMessage)
        withAnimation(.easeOut(duration: 0.18)) {
            toasts.append(toast)
        }

        guard let autoDismissAfterNanoseconds else { return }
        toastDismissTasks[toast.id]?.cancel()
        toastDismissTasks[toast.id] = Task { [weak self, toastID = toast.id] in
            try? await Task.sleep(nanoseconds: autoDismissAfterNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.toasts.contains(where: { $0.id == toastID }) == true else { return }
                self?.dismissToast(id: toastID)
            }
        }
    }

    private func presentScanNotifications(for report: ScanReport, showDiscoverySummary: Bool) {
        if showDiscoverySummary {
            showSuccessToast("Discovered \(report.discoveredProjects.count) projects")
        }

        guard !report.removedWorkspaces.isEmpty else { return }
        showInfoToast(removedWorkspacesToastMessage(for: report.removedWorkspaces))
    }

    private func removedWorkspacesToastMessage(for workspaces: [Workspace]) -> String {
        let sortedNames = workspaces.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let visibleNames = Array(sortedNames.prefix(5))
        let header: String
        if sortedNames.count == 1 {
            header = "Removed 1 workspace no longer present on disk:"
        } else {
            header = "Removed \(sortedNames.count) workspaces no longer present on disk:"
        }

        var lines = visibleNames.map { "• \($0)" }
        if sortedNames.count > visibleNames.count {
            lines.append("• +\(sortedNames.count - visibleNames.count) more")
        }
        return ([header] + lines).joined(separator: "\n")
    }

    private func handleControlCommand(_ command: ShuttleControlCommand) async throws -> ShuttleControlValue {
        guard let controlService else {
            throw ShuttleError.io("Shuttle control service is not initialized yet")
        }

        switch command {
        case .workspaceOpen(let workspaceToken):
            persistSessionSnapshot(includeScrollback: true)
            await GhosttyCheckpointWriter.shared.flushAll()
            let details = try await controlService.store.workspaceDetails(token: workspaceToken)
            await selectWorkspace(details.workspace.rawID)
            return .workspaceDetails(try await controlService.store.workspaceDetails(token: workspaceToken))
        case .sessionOpen(let sessionToken):
            persistSessionSnapshot(includeScrollback: true)
            await GhosttyCheckpointWriter.shared.flushAll()
            let activation = try await controlService.store.activateSession(token: sessionToken)
            await applyControlSessionActivation(activation)
            return .sessionActivation(activation)
        case .tabSend(let sessionToken, let tabToken, let text, let submit):
            return .tabSendResult(
                try await performControlTabSend(
                    sessionToken: sessionToken,
                    tabToken: tabToken,
                    text: text,
                    submit: submit
                )
            )
        case .tabRead(let sessionToken, let tabToken, let mode, let maxLines, let afterCursorToken):
            return .tabReadResult(
                try await performControlTabRead(
                    sessionToken: sessionToken,
                    tabToken: tabToken,
                    mode: mode,
                    maxLines: maxLines,
                    waitForText: nil,
                    timeoutMilliseconds: 0,
                    afterCursorToken: afterCursorToken
                )
            )
        case .tabWait(let sessionToken, let tabToken, let text, let mode, let maxLines, let timeoutMilliseconds, let afterCursorToken):
            return .tabReadResult(
                try await performControlTabRead(
                    sessionToken: sessionToken,
                    tabToken: tabToken,
                    mode: mode,
                    maxLines: maxLines,
                    waitForText: text,
                    timeoutMilliseconds: timeoutMilliseconds,
                    afterCursorToken: afterCursorToken
                )
            )
        case .tabFocus(let sessionToken, let tabToken):
            let existing = try await controlService.store.sessionBundle(token: sessionToken)
            let tab = try ShuttleControlCommandService.resolveTab(in: existing, token: tabToken)
            selectTab(tab.rawID)
            return .sessionBundle(existing)
        case .sessionClose(let sessionToken), .sessionEnsureClosed(let sessionToken):
            try await checkpointVisibleSessionIfNeeded(sessionToken: sessionToken, includeScrollback: true)
        case .layoutApply(let sessionToken, _), .layoutEnsureApplied(let sessionToken, _):
            try await checkpointVisibleSessionIfNeeded(sessionToken: sessionToken, includeScrollback: true)
        case .layoutSaveCurrent(let sessionToken, _, _):
            try await checkpointVisibleSessionIfNeeded(sessionToken: sessionToken, includeScrollback: false)
        default:
            break
        }

        let result = try await controlService.execute(command)
        await applyControlCommandResult(result, for: command)
        return result
    }

    private func applyControlCommandResult(_ result: ShuttleControlValue, for command: ShuttleControlCommand) async {
        guard command.isMutation else { return }

        switch (command, result) {
        case (.sessionNew, .sessionBundle(let bundle)):
            selectedWorkspaceID = bundle.workspace.rawID
            selectedSessionID = bundle.session.rawID
            upsertSession(bundle.session, in: bundle.workspace)
            applySessionBundleUpdate(bundle, preferredFocusedTabRawID: bundle.tabs.first?.rawID)
        case (.sessionEnsure, .sessionMutationResult(let result)):
            if result.status.changed {
                selectedWorkspaceID = result.bundle.workspace.rawID
                selectedSessionID = result.bundle.session.rawID
                upsertSession(result.bundle.session, in: result.bundle.workspace)
                applySessionBundleUpdate(result.bundle, preferredFocusedTabRawID: result.bundle.tabs.first?.rawID)
            }
        case (.sessionRename, .sessionBundle(let bundle)):
            upsertSession(bundle.session, in: bundle.workspace)
            if isVisibleSession(bundle.session.rawID) {
                applySessionBundleUpdate(bundle)
            }
        case (.sessionClose, .sessionBundle(let bundle)):
            upsertSession(bundle.session, in: bundle.workspace)
            await applyClosedSessionBundle(bundle)
        case (.sessionEnsureClosed, .sessionMutationResult(let result)):
            if result.status.changed {
                upsertSession(result.bundle.session, in: result.bundle.workspace)
                await applyClosedSessionBundle(result.bundle)
            }
        case (.layoutApply, .sessionBundle(let bundle)):
            upsertSession(bundle.session, in: bundle.workspace)
            if isVisibleSession(bundle.session.rawID) {
                applySessionBundleUpdate(bundle, preferredFocusedTabRawID: bundle.tabs.first?.rawID)
            }
        case (.layoutEnsureApplied, .layoutMutationResult(let result)):
            if result.status.changed {
                upsertSession(result.bundle.session, in: result.bundle.workspace)
                if isVisibleSession(result.bundle.session.rawID) {
                    applySessionBundleUpdate(result.bundle, preferredFocusedTabRawID: result.bundle.tabs.first?.rawID)
                }
            }
        case (.paneSplit, .sessionBundle(let bundle)), (.tabNew, .sessionBundle(let bundle)):
            if isVisibleSession(bundle.session.rawID) {
                let preferredFocusedTabRawID = newestAddedTabRawID(previous: sessionBundle, updated: bundle)
                applySessionBundleUpdate(bundle, preferredFocusedTabRawID: preferredFocusedTabRawID)
            }
        case (.paneResize, .sessionBundle(let bundle)), (.tabClose, .sessionBundle(let bundle)):
            if isVisibleSession(bundle.session.rawID) {
                applySessionBundleUpdate(bundle)
            }
        case (.tabMarkAttention, .sessionBundle(let bundle)), (.tabClearAttention, .sessionBundle(let bundle)):
            if isVisibleSession(bundle.session.rawID) {
                applySessionBundleUpdate(bundle)
            }
            refreshAttentionCounts()
        default:
            break
        }
    }

    func refresh(initialScanIfNeeded: Bool = false) async {
        guard let store else { return }
        do {
            if !didPrepareForLaunch {
                try await store.prepareForAppLaunch()
                didPrepareForLaunch = true
            }

            bootstrapHint = await store.bootstrapHint()
            var details = try await store.listWorkspaces()
            let hasProjectWorkspaces = details.contains { !$0.projects.isEmpty }
            let shouldPerformInitialScan = initialScanIfNeeded && !hasProjectWorkspaces
            var initialScanReport: ScanReport?
            if shouldPerformInitialScan {
                isScanningProjects = true
                defer { isScanningProjects = false }
                initialScanReport = try await store.scanProjects()
                details = try await store.listWorkspaces()
            }
            projects = try await store.listProjects()
            if let config = try? await store.config() {
                configuredProjectRoots = normalizedConfiguredProjectRoots(from: config)
            } else {
                configuredProjectRoots = []
            }
            workspaces = details
            refreshAttentionCounts()
            startSnapshotAutosaveIfNeeded()
            restoreSelectionIfNeeded(from: details)
            await refreshSelectedSession()
            if let initialScanReport {
                presentScanNotifications(for: initialScanReport, showDiscoverySummary: false)
            }
        } catch {
            showErrorToast(error.localizedDescription)
        }
    }

    func scanProjects() async {
        guard let store, !isScanningProjects else { return }
        isScanningProjects = true
        defer { isScanningProjects = false }

        do {
            let report = try await store.scanProjects()
            await refresh()
            presentScanNotifications(for: report, showDiscoverySummary: true)
        } catch {
            showErrorToast(error.localizedDescription)
        }
    }

    func createSession(workspaceToken: String, name: String?, layoutName: String?) async throws {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }

        do {
            let bundle = try await store.createSession(
                workspaceToken: workspaceToken,
                name: name,
                layoutName: layoutName,
                seedAgentGuide: ShuttlePreferences.seedMultiProjectAgentGuide
            )
            selectedWorkspaceID = bundle.workspace.rawID
            selectedSessionID = bundle.session.rawID
            sessionBundle = bundle
            syncSessionMetadataLocally(bundle.session)
            focusedTabRawID = bundle.tabs.first?.rawID
            reconcileTabSelection(for: bundle)
            persistSessionSnapshot(includeScrollback: false)
            await refresh()
        } catch {
            throw error
        }
    }

    func renameSession(sessionRawID: Int64, name: String) async throws {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }

        do {
            let bundle = try await store.renameSession(token: Session.makeRef(sessionRawID), name: name)
            upsertSession(bundle.session, in: bundle.workspace)
            if isVisibleSession(bundle.session.rawID) {
                applySessionBundleUpdate(bundle)
            }
            showSuccessToast("Renamed session to \(bundle.session.name)")
        } catch {
            throw error
        }
    }

    func closeSession(sessionRawID: Int64) async throws {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }

        do {
            try await checkpointVisibleSessionIfNeeded(sessionToken: Session.makeRef(sessionRawID), includeScrollback: true)
            let bundle = try await store.closeSession(token: Session.makeRef(sessionRawID))
            upsertSession(bundle.session, in: bundle.workspace)
            await applyClosedSessionBundle(bundle)
            showSuccessToast("Closed session \(bundle.session.name)")
        } catch {
            throw error
        }
    }

    func selectWorkspace(_ rawID: Int64?) async {
        selectedWorkspaceID = rawID
        if let workspace = selectedWorkspace,
           selectedSessionID == nil || !workspace.sessions.contains(where: { $0.rawID == selectedSessionID }) {
            selectedSessionID = mostRecentSession(in: workspace)?.rawID
        }
        await refreshSelectedSession()
        persistSessionSnapshot(includeScrollback: false)
    }

    func selectSession(_ rawID: Int64?) async {
        selectedSessionID = rawID
        await refreshSelectedSession()
        persistSessionSnapshot(includeScrollback: false)
    }

    func createTrySession(name: String, sessionName: String?, layoutName: String?) async throws {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }

        do {
            let bundle = try await store.createTrySession(
                name: name,
                sessionName: sessionName,
                layoutName: layoutName,
                seedAgentGuide: ShuttlePreferences.seedMultiProjectAgentGuide
            )
            selectedWorkspaceID = bundle.workspace.rawID
            selectedSessionID = bundle.session.rawID
            sessionBundle = bundle
            syncSessionMetadataLocally(bundle.session)
            focusedTabRawID = bundle.tabs.first?.rawID
            reconcileTabSelection(for: bundle)
            persistSessionSnapshot(includeScrollback: false)
            await refresh()
        } catch {
            throw error
        }
    }

    func restoreMessage(for sessionRawID: Int64) -> String? {
        guard pendingRestoredSessionIDs.contains(sessionRawID) else { return nil }
        if ShuttlePreferences.restoreScrollbackOnReopen {
            return "Restored after app relaunch. The previous shell exited when Shuttle quit, so this is a fresh shell started from the last checkpointed directory. Any checkpointed scrollback is replayed above."
        }
        return "Restored after app relaunch. The previous shell exited when Shuttle quit, so this is a fresh shell started from the last checkpointed directory."
    }

    func restoreEnvironment(for sessionRawID: Int64, tabRawID: Int64) -> [String: String] {
        guard pendingRestoredSessionIDs.contains(sessionRawID), ShuttlePreferences.restoreScrollbackOnReopen else {
            return [:]
        }
        if let cached = replayEnvironmentByTabRawID[tabRawID] {
            return cached
        }
        let snapshotScrollback = currentSessionSnapshot?.selectedSession?.bundle.session.rawID == sessionRawID
            ? currentSessionSnapshot?.selectedSession?.tabSnapshot(rawID: tabRawID)?.scrollback
            : startupRestoreSnapshot?.selectedSession?.bundle.session.rawID == sessionRawID
                ? startupRestoreSnapshot?.selectedSession?.tabSnapshot(rawID: tabRawID)?.scrollback
                : nil
        if let scrollback = snapshotScrollback {
            let environment = ShuttleScrollbackReplayStore.replayEnvironment(for: scrollback)
            replayEnvironmentByTabRawID[tabRawID] = environment
            return environment
        }
        return ShuttleScrollbackReplayStore.replayEnvironment(forTabRawID: tabRawID, paths: paths)
    }

    private func checkpointVisibleSessionIfNeeded(sessionToken: String, includeScrollback: Bool) async throws {
        guard let store else { return }
        let targetBundle = try await store.sessionBundle(token: sessionToken)
        guard sessionBundle?.session.rawID == targetBundle.session.rawID else {
            return
        }
        persistSessionSnapshot(includeScrollback: includeScrollback)
        await GhosttyCheckpointWriter.shared.flushAll()
    }

    private func applyControlSessionActivation(_ activation: SessionActivation) async {
        let bundle = activation.bundle
        selectedWorkspaceID = bundle.workspace.rawID
        selectedSessionID = bundle.session.rawID
        if activation.wasRestored {
            pendingRestoredSessionIDs.insert(bundle.session.rawID)
        }
        syncSessionMetadataLocally(bundle.session)
        activeTabRawIDByPaneRawID = rememberedActiveTabRawIDByPaneRawID(for: bundle)
        focusedTabRawID = rememberedFocusedTabRawID(for: bundle)
        if let focusedTabRawID {
            pendingProgrammaticFocusRestore = (bundle.session.rawID, focusedTabRawID)
        } else {
            pendingProgrammaticFocusRestore = nil
        }
        sessionBundle = bundle
        reconcileTabSelection(for: bundle)
        if let focusedTabRawID {
            requestTerminalFocus(forTabRawID: focusedTabRawID)
        }
        persistSessionSnapshot(includeScrollback: false)
        await GhosttyCheckpointWriter.shared.flushAll()
    }

    private func applyClosedSessionBundle(_ bundle: SessionBundle) async {
        let tabRawIDs = bundle.tabs.map(\.rawID)
        if sessionBundle?.session.rawID == bundle.session.rawID || selectedSessionID == bundle.session.rawID {
            for tabRawID in tabRawIDs {
                GhosttyTabRuntimeRegistry.shared.remove(runtimeKey: Tab.makeRef(tabRawID))
                replayEnvironmentByTabRawID.removeValue(forKey: tabRawID)
            }
            cancelPendingTerminalFocusRequests()
            activeTabRawIDBySessionRawID.removeValue(forKey: bundle.session.rawID)
            lastFocusedTabRawIDBySessionRawID.removeValue(forKey: bundle.session.rawID)
            pendingRestoredSessionIDs.remove(bundle.session.rawID)
            if let replacementSessionRawID = replacementSessionRawID(afterClosing: bundle.session.rawID, workspaceRawID: bundle.workspace.rawID) {
                selectedWorkspaceID = bundle.workspace.rawID
                selectedSessionID = replacementSessionRawID
                await refreshSelectedSession()
            } else {
                selectedWorkspaceID = bundle.workspace.rawID
                selectedSessionID = nil
                sessionBundle = nil
                focusedPaneRawID = nil
                focusedTabRawID = nil
                pendingProgrammaticFocusRestore = nil
                activeTabRawIDByPaneRawID = [:]
                persistSessionSnapshot(includeScrollback: false)
            }
        }
    }

    private func replacementSessionRawID(afterClosing sessionRawID: Int64, workspaceRawID: Int64) -> Int64? {
        guard let workspace = workspaces.first(where: { $0.workspace.rawID == workspaceRawID }) else {
            return nil
        }
        let candidates = workspace.sessions
            .filter { $0.rawID != sessionRawID && $0.status != .closed }
            .sorted(by: sessionListSort)
        return candidates.first?.rawID
    }

    private func resolveControlTabContext(sessionToken: String, tabToken: String) async throws -> (bundle: SessionBundle, tab: ShuttleKit.Tab) {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }

        persistSessionSnapshot(includeScrollback: true)
        await GhosttyCheckpointWriter.shared.flushAll()

        let activation = try await store.activateSession(token: sessionToken)
        await applyControlSessionActivation(activation)
        let resolvedTab = try ShuttleControlCommandService.resolveTab(in: activation.bundle, token: tabToken)
        guard await waitForRuntimeTab(tabRawID: resolvedTab.rawID, timeoutMilliseconds: 2_000) else {
            throw ShuttleError.io("Tab runtime for \(resolvedTab.id) is not ready yet")
        }
        return (activation.bundle, resolvedTab)
    }

    private func waitForRuntimeTab(tabRawID: Int64, timeoutMilliseconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(max(timeoutMilliseconds, 0)) / 1000.0)
        while Date() <= deadline {
            if GhosttyTabRuntimeRegistry.shared.hasRuntime(tabRawID: tabRawID) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return GhosttyTabRuntimeRegistry.shared.hasRuntime(tabRawID: tabRawID)
    }

    private func performControlTabSend(sessionToken: String, tabToken: String, text: String, submit: Bool) async throws -> ShuttleTabSendResult {
        let (bundle, tab) = try await resolveControlTabContext(sessionToken: sessionToken, tabToken: tabToken)
        let cursor = GhosttyTabRuntimeRegistry.shared.captureCursor(tabRawID: tab.rawID, mode: .scrollback, maxLines: 400).map {
            ShuttleTabOutputCursor(token: $0.token, tabID: tab.id, mode: .scrollback, capturedAt: $0.capturedAt)
        }

        guard GhosttyTabRuntimeRegistry.shared.send(text: text, submit: submit, to: tab.rawID) else {
            throw ShuttleError.io("Failed to send text to \(tab.id)")
        }

        return ShuttleTabSendResult(
            session: bundle.session,
            workspace: bundle.workspace,
            tab: tab,
            text: text,
            submitted: submit,
            sentAt: Date(),
            cursor: cursor
        )
    }

    private func performControlTabRead(
        sessionToken: String,
        tabToken: String,
        mode: ShuttleTabReadMode,
        maxLines: Int,
        waitForText: String?,
        timeoutMilliseconds: Int,
        afterCursorToken: String?
    ) async throws -> ShuttleTabReadResult {
        let (bundle, tab) = try await resolveControlTabContext(sessionToken: sessionToken, tabToken: tabToken)
        let trimmedExpected = waitForText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = Date().addingTimeInterval(Double(max(timeoutMilliseconds, 0)) / 1000.0)

        func capture() throws -> GhosttyTabReadCapture {
            try GhosttyTabRuntimeRegistry.shared.readCapture(
                tabRawID: tab.rawID,
                mode: mode,
                maxLines: maxLines,
                afterCursorToken: afterCursorToken
            )
        }

        var captured = try capture()
        if let expected = trimmedExpected, !expected.isEmpty {
            while !captured.text.contains(expected) {
                guard Date() <= deadline else {
                    throw ShuttleError.io("Timed out waiting for text '\(expected)' in \(tab.id)")
                }
                try? await Task.sleep(for: .milliseconds(200))
                captured = try capture()
            }
        }

        let afterCursor = captured.afterCursor.map {
            ShuttleTabOutputCursor(token: $0.token, tabID: tab.id, mode: mode, capturedAt: $0.capturedAt)
        }
        let cursor = ShuttleTabOutputCursor(
            token: captured.cursor.token,
            tabID: tab.id,
            mode: mode,
            capturedAt: captured.cursor.capturedAt
        )

        return ShuttleTabReadResult(
            session: bundle.session,
            workspace: bundle.workspace,
            tab: tab,
            mode: mode,
            text: captured.text,
            lineCount: captured.lineCount,
            capturedAt: captured.cursor.capturedAt,
            matchedText: trimmedExpected,
            afterCursor: afterCursor,
            cursor: cursor,
            isIncremental: captured.isIncremental
        )
    }

    var canSplitFocusedPane: Bool {
        guard let bundle = sessionBundle else { return false }
        return focusedSourceTab(in: bundle) != nil
    }

    var canCreateTabInFocusedPane: Bool {
        guard let bundle = sessionBundle else { return false }
        return preferredPaneRawID(in: bundle) != nil
    }

    var canCloseFocusedTab: Bool {
        focusedTabRawID != nil
    }

    func setFocusedTab(_ rawID: Int64?, userInitiated: Bool = false) {
        guard let bundle = sessionBundle else {
            focusedTabRawID = rawID
            return
        }

        if userInitiated {
            pendingProgrammaticFocusRestore = nil
        } else {
            guard let pendingProgrammaticFocusRestore,
                  pendingProgrammaticFocusRestore.sessionRawID == bundle.session.rawID,
                  rawID == pendingProgrammaticFocusRestore.tabRawID else {
                return
            }
        }

        if let rawID {
            guard let tab = bundle.tabs.first(where: { $0.rawID == rawID }) else {
                return
            }
            focusedTabRawID = rawID
            focusedPaneRawID = tab.paneID
            activeTabRawIDByPaneRawID[tab.paneID] = rawID
            var rememberedSelections = activeTabRawIDBySessionRawID[bundle.session.rawID] ?? [:]
            rememberedSelections[tab.paneID] = rawID
            activeTabRawIDBySessionRawID[bundle.session.rawID] = rememberedSelections
            lastFocusedTabRawIDBySessionRawID[bundle.session.rawID] = rawID
            if userInitiated {
                clearAttentionIfNeeded(tabRawID: rawID)
            }
        } else {
            focusedTabRawID = nil
            lastFocusedTabRawIDBySessionRawID.removeValue(forKey: bundle.session.rawID)
        }
    }

    func selectTab(_ rawID: Int64) {
        setFocusedTab(rawID, userInitiated: true)
        requestTerminalFocus(forTabRawID: rawID)
        clearAttentionIfNeeded(tabRawID: rawID)
    }

    private func clearAttentionIfNeeded(tabRawID: Int64) {
        guard let store, let bundle = sessionBundle,
              let tab = bundle.tabs.first(where: { $0.rawID == tabRawID }),
              tab.needsAttention else {
            return
        }
        Task {
            do {
                try await store.clearTabAttention(sessionToken: bundle.session.id, tabRawID: tabRawID)
                if var updatedBundle = sessionBundle {
                    updatedBundle.tabs = updatedBundle.tabs.map { t in
                        var mutable = t
                        if mutable.rawID == tabRawID {
                            mutable.needsAttention = false
                            mutable.attentionMessage = nil
                        }
                        return mutable
                    }
                    sessionBundle = updatedBundle
                }
                refreshAttentionCounts()
            } catch {
                // Best-effort; don't toast on attention-clear failures.
            }
        }
    }

    func refreshAttentionCounts() {
        guard let store else { return }
        Task {
            do {
                attentionCountsBySessionRawID = try await store.attentionCountsBySession()
            } catch {
                // Best-effort; stale counts are acceptable.
            }
        }
    }

    func activeTab(in paneRawID: Int64, tabs: [ShuttleKit.Tab]) -> ShuttleKit.Tab? {
        if let activeRawID = activeTabRawIDByPaneRawID[paneRawID],
           let tab = tabs.first(where: { $0.rawID == activeRawID }) {
            return tab
        }
        return tabs.first
    }

    func isActiveTab(_ rawID: Int64, paneRawID: Int64) -> Bool {
        activeTabRawIDByPaneRawID[paneRawID] == rawID
    }

    func isFocusedTab(_ rawID: Int64) -> Bool {
        focusedTabRawID == rawID
    }

    func isFocusedPane(_ rawID: Int64) -> Bool {
        focusedPaneRawID == rawID
    }

    func createTabInFocusedPane() async {
        guard let bundle = sessionBundle,
              let paneRawID = preferredPaneRawID(in: bundle) else {
            showErrorToast("No active pane to create a tab in")
            return
        }
        await createTab(inPaneRawID: paneRawID, sourceTabRawID: focusedSourceTab(in: bundle)?.rawID)
    }

    func createTab(inPaneRawID paneRawID: Int64, sourceTabRawID: Int64? = nil) async {
        guard let store, let bundle = sessionBundle else { return }
        let sourceTab = sourceTabRawID.flatMap { rawID in
            bundle.tabs.first(where: { $0.rawID == rawID && $0.paneID == paneRawID })
        } ?? activeTab(in: paneRawID, tabs: tabs(inPaneRawID: paneRawID, bundle: bundle))

        do {
            let oldTabIDs = Set(bundle.tabs.map(\.rawID))
            let updatedBundle = try await store.createTab(
                sessionToken: bundle.session.id,
                paneRawID: paneRawID,
                sourceTabRawID: sourceTab?.rawID
            )
            sessionBundle = updatedBundle
            syncSessionMetadataLocally(updatedBundle.session)
            reconcileTabSelection(for: updatedBundle)
            if let newTabRawID = updatedBundle.tabs.first(where: { !oldTabIDs.contains($0.rawID) })?.rawID {
                selectTab(newTabRawID)
            } else if let focusedTabRawID {
                requestTerminalFocus(forTabRawID: focusedTabRawID)
            }
            persistSessionSnapshot(includeScrollback: false)
        } catch {
            showErrorToast(error.localizedDescription)
        }
    }

    func closeFocusedTab() async {
        guard let focusedTabRawID else { return }
        await closeTab(focusedTabRawID)
    }

    func closeTab(_ rawID: Int64) async {
        guard let store, let bundle = sessionBundle,
              let targetTab = bundle.tabs.first(where: { $0.rawID == rawID }) else { return }

        let siblingTabs = tabs(inPaneRawID: targetTab.paneID, bundle: bundle).filter { $0.rawID != targetTab.rawID }
        let fallbackTabRawID = siblingTabs.first?.rawID

        do {
            let updatedBundle = try await store.closeTab(sessionToken: bundle.session.id, tabRawID: targetTab.rawID)
            GhosttyTabRuntimeRegistry.shared.remove(runtimeKey: targetTab.runtimeKey)
            replayEnvironmentByTabRawID.removeValue(forKey: targetTab.rawID)
            sessionBundle = updatedBundle
            syncSessionMetadataLocally(updatedBundle.session)
            reconcileTabSelection(for: updatedBundle)

            if let fallbackTabRawID,
               updatedBundle.tabs.contains(where: { $0.rawID == fallbackTabRawID }) {
                selectTab(fallbackTabRawID)
            } else if updatedBundle.panes.contains(where: { $0.rawID == targetTab.paneID }) && updatedBundle.tabs.isEmpty {
                focusedPaneRawID = targetTab.paneID
                focusedTabRawID = nil
                cancelPendingTerminalFocusRequests()
            } else if let focusedTabRawID {
                requestTerminalFocus(forTabRawID: focusedTabRawID)
            }

            persistSessionSnapshot(includeScrollback: false)
        } catch {
            showErrorToast(error.localizedDescription)
        }
    }

    func splitFocusedPane(direction: SplitDirection) async {
        guard let store, let bundle = sessionBundle else { return }
        guard let sourceTab = focusedSourceTab(in: bundle) else {
            showErrorToast("No active terminal pane to split")
            return
        }

        do {
            let oldTabIDs = Set(bundle.tabs.map(\.rawID))
            let updatedBundle = try await store.splitPane(
                sessionToken: bundle.session.id,
                paneRawID: sourceTab.paneID,
                direction: direction,
                sourceTabRawID: sourceTab.rawID
            )
            sessionBundle = updatedBundle
            syncSessionMetadataLocally(updatedBundle.session)
            focusedTabRawID = updatedBundle.tabs.first(where: { !oldTabIDs.contains($0.rawID) })?.rawID ?? sourceTab.rawID
            reconcileTabSelection(for: updatedBundle)
            if let focusedTabRawID {
                requestTerminalFocus(forTabRawID: focusedTabRawID)
            }
            persistSessionSnapshot(includeScrollback: false)
        } catch {
            showErrorToast(error.localizedDescription)
        }
    }

    func setPaneRatioLocally(paneRawID: Int64, ratio: Double) {
        guard var bundle = sessionBundle else { return }
        guard let index = bundle.panes.firstIndex(where: { $0.rawID == paneRawID }) else { return }
        bundle.panes[index].ratio = normalizedPaneRatio(ratio)
        sessionBundle = bundle
    }

    func resizePane(paneRawID: Int64, ratio: Double) async {
        let normalizedRatio = normalizedPaneRatio(ratio)
        setPaneRatioLocally(paneRawID: paneRawID, ratio: normalizedRatio)
        persistSessionSnapshot(includeScrollback: false)

        guard let store, let sessionToken = sessionBundle?.session.id else { return }
        do {
            try await store.resizePane(sessionToken: sessionToken, paneRawID: paneRawID, ratio: normalizedRatio)
        } catch {
            showErrorToast(error.localizedDescription)
        }
    }

    func persistActiveSnapshot(includeScrollback: Bool) {
        persistSessionSnapshot(includeScrollback: includeScrollback)
    }

    func prepareForTermination() async {
        persistSessionSnapshot(includeScrollback: true)
        await GhosttyCheckpointWriter.shared.flushAll()
        stopControlServer()
    }

    func previewDeleteSession(sessionRawID: Int64) async throws -> SessionDeletionPreview {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }
        return try await store.previewDeleteSession(token: Session.makeRef(sessionRawID))
    }

    func deleteSession(sessionRawID: Int64) async throws {
        guard let store else {
            throw ShuttleError.io("Shuttle is not initialized yet")
        }

        let token = Session.makeRef(sessionRawID)
        let bundle = try await store.sessionBundle(token: token)
        let tabRawIDs = bundle.tabs.map(\.rawID)
        let isVisibleSession = sessionBundle?.session.rawID == sessionRawID || selectedSessionID == sessionRawID

        await GhosttyCheckpointWriter.shared.discard(tabRawIDs: tabRawIDs)
        discardSessionStateForDeletion(sessionRawID: sessionRawID, tabRawIDs: tabRawIDs, clearVisibleBundle: isVisibleSession)
        await Task.yield()

        do {
            _ = try await store.deleteSession(token: token)
            await refresh()
        } catch {
            if isVisibleSession {
                selectedWorkspaceID = bundle.workspace.rawID
                selectedSessionID = sessionRawID
            }
            await refresh()
            throw error
        }
    }

    var selectedWorkspace: WorkspaceDetails? {
        guard let selectedWorkspaceID else { return workspaces.first }
        return workspaces.first(where: { $0.workspace.rawID == selectedWorkspaceID }) ?? workspaces.first
    }

    private func focusedSourceTab(in bundle: SessionBundle) -> ShuttleKit.Tab? {
        if let focusedTabRawID,
           let focused = bundle.tabs.first(where: { $0.rawID == focusedTabRawID }) {
            return focused
        }
        return bundle.tabs.first
    }

    private func modelPaneSort(_ lhs: Pane, _ rhs: Pane) -> Bool {
        if lhs.positionIndex == rhs.positionIndex {
            return lhs.rawID < rhs.rawID
        }
        return lhs.positionIndex < rhs.positionIndex
    }

    private func leafPanes(in bundle: SessionBundle) -> [Pane] {
        let parentIDs = Set(bundle.panes.compactMap(\.parentPaneID))
        return bundle.panes
            .filter { !parentIDs.contains($0.rawID) }
            .sorted(by: modelPaneSort)
    }

    private func preferredPaneRawID(in bundle: SessionBundle) -> Int64? {
        if let focusedTab = focusedSourceTab(in: bundle) {
            return focusedTab.paneID
        }
        if let focusedPaneRawID,
           bundle.panes.contains(where: { $0.rawID == focusedPaneRawID }) {
            return focusedPaneRawID
        }
        return leafPanes(in: bundle).first?.rawID
    }

    private func tabs(inPaneRawID paneRawID: Int64, bundle: SessionBundle) -> [ShuttleKit.Tab] {
        bundle.tabs
            .filter { $0.paneID == paneRawID }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
    }

    private func rememberedFocusedTabRawID(for bundle: SessionBundle) -> Int64? {
        guard let remembered = lastFocusedTabRawIDBySessionRawID[bundle.session.rawID] else {
            return nil
        }
        guard bundle.tabs.contains(where: { $0.rawID == remembered }) else {
            lastFocusedTabRawIDBySessionRawID.removeValue(forKey: bundle.session.rawID)
            return nil
        }
        return remembered
    }

    private func rememberedActiveTabRawIDByPaneRawID(for bundle: SessionBundle) -> [Int64: Int64] {
        let remembered = activeTabRawIDBySessionRawID[bundle.session.rawID] ?? [:]
        guard !remembered.isEmpty else { return [:] }

        let validSelections = remembered.filter { paneRawID, tabRawID in
            bundle.tabs.contains(where: { $0.rawID == tabRawID && $0.paneID == paneRawID })
        }
        if validSelections.count != remembered.count {
            activeTabRawIDBySessionRawID[bundle.session.rawID] = validSelections
        }
        return validSelections
    }

    private func reconcileTabSelection(for bundle: SessionBundle) {
        var nextSelection: [Int64: Int64] = [:]
        let sortedPanes = leafPanes(in: bundle)
        let rememberedSelections = rememberedActiveTabRawIDByPaneRawID(for: bundle)

        for pane in sortedPanes {
            let paneTabs = tabs(inPaneRawID: pane.rawID, bundle: bundle)
            guard !paneTabs.isEmpty else { continue }
            if let rememberedRawID = rememberedSelections[pane.rawID],
               paneTabs.contains(where: { $0.rawID == rememberedRawID }) {
                nextSelection[pane.rawID] = rememberedRawID
            } else if let existingRawID = activeTabRawIDByPaneRawID[pane.rawID],
                      paneTabs.contains(where: { $0.rawID == existingRawID }) {
                nextSelection[pane.rawID] = existingRawID
            } else {
                nextSelection[pane.rawID] = paneTabs.first?.rawID
            }
        }

        let resolvedFocusedTabRawID: Int64?
        if let currentFocusedTabRawID = focusedTabRawID,
           bundle.tabs.contains(where: { $0.rawID == currentFocusedTabRawID }) {
            resolvedFocusedTabRawID = currentFocusedTabRawID
        } else {
            resolvedFocusedTabRawID = rememberedFocusedTabRawID(for: bundle)
                ?? sortedPanes.compactMap { nextSelection[$0.rawID] }.first
        }

        if let resolvedFocusedTabRawID,
           let focusedTab = bundle.tabs.first(where: { $0.rawID == resolvedFocusedTabRawID }) {
            focusedTabRawID = focusedTab.rawID
            focusedPaneRawID = focusedTab.paneID
            nextSelection[focusedTab.paneID] = focusedTab.rawID
        } else {
            focusedTabRawID = nil
            if let focusedPaneRawID,
               sortedPanes.contains(where: { $0.rawID == focusedPaneRawID }) {
                self.focusedPaneRawID = focusedPaneRawID
            } else {
                focusedPaneRawID = sortedPanes.first?.rawID
            }
        }

        activeTabRawIDByPaneRawID = nextSelection
        activeTabRawIDBySessionRawID[bundle.session.rawID] = nextSelection

        if let focusedTabRawID {
            lastFocusedTabRawIDBySessionRawID[bundle.session.rawID] = focusedTabRawID
        } else {
            lastFocusedTabRawIDBySessionRawID.removeValue(forKey: bundle.session.rawID)
        }
    }

    private func cancelPendingTerminalFocusRequests() {
        terminalFocusRequestGeneration &+= 1
    }

    private func requestTerminalFocus(forTabRawID rawID: Int64) {
        terminalFocusRequestGeneration &+= 1
        let requestGeneration = terminalFocusRequestGeneration

        Task { @MainActor in
            for attempt in 0..<4 {
                guard requestGeneration == terminalFocusRequestGeneration,
                      focusedTabRawID == rawID,
                      sessionBundle?.tabs.contains(where: { $0.rawID == rawID }) == true else {
                    return
                }

                if GhosttyTabRuntimeRegistry.shared.focus(tabRawID: rawID) {
                    return
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        }
    }

    private func discardSessionStateForDeletion(sessionRawID: Int64, tabRawIDs: [Int64], clearVisibleBundle: Bool) {
        cancelPendingTerminalFocusRequests()
        pendingRestoredSessionIDs.remove(sessionRawID)
        activeTabRawIDBySessionRawID.removeValue(forKey: sessionRawID)
        lastFocusedTabRawIDBySessionRawID.removeValue(forKey: sessionRawID)

        for tabRawID in tabRawIDs {
            GhosttyTabRuntimeRegistry.shared.remove(runtimeKey: Tab.makeRef(tabRawID))
            replayEnvironmentByTabRawID.removeValue(forKey: tabRawID)
        }

        let snapshotMatchesSession = currentSessionSnapshot?.selectedSessionID == sessionRawID
            || currentSessionSnapshot?.selectedSession?.bundle.session.rawID == sessionRawID
            || startupRestoreSnapshot?.selectedSessionID == sessionRawID
            || startupRestoreSnapshot?.selectedSession?.bundle.session.rawID == sessionRawID
        if snapshotMatchesSession {
            ShuttleSessionSnapshotStore.remove(paths: paths)
            currentSessionSnapshot = nil
            startupRestoreSnapshot = nil
        }

        if selectedSessionID == sessionRawID {
            selectedSessionID = nil
        }

        if clearVisibleBundle {
            sessionBundle = nil
            focusedPaneRawID = nil
            focusedTabRawID = nil
            pendingProgrammaticFocusRestore = nil
            activeTabRawIDByPaneRawID = [:]
        }
    }

    private func isVisibleSession(_ sessionRawID: Int64) -> Bool {
        sessionBundle?.session.rawID == sessionRawID || selectedSessionID == sessionRawID
    }

    private func newestAddedTabRawID(previous: SessionBundle?, updated: SessionBundle) -> Int64? {
        guard let previous, previous.session.rawID == updated.session.rawID else {
            return updated.tabs.first?.rawID
        }
        let previousTabIDs = Set(previous.tabs.map(\.rawID))
        return updated.tabs.first(where: { !previousTabIDs.contains($0.rawID) })?.rawID
    }

    private func applySessionBundleUpdate(_ updatedBundle: SessionBundle, preferredFocusedTabRawID: Int64? = nil) {
        let previousBundle = sessionBundle?.session.rawID == updatedBundle.session.rawID ? sessionBundle : nil
        let updatedTabIDs = Set(updatedBundle.tabs.map(\.rawID))

        if let previousBundle {
            for removedTab in previousBundle.tabs where !updatedTabIDs.contains(removedTab.rawID) {
                GhosttyTabRuntimeRegistry.shared.remove(runtimeKey: removedTab.runtimeKey)
                replayEnvironmentByTabRawID.removeValue(forKey: removedTab.rawID)
            }
        }

        selectedWorkspaceID = updatedBundle.workspace.rawID
        selectedSessionID = updatedBundle.session.rawID
        sessionBundle = updatedBundle
        syncSessionMetadataLocally(updatedBundle.session)

        if let preferredFocusedTabRawID,
           updatedBundle.tabs.contains(where: { $0.rawID == preferredFocusedTabRawID }) {
            focusedTabRawID = preferredFocusedTabRawID
        } else if previousBundle == nil {
            focusedTabRawID = updatedBundle.tabs.first?.rawID
        }

        reconcileTabSelection(for: updatedBundle)
        persistSessionSnapshot(includeScrollback: false)
    }

    private func upsertSession(_ session: Session, in workspace: Workspace) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.workspace.rawID == workspace.rawID }) else {
            return
        }

        var updatedDetails = workspaces[workspaceIndex]
        updatedDetails.workspace = workspace
        if let sessionIndex = updatedDetails.sessions.firstIndex(where: { $0.rawID == session.rawID }) {
            updatedDetails.sessions[sessionIndex] = session
        } else {
            updatedDetails.sessions.append(session)
        }
        updatedDetails.sessions.sort(by: sessionListSort)
        workspaces[workspaceIndex] = updatedDetails
    }

    private func removeSession(_ sessionRawID: Int64, fromWorkspaceID workspaceRawID: Int64) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.workspace.rawID == workspaceRawID }) else {
            return
        }

        var updatedDetails = workspaces[workspaceIndex]
        updatedDetails.sessions.removeAll { $0.rawID == sessionRawID }
        workspaces[workspaceIndex] = updatedDetails
    }

    private func sessionListSort(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.lastActiveAt == rhs.lastActiveAt {
            return lhs.rawID > rhs.rawID
        }
        return lhs.lastActiveAt > rhs.lastActiveAt
    }

    private func syncSessionMetadataLocally(_ session: Session) {
        if sessionBundle?.session.rawID == session.rawID {
            sessionBundle?.session = session
        }

        workspaces = workspaces.map { details in
            guard let index = details.sessions.firstIndex(where: { $0.rawID == session.rawID }) else {
                return details
            }

            var updatedDetails = details
            updatedDetails.sessions[index] = session
            updatedDetails.sessions.sort(by: sessionListSort)
            return updatedDetails
        }
    }

    private func refreshSelectedSession() async {
        guard let store else { return }
        sessionRefreshGeneration &+= 1
        let refreshGeneration = sessionRefreshGeneration
        cancelPendingTerminalFocusRequests()

        guard let workspace = selectedWorkspace else {
            sessionBundle = nil
            focusedPaneRawID = nil
            focusedTabRawID = nil
            pendingProgrammaticFocusRestore = nil
            activeTabRawIDByPaneRawID = [:]
            return
        }
        if selectedSessionID == nil {
            selectedSessionID = mostRecentSession(in: workspace)?.rawID
        }
        guard let selectedSessionID else {
            sessionBundle = nil
            focusedPaneRawID = nil
            focusedTabRawID = nil
            pendingProgrammaticFocusRestore = nil
            activeTabRawIDByPaneRawID = [:]
            return
        }
        do {
            let activation = try await store.activateSession(token: Session.makeRef(selectedSessionID))
            guard refreshGeneration == sessionRefreshGeneration else { return }

            let startupSelectedSession = startupRestoreSnapshot?.selectedSession
            let shouldApplyStartupSnapshot = startupSelectedSession?.bundle.session.rawID == activation.bundle.session.rawID
                && !startupSnapshotAppliedSessionIDs.contains(activation.bundle.session.rawID)
            let resolvedBundle = shouldApplyStartupSnapshot
                ? (startupSelectedSession?.applying(to: activation.bundle) ?? activation.bundle)
                : activation.bundle
            if shouldApplyStartupSnapshot {
                startupSnapshotAppliedSessionIDs.insert(activation.bundle.session.rawID)
            }
            if activation.wasRestored || shouldApplyStartupSnapshot {
                pendingRestoredSessionIDs.insert(resolvedBundle.session.rawID)
            }
            syncSessionMetadataLocally(resolvedBundle.session)
            activeTabRawIDByPaneRawID = rememberedActiveTabRawIDByPaneRawID(for: resolvedBundle)
            focusedTabRawID = rememberedFocusedTabRawID(for: resolvedBundle)
            if let focusedTabRawID {
                pendingProgrammaticFocusRestore = (resolvedBundle.session.rawID, focusedTabRawID)
            } else {
                pendingProgrammaticFocusRestore = nil
            }
            sessionBundle = resolvedBundle
            reconcileTabSelection(for: resolvedBundle)
            if let focusedTabRawID {
                requestTerminalFocus(forTabRawID: focusedTabRawID)
            }
            persistSessionSnapshot(includeScrollback: false)
            await GhosttyCheckpointWriter.shared.flushAll()
        } catch {
            guard refreshGeneration == sessionRefreshGeneration else { return }
            sessionBundle = nil
            focusedPaneRawID = nil
            focusedTabRawID = nil
            pendingProgrammaticFocusRestore = nil
            activeTabRawIDByPaneRawID = [:]
        }
    }

    private func restoreSelectionIfNeeded(from details: [WorkspaceDetails]) {
        guard !details.isEmpty else {
            selectedWorkspaceID = nil
            selectedSessionID = nil
            return
        }

        if let selectedSessionID,
           let match = workspaceAndSession(for: selectedSessionID, in: details) {
            selectedWorkspaceID = match.workspace.workspace.rawID
            return
        }

        if let selectedWorkspaceID,
           let workspace = details.first(where: { $0.workspace.rawID == selectedWorkspaceID }) {
            self.selectedWorkspaceID = workspace.workspace.rawID
            selectedSessionID = mostRecentSession(in: workspace)?.rawID
            return
        }

        if let mostRecent = mostRecentWorkspaceAndSession(in: details) {
            selectedWorkspaceID = mostRecent.workspace.workspace.rawID
            selectedSessionID = mostRecent.session.rawID
            return
        }

        selectedWorkspaceID = details.first?.workspace.rawID
        if let firstWorkspace = details.first {
            selectedSessionID = mostRecentSession(in: firstWorkspace)?.rawID
        } else {
            selectedSessionID = nil
        }
    }

    private func workspaceAndSession(for sessionRawID: Int64, in details: [WorkspaceDetails]) -> (workspace: WorkspaceDetails, session: Session)? {
        for workspace in details {
            if let session = workspace.sessions.first(where: { $0.rawID == sessionRawID }) {
                return (workspace, session)
            }
        }
        return nil
    }

    private func mostRecentWorkspaceAndSession(in details: [WorkspaceDetails]) -> (workspace: WorkspaceDetails, session: Session)? {
        var best: (workspace: WorkspaceDetails, session: Session)?
        for workspace in details {
            guard let candidate = mostRecentSession(in: workspace) else { continue }
            if let best, best.session.lastActiveAt >= candidate.lastActiveAt {
                continue
            }
            best = (workspace, candidate)
        }
        return best
    }

    private func mostRecentSession(in workspace: WorkspaceDetails) -> Session? {
        workspace.sessions.max { lhs, rhs in
            if lhs.lastActiveAt == rhs.lastActiveAt {
                return lhs.rawID < rhs.rawID
            }
            return lhs.lastActiveAt < rhs.lastActiveAt
        }
    }

    private func normalizedPaneRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0.1), 0.9)
    }

    private func startSnapshotAutosaveIfNeeded() {
        guard snapshotAutosaveTask == nil else { return }
        snapshotAutosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.persistSnapshotFromAutosave()
            }
        }
    }

    private func persistSnapshotFromAutosave() async {
        // Match cmux more closely: the periodic autosave keeps layout/session
        // metadata fresh, but scrollback is checkpointed on prompt-return and
        // lifecycle boundaries instead of on every timer tick.
        persistSessionSnapshot(includeScrollback: false)
        await GhosttyCheckpointWriter.shared.flushAll()
    }

    private func persistSessionSnapshot(includeScrollback: Bool) {
        guard ShuttlePreferences.reopenPreviousSelectionOnLaunch else {
            ShuttleSessionSnapshotStore.remove(paths: paths)
            currentSessionSnapshot = nil
            return
        }

        let snapshot = buildSessionSnapshot(includeScrollback: includeScrollback && ShuttlePreferences.restoreScrollbackOnReopen)
        if ShuttleSessionSnapshotStore.save(snapshot, paths: paths) {
            currentSessionSnapshot = snapshot
        }
    }

    private func buildSessionSnapshot(includeScrollback: Bool) -> ShuttleAppSessionSnapshot {
        let runtimeStates = GhosttyTabRuntimeRegistry.shared.captureSnapshotStates(includeScrollback: includeScrollback)
        let fallbackSelectedSession = currentSessionSnapshot?.selectedSession

        let selectedSessionSnapshot: ShuttleSelectedSessionSnapshot? = sessionBundle.map { bundle in
            var snapshotBundle = bundle
            snapshotBundle.tabs = bundle.tabs.map { tab in
                var updatedTab = tab
                if let state = runtimeStates[tab.rawID] {
                    updatedTab.title = state.title
                    if let cwd = state.currentWorkingDirectory {
                        updatedTab.cwd = cwd
                    }
                    updatedTab.runtimeStatus = .idle
                } else if let fallback = fallbackSelectedSession?.tabSnapshot(rawID: tab.rawID) {
                    updatedTab.title = fallback.title
                    updatedTab.cwd = fallback.cwd
                }
                return updatedTab
            }

            let tabSnapshots = snapshotBundle.tabs.map { tab in
                let scrollback = runtimeStates[tab.rawID]?.scrollback
                    ?? (!includeScrollback ? fallbackSelectedSession?.tabSnapshot(rawID: tab.rawID)?.scrollback : nil)
                return ShuttleRestorableTabSnapshot(
                    tabRawID: tab.rawID,
                    title: tab.title,
                    cwd: tab.cwd,
                    scrollback: scrollback
                )
            }

            let paneSelections = rememberedActiveTabRawIDByPaneRawID(for: snapshotBundle)
                .map { ShuttlePaneSelectionSnapshot(paneRawID: $0.key, activeTabRawID: $0.value) }
                .sorted {
                    if $0.paneRawID == $1.paneRawID {
                        return $0.activeTabRawID < $1.activeTabRawID
                    }
                    return $0.paneRawID < $1.paneRawID
                }

            return ShuttleSelectedSessionSnapshot(
                bundle: snapshotBundle,
                tabSnapshots: tabSnapshots,
                paneSelections: paneSelections.isEmpty ? (fallbackSelectedSession?.paneSelections ?? []) : paneSelections,
                focusedTabRawID: rememberedFocusedTabRawID(for: snapshotBundle) ?? fallbackSelectedSession?.focusedTabRawID
            )
        } ?? fallbackSelectedSession

        return ShuttleAppSessionSnapshot(
            savedAt: Date(),
            selectedWorkspaceID: selectedWorkspaceID,
            selectedSessionID: selectedSessionID,
            selectedSession: selectedSessionSnapshot
        )
    }

    // MARK: - Keyboard Navigation

    /// Tabs in the currently focused pane, sorted by position.
    private var focusedPaneTabs: [ShuttleKit.Tab] {
        guard let bundle = sessionBundle, let focusedPaneRawID else { return [] }
        return bundle.tabs
            .filter { $0.paneID == focusedPaneRawID }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
    }

    var hasMultipleTabsInFocusedPane: Bool {
        focusedPaneTabs.count > 1
    }

    var hasMultiplePanes: Bool {
        guard let bundle = sessionBundle else { return false }
        let parentIDs = Set(bundle.panes.compactMap(\.parentPaneID))
        let leafPanes = bundle.panes.filter { !parentIDs.contains($0.rawID) }
        return leafPanes.count > 1
    }

    func selectNextTab() {
        let tabs = focusedPaneTabs
        guard tabs.count > 1 else { return }
        guard let currentIndex = tabs.firstIndex(where: { $0.rawID == focusedTabRawID }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectTab(tabs[nextIndex].rawID)
    }

    func selectPreviousTab() {
        let tabs = focusedPaneTabs
        guard tabs.count > 1 else { return }
        guard let currentIndex = tabs.firstIndex(where: { $0.rawID == focusedTabRawID }) else { return }
        let previousIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectTab(tabs[previousIndex].rawID)
    }

    func canSelectTabByIndex(_ index: Int) -> Bool {
        let tabs = focusedPaneTabs
        return tabs.indices.contains(index)
    }

    func selectTabByIndex(_ index: Int) {
        let tabs = focusedPaneTabs
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].rawID)
    }

    func focusNextPane() {
        guard let bundle = sessionBundle else { return }
        let parentIDs = Set(bundle.panes.compactMap(\.parentPaneID))
        let leafPanes = bundle.panes
            .filter { !parentIDs.contains($0.rawID) }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
        guard leafPanes.count > 1 else { return }
        let currentIndex = leafPanes.firstIndex(where: { $0.rawID == focusedPaneRawID }) ?? 0
        let nextIndex = (currentIndex + 1) % leafPanes.count
        let nextPane = leafPanes[nextIndex]

        // Focus the active tab in the next pane
        let paneTabs = bundle.tabs
            .filter { $0.paneID == nextPane.rawID }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
        if let activeRawID = activeTabRawIDByPaneRawID[nextPane.rawID],
           paneTabs.contains(where: { $0.rawID == activeRawID }) {
            selectTab(activeRawID)
        } else if let firstTab = paneTabs.first {
            selectTab(firstTab.rawID)
        }
    }

    func focusPreviousPane() {
        guard let bundle = sessionBundle else { return }
        let parentIDs = Set(bundle.panes.compactMap(\.parentPaneID))
        let leafPanes = bundle.panes
            .filter { !parentIDs.contains($0.rawID) }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
        guard leafPanes.count > 1 else { return }
        let currentIndex = leafPanes.firstIndex(where: { $0.rawID == focusedPaneRawID }) ?? 0
        let previousIndex = (currentIndex - 1 + leafPanes.count) % leafPanes.count
        let previousPane = leafPanes[previousIndex]

        let paneTabs = bundle.tabs
            .filter { $0.paneID == previousPane.rawID }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
        if let activeRawID = activeTabRawIDByPaneRawID[previousPane.rawID],
           paneTabs.contains(where: { $0.rawID == activeRawID }) {
            selectTab(activeRawID)
        } else if let firstTab = paneTabs.first {
            selectTab(firstTab.rawID)
        }
    }
}

