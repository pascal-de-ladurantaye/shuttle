import SwiftUI
import AppKit
import ShuttleKit

final class ShuttleApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let appMenuItem = app.mainMenu?.item(at: 0) {
            appMenuItem.title = ShuttleProfile.current.appDisplayName
        }
        TerminalFocusCoordinator.shared.installIfNeeded()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        DispatchQueue.main.async {
            app.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        Task {
            await terminationHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private enum ShuttleMainWindow {
    static let id = "main-window"

    static var frameAutosaveName: String {
        "\(ShuttleProfile.current.bundleIdentifier).main-window"
    }
}

struct ShuttleToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case info
        case error

        var iconName: String {
            switch self {
            case .success:
                return "checkmark.circle.fill"
            case .info:
                return "info.circle.fill"
            case .error:
                return "exclamationmark.triangle.fill"
            }
        }

        var tintColor: Color {
            switch self {
            case .success:
                return .green
            case .info:
                return .blue
            case .error:
                return .red
            }
        }

        var showsDismissButton: Bool {
            self != .success
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

private enum ShuttleToastLayout {
    static let width: CGFloat = 360
    static let maxVisibleRows = 4
    static let stackSpacing: CGFloat = 10
}

@main
struct ShuttleDesktopApp: App {
    @NSApplicationDelegateAdaptor(ShuttleApplicationDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: ShuttleAppModel
    @StateObject private var layoutLibrary: LayoutLibraryModel

    init() {
        // Force NSApplication initialization early without relying on the `NSApp`
        // implicit IUO, which is still nil in SwiftUI App.init() for CLI-launched builds.
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        ShuttlePreferences.registerDefaults()
        _model = StateObject(wrappedValue: ShuttleAppModel())
        _layoutLibrary = StateObject(wrappedValue: LayoutLibraryModel())
    }

    var body: some Scene {
        WindowGroup(LocalizedStringKey(ShuttleProfile.current.appDisplayName), id: ShuttleMainWindow.id) {
            ContentView()
                .defaultAppStorage(ShuttlePreferences.userDefaults)
                .environmentObject(model)
                .environmentObject(layoutLibrary)
                .background(WindowChromeConfigurator(frameAutosaveName: ShuttleMainWindow.frameAutosaveName))
                .task {
                    appDelegate.terminationHandler = {
                        await model.prepareForTermination()
                    }
                    await model.refresh(initialScanIfNeeded: true)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        NSRunningApplication.current.activate(options: [.activateAllWindows])
                        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase != .active {
                        Task {
                            model.persistActiveSnapshot(includeScrollback: true)
                            await GhosttyCheckpointWriter.shared.flushAll()
                        }
                    }
                }
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            ShuttlePaneCommands(model: model)
            ShuttleTabCommands(model: model)
            ShuttleFileCommands(model: model)
            ShuttleLayoutCommands()
        }

        Settings {
            ShuttleSettingsView()
                .defaultAppStorage(ShuttlePreferences.userDefaults)
                .environmentObject(layoutLibrary)
        }

        Window(LocalizedStringKey("\(ShuttleProfile.current.appDisplayName) Layout Builder"), id: ShuttleLayoutBuilderWindow.id) {
            ShuttleLayoutBuilderView()
                .defaultAppStorage(ShuttlePreferences.userDefaults)
                .environmentObject(layoutLibrary)
        }
        .defaultSize(width: 1100, height: 720)
    }
}

private final class WindowChromeConfigurationView: NSView {
    var configuredWindowNumber: Int?
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    let frameAutosaveName: String

    func makeNSView(context: Context) -> WindowChromeConfigurationView {
        let view = WindowChromeConfigurationView(frame: .zero)
        DispatchQueue.main.async {
            configure(view)
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeConfigurationView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView)
        }
    }

    private func configure(_ view: WindowChromeConfigurationView) {
        guard let window = view.window else { return }
        window.tabbingMode = .disallowed
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        guard view.configuredWindowNumber != window.windowNumber else { return }
        view.configuredWindowNumber = window.windowNumber

        let autosaveName = NSWindow.FrameAutosaveName(frameAutosaveName)
        _ = window.setFrameAutosaveName(autosaveName)
        _ = window.setFrameUsingName(autosaveName)
    }
}

struct ShuttlePaneCommands: Commands {
    @ObservedObject var model: ShuttleAppModel

    var body: some Commands {
        CommandMenu("Pane") {
            Button("Split Horizontally") {
                Task { await model.splitFocusedPane(direction: .down) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.canSplitFocusedPane)

            Button("Split Vertically") {
                Task { await model.splitFocusedPane(direction: .right) }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(!model.canSplitFocusedPane)
        }
    }
}

struct ShuttleTabCommands: Commands {
    @ObservedObject var model: ShuttleAppModel

    var body: some Commands {
        CommandMenu("Tab") {
            Button("New Tab") {
                Task { await model.createTabInFocusedPane() }
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(!model.canCreateTabInFocusedPane)

            Button("Close Tab") {
                Task { await model.closeFocusedTab() }
            }
            .disabled(!model.canCloseFocusedTab)
        }
    }
}

struct ShuttleFileCommands: Commands {
    @ObservedObject var model: ShuttleAppModel

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                Task { await model.closeFocusedTab() }
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(!model.canCloseFocusedTab)

            Divider()

            Button("Close Window") {
                _ = NSApplication.shared.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

struct ShuttleLayoutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Layout") {
            Button("Layout Builder…") {
                openWindow(id: ShuttleLayoutBuilderWindow.id)
            }
        }
    }
}

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
    private var bellObserver: NSObjectProtocol?
    private var desktopNotificationObserver: NSObjectProtocol?

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
    }

    private func installBellObserver() {
        bellObserver = NotificationCenter.default.addObserver(
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

    private func installDesktopNotificationObserver() {
        desktopNotificationObserver = NotificationCenter.default.addObserver(
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
}

// MARK: - Content View

private struct ShuttleChromePalette {
    let colorScheme: ColorScheme

    private var isDark: Bool {
        colorScheme == .dark
    }

    var sidebarBackground: Color {
        let base = isDark ? NSColor.underPageBackgroundColor : NSColor.controlBackgroundColor
        let adjusted = isDark
            ? (base.blended(withFraction: 0.18, of: .black) ?? base)
            : (base.blended(withFraction: 0.04, of: .black) ?? base)
        return Color(nsColor: adjusted)
    }

    var emphasizedSelectionFill: Color {
        if isDark {
            return Color.accentColor.opacity(0.24)
        }

        return Color(nsColor: NSColor.selectedContentBackgroundColor)
    }

    var emphasizedSelectionText: Color {
        .white
    }

    var emphasizedSelectionSecondaryText: Color {
        Color.white.opacity(isDark ? 0.76 : 0.86)
    }

    var sidebarSearchFieldFill: Color {
        let base = NSColor.controlBackgroundColor
        let adjusted = isDark
            ? (base.blended(withFraction: 0.1, of: .white) ?? base)
            : (base.blended(withFraction: 0.02, of: .black) ?? base)
        return Color(nsColor: adjusted)
    }

    var sidebarSearchFieldBorder: Color {
        Color(nsColor: NSColor.separatorColor).opacity(isDark ? 0.16 : 0.12)
    }

    var focusedTabBarTint: Color {
        isDark ? Color.accentColor.opacity(0.05) : .clear
    }

    var tabBaseFill: Color {
        Color(nsColor: NSColor.controlBackgroundColor)
    }

    var inactivePaneActiveTabFill: Color {
        isDark ? Color.secondary.opacity(0.12) : Color(nsColor: NSColor.controlBackgroundColor).opacity(0.92)
    }

    var hoveredTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.6 : 0.94)
    }

    var restingTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.34 : 0.82)
    }

    var unfocusedHoveredTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.46 : 0.84)
    }

    var unfocusedRestingTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.24 : 0.68)
    }

    var activeTabText: Color {
        emphasizedSelectionText
    }

    var inactivePaneActiveTabText: Color {
        Color.primary.opacity(isDark ? 0.82 : 0.72)
    }

    var focusedInactiveTabText: Color {
        Color.primary.opacity(isDark ? 0.82 : 0.78)
    }

    var unfocusedInactiveTabText: Color {
        Color.primary.opacity(isDark ? 0.62 : 0.56)
    }

    var activeHoverCloseIcon: Color {
        isDark ? Color.white.opacity(0.82) : Color.primary.opacity(0.78)
    }

    var inactiveHoverCloseIcon: Color {
        Color.primary.opacity(isDark ? 0.52 : 0.62)
    }

    func selectedBorderColor(isActive: Bool) -> Color {
        if isActive {
            return isDark
                ? Color(nsColor: NSColor.separatorColor).opacity(0.28)
                : Color.white.opacity(0.22)
        }

        return Color(nsColor: NSColor.separatorColor).opacity(isDark ? 0.12 : 0.2)
    }

    func hoveredBorderColor(isFocusedPane: Bool) -> Color {
        Color(nsColor: NSColor.separatorColor).opacity(isDark ? 0.22 : (isFocusedPane ? 0.22 : 0.18))
    }

    func tabShadow(isActive: Bool, isFocusedPane: Bool) -> Color {
        guard isActive else { return .clear }
        if isDark {
            return Color.black.opacity(isFocusedPane ? 0.16 : 0.08)
        }
        return Color.black.opacity(isFocusedPane ? 0.08 : 0.04)
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: ShuttleAppModel
    @EnvironmentObject private var layoutLibrary: LayoutLibraryModel
    @Environment(\.colorScheme) private var colorScheme
    private let profile = ShuttleProfile.current
    @State private var showSessionInfoPopover = false
    @State private var presentedSheet: ShuttleSheet?
    @State private var discoveredWorkspaceSearchText = ""
    @State private var sessionSearchText = ""
    @AppStorage(ShuttlePreferenceKey.workspaceSidebarPinnedExpanded) private var isPinnedWorkspacesExpanded = true
    @AppStorage(ShuttlePreferenceKey.workspaceSidebarRecentExpanded) private var isRecentWorkspacesExpanded = true
    @AppStorage(ShuttlePreferenceKey.workspaceSidebarProjectExpanded) private var isProjectWorkspacesExpanded = true
    @AppStorage(ShuttlePreferenceKey.workspaceSidebarTryExpanded) private var isTryWorkspacesExpanded = true
    @AppStorage(ShuttlePreferenceKey.pinnedWorkspaceKeys) private var pinnedWorkspaceKeysStorage = ShuttlePreferences.emptyPinnedWorkspaceKeysStorage
    @AppStorage(ShuttlePreferenceKey.sessionSidebarArchivedExpanded) private var isArchivedSessionsExpanded = false
    @AppStorage(ShuttlePreferenceKey.sessionSidebarProjectsExpanded) private var isProjectsExpanded = false

    private enum SidebarLayout {
        static let workspaceMinWidth: CGFloat = 220
        static let workspaceIdealWidth: CGFloat = workspaceMinWidth
        static let workspaceMaxWidth: CGFloat = 320
        static let sessionMinWidth: CGFloat = 220
        static let sessionIdealWidth: CGFloat = sessionMinWidth
        static let combinedMinWidth: CGFloat = workspaceMinWidth + sessionMinWidth
        static let combinedIdealWidth: CGFloat = combinedMinWidth
        static let combinedMaxWidth: CGFloat = 760
    }

    private enum WorkspaceSidebarCategory {
        case global
        case project
        case tryWorkspace
    }

    private struct ProjectWorkspaceGroup: Identifiable {
        let rootPath: String?
        let title: String
        let workspaces: [WorkspaceDetails]

        var id: String {
            rootPath ?? "outside-current-config"
        }
    }

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    private var solidSidebarBackground: Color {
        chromePalette.sidebarBackground
    }

    var body: some View {
        NavigationSplitView {
            combinedSidebar
        } detail: {
            DetailView()
        }
        .toolbar {
            toolbarContent
        }
        .overlay(alignment: .topTrailing) {
            toastOverlay
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .newSession:
                if let workspace = model.selectedWorkspace {
                    NewSessionSheet(workspace: workspace)
                        .environmentObject(model)
                        .environmentObject(layoutLibrary)
                } else {
                    ContentUnavailableView("No Workspace Selected", systemImage: "square.stack.3d.up")
                        .frame(width: 420, height: 220)
                }
            case .newTry:
                NewTrySessionSheet()
                    .environmentObject(model)
                    .environmentObject(layoutLibrary)
            case .renameSession(let sessionRawID):
                RenameSessionSheet(sessionRawID: sessionRawID)
                    .environmentObject(model)
            case .deleteSession(let sessionRawID):
                DeleteSessionSheet(sessionRawID: sessionRawID)
                    .environmentObject(model)
            }
        }
    }

    private var combinedSidebar: some View {
        HSplitView {
            workspaceSidebarColumn
                .frame(
                    minWidth: SidebarLayout.workspaceMinWidth,
                    idealWidth: SidebarLayout.workspaceIdealWidth,
                    maxWidth: SidebarLayout.workspaceMaxWidth,
                    maxHeight: .infinity
                )

            sessionSidebarColumn
                .frame(
                    minWidth: SidebarLayout.sessionMinWidth,
                    idealWidth: SidebarLayout.sessionIdealWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(solidSidebarBackground)
        .navigationSplitViewColumnWidth(
            min: SidebarLayout.combinedMinWidth,
            ideal: SidebarLayout.combinedIdealWidth,
            max: SidebarLayout.combinedMaxWidth
        )
    }

    private var workspaceSidebarColumn: some View {
        VStack(spacing: 0) {
            if model.workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces Yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Run Scan from the toolbar or configure project roots in \(model.configFilePath).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    workspaceSidebarSections
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(solidSidebarBackground)
    }

    @ViewBuilder
    private var sessionSidebarColumn: some View {
        if let workspace = model.selectedWorkspace {
            VStack(spacing: 0) {
                sessionSidebarHeader(for: workspace)
                Divider()

                if sessionSidebarHasVisibleContent(for: workspace) {
                    List {
                        sessionSidebarSections(for: workspace)
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.sidebar)
                    .background(solidSidebarBackground)
                } else {
                    ContentUnavailableView(
                        normalizedSessionSearchText.isEmpty ? "No Sessions Yet" : "No Matching Sessions or Projects",
                        systemImage: normalizedSessionSearchText.isEmpty ? "terminal" : "magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(solidSidebarBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(solidSidebarBackground)
        } else {
            ContentUnavailableView("No Workspace Selected", systemImage: "square.stack.3d.up")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(solidSidebarBackground)
        }
    }

    private var selectedWorkspaceRawID: Int64? {
        model.selectedWorkspace?.workspace.rawID
    }

    private var selectedSessionRawID: Int64? {
        model.sessionBundle?.session.rawID ?? model.selectedSessionID
    }

    private var sidebarRowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 1)
    }

    private var normalizedDiscoveredWorkspaceSearchText: String {
        discoveredWorkspaceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSessionSearchText: String {
        sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pinnedWorkspaceKeys: Set<String> {
        ShuttlePreferences.decodePinnedWorkspaceKeys(from: pinnedWorkspaceKeysStorage)
    }

    private var newestFirstToasts: [ShuttleToast] {
        Array(model.toasts.reversed())
    }

    private var visibleToasts: [ShuttleToast] {
        guard newestFirstToasts.count > ShuttleToastLayout.maxVisibleRows else {
            return newestFirstToasts
        }
        return Array(newestFirstToasts.prefix(ShuttleToastLayout.maxVisibleRows - 1))
    }

    private var hiddenToastCount: Int {
        max(newestFirstToasts.count - visibleToasts.count, 0)
    }

    private var globalWorkspaces: [WorkspaceDetails] {
        model.workspaces.filter {
            workspaceSidebarCategory(for: $0) == .global
        }
    }

    private var pinnedWorkspaces: [WorkspaceDetails] {
        model.workspaces.filter {
            workspaceSidebarCategory(for: $0) != .global && isWorkspacePinned($0)
        }
    }

    private var recentWorkspaces: [WorkspaceDetails] {
        Array(
            model.workspaces
                .filter {
                    workspaceSidebarCategory(for: $0) != .global
                        && !isWorkspacePinned($0)
                        && workspaceMostRecentActivityDate(in: $0) != nil
                }
                .sorted(by: workspaceRecencySort)
                .prefix(5)
        )
    }

    private var discoveredProjectWorkspaces: [WorkspaceDetails] {
        model.workspaces.filter {
            workspaceSidebarCategory(for: $0) == .project
        }
    }

    private var discoveredTryWorkspaces: [WorkspaceDetails] {
        model.workspaces.filter {
            workspaceSidebarCategory(for: $0) == .tryWorkspace
        }
    }

    private var filteredProjectWorkspaces: [WorkspaceDetails] {
        guard !normalizedDiscoveredWorkspaceSearchText.isEmpty else {
            return discoveredProjectWorkspaces
        }
        return discoveredProjectWorkspaces.filter {
            workspaceMatchesSearch($0, query: normalizedDiscoveredWorkspaceSearchText)
        }
    }

    private var filteredTryWorkspaces: [WorkspaceDetails] {
        guard !normalizedDiscoveredWorkspaceSearchText.isEmpty else {
            return discoveredTryWorkspaces
        }
        return discoveredTryWorkspaces.filter {
            workspaceMatchesSearch($0, query: normalizedDiscoveredWorkspaceSearchText)
        }
    }

    private var projectWorkspaceGroups: [ProjectWorkspaceGroup] {
        groupedProjectWorkspaces(filteredProjectWorkspaces)
    }

    private var shouldShowProjectWorkspaceRootHeaders: Bool {
        model.configuredProjectRoots.count > 1
            || projectWorkspaceGroups.contains { $0.rootPath == nil }
    }

    private var hasDiscoveredWorkspaces: Bool {
        !discoveredProjectWorkspaces.isEmpty || !discoveredTryWorkspaces.isEmpty
    }

    private var hasVisibleDiscoveredWorkspaces: Bool {
        !filteredProjectWorkspaces.isEmpty || !filteredTryWorkspaces.isEmpty
    }

    @ViewBuilder
    private var workspaceSidebarSections: some View {
        if !globalWorkspaces.isEmpty {
            Section("Global") {
                ForEach(globalWorkspaces, id: \.workspace.rawID) { details in
                    workspaceRow(for: details)
                }
            }
        }

        if !pinnedWorkspaces.isEmpty {
            workspaceSidebarSection(
                title: "Pinned",
                workspaces: pinnedWorkspaces,
                isExpanded: isPinnedWorkspacesExpanded,
                sectionsLockedOpen: false
            ) {
                isPinnedWorkspacesExpanded.toggle()
            }
        }

        if !recentWorkspaces.isEmpty {
            workspaceSidebarSection(
                title: "Recent",
                workspaces: recentWorkspaces,
                isExpanded: isRecentWorkspacesExpanded,
                sectionsLockedOpen: false
            ) {
                isRecentWorkspacesExpanded.toggle()
            }
        }

        discoveredWorkspaceSidebarSections
    }

    @ViewBuilder
    private var discoveredWorkspaceSidebarSections: some View {
        let sectionsLockedOpen = !normalizedDiscoveredWorkspaceSearchText.isEmpty

        Section("Discovered Workspaces") {
            if hasDiscoveredWorkspaces || sectionsLockedOpen {
                SidebarSearchField(
                    placeholder: "Search discovered workspaces",
                    text: $discoveredWorkspaceSearchText
                )
                .padding(.vertical, 4)
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)
            }

            if !hasDiscoveredWorkspaces {
                SidebarStatusRow(
                    systemImage: "sparkle.magnifyingglass",
                    title: "No Discovered Workspaces",
                    subtitle: "Run Scan from the toolbar or configure project roots in \(model.configFilePath)."
                )
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)
            } else if !hasVisibleDiscoveredWorkspaces {
                SidebarStatusRow(
                    systemImage: "magnifyingglass",
                    title: "No Matching Discovered Workspaces",
                    subtitle: "Search only filters Project Workspaces and Try Workspaces."
                )
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)
            }
        }

        if hasDiscoveredWorkspaces {
            if !filteredProjectWorkspaces.isEmpty {
                projectWorkspaceSidebarSection(
                    title: "Project Workspaces",
                    groups: projectWorkspaceGroups,
                    showGroupHeaders: shouldShowProjectWorkspaceRootHeaders,
                    isExpanded: isProjectWorkspacesExpanded || sectionsLockedOpen,
                    sectionsLockedOpen: sectionsLockedOpen
                ) {
                    isProjectWorkspacesExpanded.toggle()
                }
            }

            if !filteredTryWorkspaces.isEmpty {
                workspaceSidebarSection(
                    title: "Try Workspaces",
                    workspaces: filteredTryWorkspaces,
                    isExpanded: isTryWorkspacesExpanded || sectionsLockedOpen,
                    sectionsLockedOpen: sectionsLockedOpen
                ) {
                    isTryWorkspacesExpanded.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private func projectWorkspaceSidebarSection(
        title: String,
        groups: [ProjectWorkspaceGroup],
        showGroupHeaders: Bool,
        isExpanded: Bool,
        sectionsLockedOpen: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Section {
            Button {
                onToggle()
            } label: {
                SidebarDisclosureRow(
                    title: title,
                    count: groups.reduce(0) { $0 + $1.workspaces.count },
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .shuttleHint(sectionsLockedOpen ? "Search is keeping \(title) expanded." : (isExpanded ? "Hide \(title.lowercased())." : "Show \(title.lowercased())."))
            .disabled(sectionsLockedOpen)
            .listRowInsets(sidebarRowInsets)
            .listRowBackground(Color.clear)

            if isExpanded {
                ForEach(groups) { group in
                    if showGroupHeaders {
                        SidebarGroupHeaderRow(
                            title: group.title,
                            count: group.workspaces.count
                        )
                        .shuttleHint(
                            group.rootPath.map { "Configured project root: \(abbreviatedPath($0))" }
                                ?? "These workspaces no longer match a configured project root."
                        )
                        .listRowInsets(sidebarRowInsets)
                        .listRowBackground(Color.clear)
                    }

                    ForEach(group.workspaces, id: \.workspace.rawID) { details in
                        workspaceRow(for: details)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceSidebarSection(
        title: String,
        workspaces: [WorkspaceDetails],
        isExpanded: Bool,
        sectionsLockedOpen: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Section {
            Button {
                onToggle()
            } label: {
                SidebarDisclosureRow(
                    title: title,
                    count: workspaces.count,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .shuttleHint(sectionsLockedOpen ? "Search is keeping \(title) expanded." : (isExpanded ? "Hide \(title.lowercased())." : "Show \(title.lowercased())."))
            .disabled(sectionsLockedOpen)
            .listRowInsets(sidebarRowInsets)
            .listRowBackground(Color.clear)

            if isExpanded {
                ForEach(workspaces, id: \.workspace.rawID) { details in
                    workspaceRow(for: details)
                }
            }
        }
    }

    private func workspaceRow(for details: WorkspaceDetails) -> some View {
        let category = workspaceSidebarCategory(for: details)
        let systemImage: String = {
            switch category {
            case .global:
                return "house"
            case .tryWorkspace:
                return "sparkles"
            case .project:
                return "folder"
            }
        }()
        let workspaceAttentionCount = details.sessions.reduce(0) { $0 + (model.attentionCountsBySessionRawID[$1.rawID] ?? 0) }
        let iconColor: Color = workspaceAttentionCount > 0 ? .orange : .accentColor
        let isPinned = isWorkspacePinned(details)

        return HoverPinnableWorkspaceRow(
            systemImage: systemImage,
            iconColor: iconColor,
            title: details.workspace.name,
            subtitle: workspaceSidebarSubtitle(for: details),
            isSelected: selectedWorkspaceRawID == details.workspace.rawID,
            isPinned: isPinned,
            canTogglePin: workspacePinPreferenceKey(for: details) != nil,
            attentionCount: workspaceAttentionCount,
            onSelect: {
                Task { await model.selectWorkspace(details.workspace.rawID) }
            },
            onTogglePin: {
                setWorkspacePinned(details, isPinned: !isPinned)
            }
        )
        .shuttleHint(workspaceHelpText(for: details))
        .contextMenu {
            Button("New Session…") {
                Task {
                    await model.selectWorkspace(details.workspace.rawID)
                    presentedSheet = .newSession
                }
            }

            if workspacePinPreferenceKey(for: details) != nil {
                Divider()

                Button(isPinned ? "Unpin Workspace" : "Pin Workspace") {
                    setWorkspacePinned(details, isPinned: !isPinned)
                }
            }

            if !details.projects.isEmpty {
                Divider()
            }

            if details.projects.count == 1, let project = details.projects.first {
                Button("Reveal Project in Finder") {
                    revealPath(project.path)
                }
            } else if !details.projects.isEmpty {
                Menu("Reveal Project in Finder") {
                    ForEach(details.projects, id: \.rawID) { project in
                        Button(project.name) {
                            revealPath(project.path)
                        }
                    }
                }
            }
        }
        .listRowInsets(sidebarRowInsets)
        .listRowBackground(Color.clear)
    }

    private func workspaceSidebarCategory(for details: WorkspaceDetails) -> WorkspaceSidebarCategory {
        if details.workspace.createdFrom == .global {
            return .global
        }
        if !details.projects.isEmpty && details.projects.allSatisfy({ $0.kind == .try }) {
            return .tryWorkspace
        }
        return .project
    }

    private func primaryProject(for details: WorkspaceDetails) -> Project? {
        if let sourceProjectID = details.workspace.sourceProjectID,
           let sourceProject = details.projects.first(where: { $0.rawID == sourceProjectID }) {
            return sourceProject
        }
        return details.projects.first
    }

    private func projectWorkspaceRootPath(for details: WorkspaceDetails) -> String? {
        guard let project = primaryProject(for: details) else {
            return nil
        }
        return bestMatchingPathRoot(for: project.path, roots: model.configuredProjectRoots)
    }

    private func groupedProjectWorkspaces(_ workspaces: [WorkspaceDetails]) -> [ProjectWorkspaceGroup] {
        guard !workspaces.isEmpty else { return [] }

        let workspacesByRoot = Dictionary(grouping: workspaces) { projectWorkspaceRootPath(for: $0) }
        var groups: [ProjectWorkspaceGroup] = []

        for root in model.configuredProjectRoots {
            guard let groupedWorkspaces = workspacesByRoot[root], !groupedWorkspaces.isEmpty else {
                continue
            }
            groups.append(
                ProjectWorkspaceGroup(
                    rootPath: root,
                    title: abbreviatedPath(root),
                    workspaces: groupedWorkspaces
                )
            )
        }

        if let unmatchedWorkspaces = workspacesByRoot[nil], !unmatchedWorkspaces.isEmpty {
            groups.append(
                ProjectWorkspaceGroup(
                    rootPath: nil,
                    title: "Outside Current Config",
                    workspaces: unmatchedWorkspaces
                )
            )
        }

        return groups
    }

    private func workspacePinPreferenceKey(for details: WorkspaceDetails) -> String? {
        guard details.workspace.createdFrom != .global else {
            return nil
        }
        if let project = primaryProject(for: details) {
            return "project:\(standardizedWorkspacePinPath(project.path))"
        }
        return "workspace:\(details.workspace.uuid.uuidString.lowercased())"
    }

    private func standardizedWorkspacePinPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func isWorkspacePinned(_ details: WorkspaceDetails) -> Bool {
        guard let preferenceKey = workspacePinPreferenceKey(for: details) else {
            return false
        }
        return pinnedWorkspaceKeys.contains(preferenceKey)
    }

    private func setWorkspacePinned(_ details: WorkspaceDetails, isPinned: Bool) {
        guard let preferenceKey = workspacePinPreferenceKey(for: details) else {
            return
        }

        var updatedPinnedWorkspaceKeys = pinnedWorkspaceKeys
        if isPinned {
            updatedPinnedWorkspaceKeys.insert(preferenceKey)
        } else {
            updatedPinnedWorkspaceKeys.remove(preferenceKey)
        }
        pinnedWorkspaceKeysStorage = ShuttlePreferences.encodePinnedWorkspaceKeys(updatedPinnedWorkspaceKeys)
    }

    private func workspaceMostRecentActivityDate(in details: WorkspaceDetails) -> Date? {
        details.sessions.map(\.lastActiveAt).max()
    }

    private func workspaceRecencySort(_ lhs: WorkspaceDetails, _ rhs: WorkspaceDetails) -> Bool {
        let lhsDate = workspaceMostRecentActivityDate(in: lhs) ?? .distantPast
        let rhsDate = workspaceMostRecentActivityDate(in: rhs) ?? .distantPast
        if lhsDate == rhsDate {
            return lhs.workspace.name.localizedCaseInsensitiveCompare(rhs.workspace.name) == .orderedAscending
        }
        return lhsDate > rhsDate
    }

    private func workspaceSidebarSubtitle(for details: WorkspaceDetails) -> String {
        if details.workspace.createdFrom == .global {
            return "\(details.sessions.count) session\(details.sessions.count == 1 ? "" : "s") • opens in ~"
        }
        return "\(details.sessions.count) session\(details.sessions.count == 1 ? "" : "s")"
    }

    private func workspaceHelpText(for details: WorkspaceDetails) -> String {
        var lines = [
            "Workspace: \(details.workspace.name)",
            workspaceSidebarSubtitle(for: details)
        ]

        if isWorkspacePinned(details) {
            lines.append("Pinned in the sidebar")
        }

        if details.workspace.createdFrom == .global {
            lines.append("")
            lines.append("Global workspace")
            lines.append("• Sessions are not linked to a project")
            lines.append("• New tabs start in ~")
            lines.append("• Shuttle still keeps session metadata in each session root")
            return lines.joined(separator: "\n")
        }

        if !details.projects.isEmpty {
            lines.append("")
            lines.append("Projects")
            lines.append(contentsOf: details.projects.map { "• \($0.name) — \(abbreviatedPath($0.path))" })
        }

        return lines.joined(separator: "\n")
    }

    private func sessionSidebarHasVisibleContent(for workspace: WorkspaceDetails) -> Bool {
        !activeSessions(in: workspace).isEmpty
            || !recentInactiveSessions(in: workspace).isEmpty
            || !archivedInactiveSessions(in: workspace).isEmpty
            || shouldShowProjectsSection(for: workspace)
    }

    @ViewBuilder
    private func sessionSidebarSections(for workspace: WorkspaceDetails) -> some View {
        let activeSessions = activeSessions(in: workspace)
        let recentSessions = recentInactiveSessions(in: workspace)
        let archivedSessions = archivedInactiveSessions(in: workspace)
        let filteredProjects = filteredProjects(in: workspace)
        let archivedSessionsExpanded = isArchivedSessionsExpanded || (!normalizedSessionSearchText.isEmpty && !archivedSessions.isEmpty)
        let projectsExpanded = isProjectsExpanded || (!normalizedSessionSearchText.isEmpty && !filteredProjects.isEmpty)

        if !activeSessions.isEmpty {
            Section("Active") {
                ForEach(activeSessions, id: \.rawID) { session in
                    sessionRow(for: session)
                }
            }
        }

        if !recentSessions.isEmpty {
            Section("Recent") {
                ForEach(recentSessions, id: \.rawID) { session in
                    sessionRow(for: session)
                }
            }
        }

        if !archivedSessions.isEmpty {
            Section {
                Button {
                    isArchivedSessionsExpanded.toggle()
                } label: {
                    SidebarDisclosureRow(
                        title: "Restorable & Closed",
                        count: archivedSessions.count,
                        isExpanded: archivedSessionsExpanded
                    )
                }
                .buttonStyle(.plain)
                .shuttleHint(archivedSessionsExpanded ? "Hide restorable and closed sessions." : "Show restorable and closed sessions.")
                .disabled(!normalizedSessionSearchText.isEmpty)
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)

                if archivedSessionsExpanded {
                    ForEach(archivedSessions, id: \.rawID) { session in
                        sessionRow(for: session)
                    }
                }
            }
        }

        if shouldShowProjectsSection(for: workspace) {
            Section {
                Button {
                    isProjectsExpanded.toggle()
                } label: {
                    SidebarDisclosureRow(
                        title: "Projects",
                        count: filteredProjects.count,
                        isExpanded: projectsExpanded
                    )
                }
                .buttonStyle(.plain)
                .shuttleHint(projectsExpanded ? "Hide workspace projects." : "Show workspace projects.")
                .disabled(!normalizedSessionSearchText.isEmpty)
                .listRowInsets(sidebarRowInsets)
                .listRowBackground(Color.clear)

                if projectsExpanded {
                    ForEach(filteredProjects, id: \.rawID) { project in
                        projectRow(for: project)
                    }
                }
            }
        }
    }

    private func sessionRow(for session: Session) -> some View {
        let systemImage: String
        switch session.status {
        case .active:
            systemImage = "terminal"
        case .restorable:
            systemImage = "arrow.clockwise.circle"
        case .closed:
            systemImage = "clock"
        }

        let attentionCount = model.attentionCountsBySessionRawID[session.rawID] ?? 0
        let iconColor: Color = attentionCount > 0 ? .orange : (session.status == .active ? .accentColor : .secondary)

        return TimelineView(.periodic(from: .now, by: 30)) { context in
            HoverDeletableSessionRow(
                systemImage: systemImage,
                iconColor: iconColor,
                title: session.name,
                subtitle: sessionSidebarSubtitle(for: session, relativeTo: context.date),
                isSelected: selectedSessionRawID == session.rawID,
                attentionCount: attentionCount,
                onSelect: {
                    Task { await model.selectSession(session.rawID) }
                },
                onDelete: {
                    presentedSheet = .deleteSession(session.rawID)
                }
            )
        }
        .shuttleHint(sessionHelpText(for: session))
        .contextMenu {
            Button(session.status == .restorable ? "Restore Session" : "Open Session") {
                Task { await model.selectSession(session.rawID) }
            }

            Button("Rename Session…") {
                presentedSheet = .renameSession(session.rawID)
            }

            Button("Close Session") {
                Task {
                    do {
                        try await model.closeSession(sessionRawID: session.rawID)
                    } catch {
                        // Toasts are surfaced by the model call path.
                    }
                }
            }
            .disabled(session.status == .closed)

            Button("Reveal Session Root in Finder") {
                revealPath(session.sessionRootPath)
            }

            Divider()

            Button("Delete Session…", role: .destructive) {
                presentedSheet = .deleteSession(session.rawID)
            }
        }
        .listRowInsets(sidebarRowInsets)
        .listRowBackground(Color.clear)
    }

    private func projectRow(for project: Project) -> some View {
        SidebarListRow(
            systemImage: project.kind == .try ? "sparkles" : "folder.badge.gearshape",
            iconColor: project.kind == .try ? .accentColor : .secondary,
            title: project.name,
            subtitle: projectSidebarSubtitle(for: project),
            isSelected: false
        )
        .shuttleHint(projectHelpText(for: project))
        .contextMenu {
            Button("Reveal Project in Finder") {
                revealPath(project.path)
            }
        }
        .listRowInsets(sidebarRowInsets)
        .listRowBackground(Color.clear)
    }

    private func activeSessions(in workspace: WorkspaceDetails) -> [Session] {
        workspace.sessions
            .filter { $0.status == .active && sessionMatchesSearch($0, query: normalizedSessionSearchText) }
    }

    private func recentInactiveSessions(in workspace: WorkspaceDetails) -> [Session] {
        Array(filteredInactiveSessions(in: workspace).prefix(5))
    }

    private func archivedInactiveSessions(in workspace: WorkspaceDetails) -> [Session] {
        Array(filteredInactiveSessions(in: workspace).dropFirst(5))
    }

    private func filteredInactiveSessions(in workspace: WorkspaceDetails) -> [Session] {
        workspace.sessions
            .filter { $0.status != .active && sessionMatchesSearch($0, query: normalizedSessionSearchText) }
            .sorted(by: sessionSort)
    }

    private func filteredProjects(in workspace: WorkspaceDetails) -> [Project] {
        workspace.projects.filter { projectMatchesSearch($0, query: normalizedSessionSearchText) }
    }

    private func shouldShowProjectsSection(for workspace: WorkspaceDetails) -> Bool {
        let projects = filteredProjects(in: workspace)
        guard !projects.isEmpty else { return false }
        if !normalizedSessionSearchText.isEmpty {
            return true
        }
        return workspace.projects.count > 1
    }

    private func sessionSort(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.lastActiveAt == rhs.lastActiveAt {
            return lhs.rawID > rhs.rawID
        }
        return lhs.lastActiveAt > rhs.lastActiveAt
    }

    private func workspaceMatchesSearch(_ details: WorkspaceDetails, query: String) -> Bool {
        let projectFields = details.projects.flatMap { project in
            [project.name, project.path, project.kind.rawValue]
        }
        return matchesSearch(
            query: query,
            fields: [details.workspace.name, details.workspace.slug] + projectFields
        )
    }

    private func sessionMatchesSearch(_ session: Session, query: String) -> Bool {
        matchesSearch(
            query: query,
            fields: [
                session.name,
                session.slug,
                session.layoutName ?? LayoutPresetStore.defaultPresetID,
                session.sessionRootPath,
                sessionStatusDisplayName(session.status)
            ]
        )
    }

    private func projectMatchesSearch(_ project: Project, query: String) -> Bool {
        matchesSearch(
            query: query,
            fields: [
                project.name,
                project.path,
                project.kind.rawValue
            ]
        )
    }

    private func matchesSearch(query: String, fields: [String]) -> Bool {
        let tokens = searchTokens(from: query)
        guard !tokens.isEmpty else { return true }
        let haystack = fields.joined(separator: "\n").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func searchTokens(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private func sessionSidebarSubtitle(for session: Session, relativeTo referenceDate: Date = Date()) -> String {
        var parts: [String] = []

        if session.status != .active {
            parts.append(sessionStatusDisplayName(session.status))
            parts.append(relativeTimestamp(session.lastActiveAt, relativeTo: referenceDate))
        }

        parts.append("\(session.layoutName ?? LayoutPresetStore.defaultPresetID) layout")

        return parts.joined(separator: " • ")
    }

    private func sessionHelpText(for session: Session) -> String {
        let lines = [
            "Session: \(session.name)",
            "Status: \(sessionStatusDisplayName(session.status))",
            "Last active: \(absoluteTimestamp(session.lastActiveAt))",
            "Layout: \(session.layoutName ?? LayoutPresetStore.defaultPresetID)",
            "Root: \(abbreviatedPath(session.sessionRootPath))"
        ]

        return lines.joined(separator: "\n")
    }

    private func projectSidebarSubtitle(for project: Project) -> String? {
        project.kind == .try ? "Try project" : "Workspace project"
    }

    private func projectHelpText(for project: Project) -> String {
        [
            "Project: \(project.name)",
            "Type: \(project.kind == .try ? "Try" : "Standard")",
            "Path: \(abbreviatedPath(project.path))"
        ].joined(separator: "\n")
    }

    private func sessionStatusDisplayName(_ status: SessionStatus) -> String {
        switch status {
        case .active:
            return "Active"
        case .restorable:
            return "Restorable"
        case .closed:
            return "Closed"
        }
    }

    private func relativeTimestamp(_ date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private func absoluteTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func revealPath(_ path: String) {
        ShuttleExternalPaths.reveal(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func sessionSidebarHeader(for workspace: WorkspaceDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.workspace.name)
                        .font(.headline)

                    if profile == .dev {
                        ShuttleProfileBadge(profile: profile)
                    }
                }
                Text(
                    workspace.workspace.createdFrom == .global
                        ? "\(workspace.sessions.count) session\(workspace.sessions.count == 1 ? "" : "s") • new tabs start in ~"
                        : "\(workspace.sessions.count) session\(workspace.sessions.count == 1 ? "" : "s")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if workspace.workspace.createdFrom == .global {
                    Text("Global workspace • not linked to any project")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if workspace.projects.count == 1, let project = workspace.projects.first {
                    Text("\(project.kind == .try ? "Try" : "Project") • \(project.name)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            SidebarSearchField(
                placeholder: "Filter sessions and projects",
                text: $sessionSearchText
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await model.scanProjects() }
            } label: {
                if model.isScanningProjects {
                    Label {
                        Text("Scan")
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
            }
            .shuttleHint(model.isScanningProjects ? "Scanning configured project roots…" : "Rescan configured project roots and refresh the sidebar.")

            Button {
                presentedSheet = .newSession
            } label: {
                Label("New Session…", systemImage: "plus.rectangle.on.rectangle")
            }
            .shuttleHint("Create a new session in the selected workspace.")
            .disabled(model.selectedWorkspace == nil)

            Button {
                presentedSheet = .newTry
            } label: {
                Label("New Try Session…", systemImage: "sparkles")
            }
            .shuttleHint("Create a new try directory and open its initial session.")
        }

        ToolbarItem(placement: .principal) {
            toolbarSessionContext
        }
    }

    @ViewBuilder
    private var toolbarSessionContext: some View {
        if let bundle = model.sessionBundle {
            HStack(spacing: 7) {
                if profile == .dev {
                    ShuttleProfileBadge(profile: profile)
                }

                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(bundle.session.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text(bundle.workspace.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button {
                    showSessionInfoPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .shuttleHint("Show session details, restore state, and checkout information.")
                .popover(isPresented: $showSessionInfoPopover) {
                    SessionInfoPopoverView(
                        bundle: bundle,
                        restoreMessage: model.restoreMessage(for: bundle.session.rawID),
                        onRename: {
                            showSessionInfoPopover = false
                            presentedSheet = .renameSession(bundle.session.rawID)
                        },
                        onClose: {
                            showSessionInfoPopover = false
                            Task {
                                do {
                                    try await model.closeSession(sessionRawID: bundle.session.rawID)
                                } catch {
                                    // Toasts are surfaced by the model call path.
                                }
                            }
                        },
                        onDelete: {
                            showSessionInfoPopover = false
                            presentedSheet = .deleteSession(bundle.session.rawID)
                        }
                    )
                    .frame(width: 320)
                    .padding()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .fixedSize(horizontal: true, vertical: false)
        } else if let workspace = model.selectedWorkspace {
            HStack(spacing: 6) {
                if profile == .dev {
                    ShuttleProfileBadge(profile: profile)
                }

                Image(systemName: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(workspace.workspace.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .fixedSize(horizontal: true, vertical: false)
        } else if profile == .dev {
            ShuttleProfileBadge(profile: profile)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if !model.toasts.isEmpty {
            VStack(alignment: .trailing, spacing: ShuttleToastLayout.stackSpacing) {
                ForEach(visibleToasts) { toast in
                    ShuttleToastView(toast: toast) {
                        model.dismissToast(id: toast.id)
                    }
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(toast.kind.showsDismissButton)
                }

                if hiddenToastCount > 0 {
                    ShuttleToastOverflowSummaryView(hiddenCount: hiddenToastCount)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
    }
}

private struct ShuttleToastView: View {
    let toast: ShuttleToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.kind.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.kind.tintColor)
                .padding(.top, 1)

            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if toast.kind.showsDismissButton {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: ShuttleToastLayout.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(toast.kind.tintColor.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct ShuttleToastOverflowSummaryView: View {
    let hiddenCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("+\(hiddenCount) more notification\(hiddenCount == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: ShuttleToastLayout.width, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        .accessibilityLabel("\(hiddenCount) more notifications hidden")
    }
}

private struct ShuttleProfileBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let profile: ShuttleProfile

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var fillColor: Color {
        isDark ? Color.orange.opacity(0.2) : Color.orange.opacity(0.12)
    }

    private var borderColor: Color {
        isDark ? Color.orange.opacity(0.55) : Color.orange.opacity(0.34)
    }

    private var textColor: Color {
        isDark ? Color.orange.opacity(0.96) : Color(red: 0.72, green: 0.36, blue: 0.02)
    }

    var body: some View {
        if profile == .dev {
            Label("DEV", systemImage: "hammer.fill")
                .font(.caption2.weight(.bold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(textColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(fillColor)
                )
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: 1)
                )
                .shuttleHint("Shuttle Dev profile — isolated config, Application Support, preferences, and session root.")
                .accessibilityLabel("DEV profile")
        }
    }
}

private struct SidebarSearchField: View {
    @Environment(\.colorScheme) private var colorScheme

    let placeholder: String
    @Binding var text: String

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .shuttleHint("Clear the current search.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(chromePalette.sidebarSearchFieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(chromePalette.sidebarSearchFieldBorder, lineWidth: 1)
        )
    }
}

private struct SidebarDisclosureRow: View {
    let title: String
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SidebarGroupHeaderRow: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarStatusRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SidebarListRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let trailingAccessorySystemImage: String?
    let attentionCount: Int

    init(
        systemImage: String,
        iconColor: Color,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        trailingAccessorySystemImage: String? = nil,
        attentionCount: Int = 0
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.trailingAccessorySystemImage = trailingAccessorySystemImage
        self.attentionCount = attentionCount
    }

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    private var titleColor: Color {
        isSelected ? chromePalette.emphasizedSelectionText : .primary
    }

    private var subtitleColor: Color {
        isSelected ? chromePalette.emphasizedSelectionSecondaryText : .secondary
    }

    private var rowBackground: Color {
        isSelected ? chromePalette.emphasizedSelectionFill : .clear
    }

    private var trailingAccessoryColor: Color {
        isSelected ? chromePalette.emphasizedSelectionSecondaryText : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? .white : iconColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            if let trailingAccessorySystemImage {
                Image(systemName: trailingAccessorySystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trailingAccessoryColor)
                    .frame(width: 12)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: trailingAccessorySystemImage != nil)
        .animation(.easeOut(duration: 0.14), value: attentionCount)
    }
}

private struct HoverPinnableWorkspaceRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isPinned: Bool
    let canTogglePin: Bool
    var attentionCount: Int = 0
    let onSelect: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovering = false

    private let pinButtonSize: CGFloat = 18

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var hoverButtonSystemImage: String {
        isPinned ? "pin.slash.fill" : "pin.fill"
    }

    private var hoverButtonFill: Color {
        if isPinned {
            return isDark ? Color.white.opacity(0.2) : Color(nsColor: NSColor.controlColor).opacity(0.94)
        }
        return isDark ? Color.accentColor.opacity(0.92) : Color.accentColor
    }

    private var hoverButtonBorder: Color {
        if isPinned {
            return isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
        }
        return isDark ? Color.white.opacity(0.14) : Color.accentColor.opacity(0.24)
    }

    private var hoverButtonShadow: Color {
        Color.black.opacity(isDark ? 0.22 : 0.12)
    }

    private var hoverButtonForeground: Color {
        if isPinned {
            return isDark ? Color.white.opacity(0.92) : Color.primary.opacity(0.82)
        }
        return .white
    }

    private var hoverButtonHint: String {
        isPinned ? "Unpin workspace \(title)." : "Pin workspace \(title)."
    }

    private var hoverAnimation: Animation {
        .spring(response: 0.22, dampingFraction: 0.84, blendDuration: 0.08)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                SidebarListRow(
                    systemImage: systemImage,
                    iconColor: iconColor,
                    title: title,
                    subtitle: subtitle,
                    isSelected: isSelected,
                    trailingAccessorySystemImage: isPinned && !isHovering ? "pin.fill" : nil,
                    attentionCount: attentionCount
                )
            }
            .buttonStyle(.plain)

            if canTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: hoverButtonSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hoverButtonForeground)
                        .frame(width: pinButtonSize, height: pinButtonSize)
                        .background(
                            Circle()
                                .fill(hoverButtonFill)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(hoverButtonBorder, lineWidth: 0.75)
                        )
                        .shadow(color: hoverButtonShadow, radius: 5, y: 1)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .shuttleHint(hoverButtonHint)
                .padding(.trailing, 8)
                .scaleEffect(isHovering ? 1 : 0.84)
                .offset(x: isHovering ? 0 : 2)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityLabel(isPinned ? "Unpin Workspace" : "Pin Workspace")
                .animation(hoverAnimation, value: isHovering)
                .animation(.easeOut(duration: 0.16), value: isPinned)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering in
            withAnimation(hoverAnimation) {
                isHovering = hovering
            }
        }
    }
}

private struct HoverDeletableSessionRow: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    var attentionCount: Int = 0
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private let deleteButtonSize: CGFloat = 18

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                SidebarListRow(
                    systemImage: systemImage,
                    iconColor: iconColor,
                    title: title,
                    subtitle: subtitle,
                    isSelected: isSelected,
                    attentionCount: attentionCount
                )
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: deleteButtonSize, height: deleteButtonSize)
                    .background(
                        Circle()
                            .fill(Color.red.opacity(0.92))
                    )
            }
            .buttonStyle(.plain)
            .shuttleHint("Delete session \(title)…")
            .padding(.trailing, 8)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityLabel("Delete Session")
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Detail View with Live Terminal

private struct DetailView: View {
    @EnvironmentObject private var model: ShuttleAppModel

    var body: some View {
        if let bundle = model.sessionBundle {
            SessionDetailView(bundle: bundle)
                .id(bundle.session.rawID)
        } else if let workspace = model.selectedWorkspace {
            VStack(alignment: .leading, spacing: 16) {
                Text(workspace.workspace.name)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Select or create a session to start working.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Welcome to Shuttle", systemImage: "launchpad")
        }
    }
}

// MARK: - Session Detail with Terminal Panes

private struct SessionDetailView: View {
    @EnvironmentObject private var model: ShuttleAppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var runtimeRegistry = GhosttyTabRuntimeRegistry.shared

    let bundle: SessionBundle

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    var body: some View {
        terminalArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rootPanes: [Pane] {
        bundle.panes
            .filter { $0.parentPaneID == nil }
            .sorted(by: paneSort)
    }

    @ViewBuilder
    private var terminalArea: some View {
        if bundle.tabs.isEmpty {
            ContentUnavailableView(
                "No Tabs",
                systemImage: "rectangle.split.3x1",
                description: Text("Create a new session to open terminal panes")
            )
        } else if let rootPane = rootPanes.first, rootPanes.count == 1 {
            paneView(rootPane)
        } else if !rootPanes.isEmpty {
            VSplitView {
                ForEach(rootPanes, id: \.rawID) { pane in
                    paneView(pane)
                        .frame(minHeight: 120)
                }
            }
        } else {
            leafPaneView(for: bundle.tabs)
        }
    }

    private func paneView(_ pane: Pane) -> AnyView {
        let children = childPanes(of: pane)
        guard !children.isEmpty else {
            return AnyView(leafPaneView(in: pane))
        }

        switch pane.splitDirection {
        case .left, .right:
            if children.count == 2 {
                return AnyView(
                    ResizablePaneSplitView(
                        paneRawID: pane.rawID,
                        axis: .horizontal,
                        ratio: pane.ratio ?? 0.5,
                        first: paneView(children[0]),
                        second: paneView(children[1]),
                        onRatioChanged: { _ in },
                        onRatioCommitted: { ratio in
                            Task { await model.resizePane(paneRawID: pane.rawID, ratio: ratio) }
                        }
                    )
                )
            }
            return AnyView(
                HStack(spacing: 0) {
                    ForEach(children, id: \.rawID) { child in
                        paneView(child)
                            .frame(minWidth: 180)
                    }
                }
            )
        case .up, .down:
            if children.count == 2 {
                return AnyView(
                    ResizablePaneSplitView(
                        paneRawID: pane.rawID,
                        axis: .vertical,
                        ratio: pane.ratio ?? 0.5,
                        first: paneView(children[0]),
                        second: paneView(children[1]),
                        onRatioChanged: { _ in },
                        onRatioCommitted: { ratio in
                            Task { await model.resizePane(paneRawID: pane.rawID, ratio: ratio) }
                        }
                    )
                )
            }
            return AnyView(
                VStack(spacing: 0) {
                    ForEach(children, id: \.rawID) { child in
                        paneView(child)
                            .frame(minHeight: 120)
                    }
                }
            )
        case .none:
            return AnyView(leafPaneView(in: pane))
        }
    }

    @ViewBuilder
    private func leafPaneView(in pane: Pane) -> some View {
        let paneTabs = tabs(in: pane)
        let shouldDimTerminal = model.focusedPaneRawID != nil && !model.isFocusedPane(pane.rawID)

        if paneTabs.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Empty Pane",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Create a new tab here or split another pane into this area.")
                )
                Button {
                    Task { await model.createTab(inPaneRawID: pane.rawID) }
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .shuttleHint("Create a new tab in this pane.")
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        } else if let activeTab = model.activeTab(in: pane.rawID, tabs: paneTabs) {
            VStack(spacing: 0) {
                paneTabBar(pane: pane, tabs: paneTabs, activeTab: activeTab)
                terminalForTab(activeTab, isDimmed: shouldDimTerminal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func leafPaneView(for tabs: [ShuttleKit.Tab]) -> some View {
        if let first = tabs.first {
            terminalForTab(first)
        }
    }

    private func paneTabBar(pane: Pane, tabs: [ShuttleKit.Tab], activeTab: ShuttleKit.Tab) -> some View {
        let isFocusedPane = model.isFocusedPane(pane.rawID)
        let tabIDs = tabs.map(\.rawID)

        return GeometryReader { proxy in
            let availableTabWidth = max(
                proxy.size.width
                    - (PaneTabBarMetrics.horizontalPadding * 2)
                    - PaneTabBarMetrics.addButtonWidth
                    - PaneTabBarMetrics.interItemSpacing,
                PaneTabBarMetrics.minTabWidth
            )
            let tabWidth = ghosttyStyleTabWidth(availableWidth: availableTabWidth, tabCount: tabs.count)

            HStack(spacing: PaneTabBarMetrics.interItemSpacing) {
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: PaneTabBarMetrics.interItemSpacing) {
                            ForEach(tabs, id: \.rawID) { tab in
                                let isActive = model.isActiveTab(tab.rawID, paneRawID: pane.rawID)
                                let title = runtimeRegistry.liveTitle(for: tab.rawID, fallbackTitle: tab.title)

                                GhosttyPaneTabCell(
                                    title: title,
                                    isActive: isActive,
                                    isFocusedPane: isFocusedPane,
                                    needsAttention: tab.needsAttention,
                                    attentionMessage: tab.attentionMessage,
                                    onSelect: {
                                        model.selectTab(tab.rawID)
                                    },
                                    onClose: {
                                        Task { await model.closeTab(tab.rawID) }
                                    }
                                )
                                .frame(width: tabWidth, height: PaneTabBarMetrics.tabHeight)
                                .id(tab.rawID)
                            }
                        }
                        .padding(.leading, PaneTabBarMetrics.horizontalPadding)
                        .padding(.trailing, 2)
                        .padding(.vertical, PaneTabBarMetrics.verticalPadding)
                    }
                    .onAppear {
                        scrollPaneTabStrip(scrollProxy, to: activeTab.rawID)
                    }
                    .onChange(of: activeTab.rawID) { _, newValue in
                        scrollPaneTabStrip(scrollProxy, to: newValue)
                    }
                    .onChange(of: tabIDs) { _, _ in
                        scrollPaneTabStrip(scrollProxy, to: activeTab.rawID)
                    }
                }

                Button {
                    Task { await model.createTab(inPaneRawID: pane.rawID, sourceTabRawID: activeTab.rawID) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: PaneTabBarMetrics.addButtonWidth, height: PaneTabBarMetrics.tabHeight)
                        .background(Color(nsColor: NSColor.controlBackgroundColor).opacity(isFocusedPane ? 0.62 : 0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.18), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .shuttleHint("Create a new tab in this pane.")
                .foregroundStyle(Color.primary.opacity(isFocusedPane ? 0.88 : 0.66))
                .padding(.trailing, PaneTabBarMetrics.horizontalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: PaneTabBarMetrics.barHeight)
        .background(.bar)
        .background(isFocusedPane ? chromePalette.focusedTabBarTint : Color.clear)
    }

    private func ghosttyStyleTabWidth(availableWidth: CGFloat, tabCount: Int) -> CGFloat {
        guard tabCount > 0 else { return PaneTabBarMetrics.minTabWidth }

        let totalSpacing = CGFloat(max(tabCount - 1, 0)) * PaneTabBarMetrics.interItemSpacing
        let computedWidth = floor((availableWidth - totalSpacing) / CGFloat(tabCount))
        return max(PaneTabBarMetrics.minTabWidth, computedWidth)
    }

    private func scrollPaneTabStrip(_ proxy: ScrollViewProxy, to tabRawID: Int64) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(tabRawID, anchor: .center)
            }
        }
    }

    private func childPanes(of pane: Pane) -> [Pane] {
        bundle.panes
            .filter { $0.parentPaneID == pane.rawID }
            .sorted(by: paneSort)
    }

    private func tabs(in pane: Pane) -> [ShuttleKit.Tab] {
        bundle.tabs
            .filter { $0.paneID == pane.rawID }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
    }

    private func paneSort(_ lhs: Pane, _ rhs: Pane) -> Bool {
        if lhs.positionIndex == rhs.positionIndex {
            return lhs.rawID < rhs.rawID
        }
        return lhs.positionIndex < rhs.positionIndex
    }

    private func terminalForTab(_ tab: ShuttleKit.Tab, isDimmed: Bool = false) -> some View {
        let envVars = buildEnvironmentVariables(for: tab)
        return TerminalHostView(
            runtimeKey: tab.runtimeKey,
            workingDirectory: tab.cwd,
            command: tab.command,
            environmentVariables: envVars,
            prefersKeyboardFocus: model.isFocusedTab(tab.rawID),
            onFocus: { userInitiated in
                model.setFocusedTab(tab.rawID, userInitiated: userInitiated)
            }
        )
        .overlay {
            if isDimmed {
                Color.black.opacity(0.16)
                    .allowsHitTesting(false)
            }
        }
        .id(tab.runtimeKey)
    }

    private func buildEnvironmentVariables(for tab: ShuttleKit.Tab) -> [String: String] {
        let project = tab.projectID.flatMap { projectID in
            bundle.projects.first(where: { $0.rawID == projectID })
        }

        var env: [String: String]
        if let pane = bundle.panes.first(where: { $0.rawID == tab.paneID }) {
            env = TerminalEnvironmentContext(
                workspace: bundle.workspace,
                session: bundle.session,
                project: project,
                pane: pane,
                tab: tab,
                socketPath: nil
            ).environmentVariables
        } else {
            env = [
                "SHUTTLE_WORKSPACE_ID": bundle.workspace.id,
                "SHUTTLE_WORKSPACE_NAME": bundle.workspace.name,
                "SHUTTLE_SESSION_ID": bundle.session.id,
                "SHUTTLE_SESSION_NAME": bundle.session.name,
                "SHUTTLE_TAB_ID": tab.id,
                "SHUTTLE_SESSION_ROOT": bundle.session.sessionRootPath,
            ]

            if let project {
                env["SHUTTLE_PROJECT_ID"] = project.id
                env["SHUTTLE_PROJECT_NAME"] = project.name
                env["SHUTTLE_PROJECT_PATH"] = project.path
                env["SHUTTLE_PROJECT_KIND"] = project.kind.rawValue
            }
        }

        model.restoreEnvironment(for: bundle.session.rawID, tabRawID: tab.rawID).forEach {
            env[$0.key] = $0.value
        }

        return env
    }

}

private enum PaneTabBarMetrics {
    static let barHeight: CGFloat = 34
    static let tabHeight: CGFloat = 26
    static let minTabWidth: CGFloat = 160
    static let addButtonWidth: CGFloat = 26
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 4
    static let interItemSpacing: CGFloat = 4
}

private struct GhosttyPaneTabCell: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let isActive: Bool
    let isFocusedPane: Bool
    let needsAttention: Bool
    let attentionMessage: String?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    private var showsAttentionTreatment: Bool {
        needsAttention && !(isActive && isFocusedPane)
    }

    private var fillColor: Color {
        if showsAttentionTreatment {
            return colorScheme == .dark
                ? Color.orange.opacity(0.18)
                : Color.orange.opacity(0.12)
        }

        if isActive {
            return isFocusedPane ? chromePalette.emphasizedSelectionFill : chromePalette.inactivePaneActiveTabFill
        }

        if isHovering {
            return isFocusedPane ? chromePalette.hoveredTabFill : chromePalette.unfocusedHoveredTabFill
        }

        return isFocusedPane ? chromePalette.restingTabFill : chromePalette.unfocusedRestingTabFill
    }

    private var borderColor: Color {
        if showsAttentionTreatment {
            return Color.orange.opacity(0.5)
        }

        if isActive {
            return chromePalette.selectedBorderColor(isActive: true)
        }

        if isHovering {
            return chromePalette.hoveredBorderColor(isFocusedPane: isFocusedPane)
        }

        return chromePalette.selectedBorderColor(isActive: false)
    }

    private var textColor: Color {
        if showsAttentionTreatment {
            return Color.orange
        }

        if isActive {
            return isFocusedPane ? chromePalette.activeTabText : chromePalette.inactivePaneActiveTabText
        }

        return isFocusedPane ? chromePalette.focusedInactiveTabText : chromePalette.unfocusedInactiveTabText
    }

    private var closeIconColor: Color {
        if isActive {
            return isFocusedPane ? chromePalette.activeHoverCloseIcon : chromePalette.inactivePaneActiveTabText
        }

        return chromePalette.inactiveHoverCloseIcon
    }

    private var tabOpacity: Double {
        if showsAttentionTreatment { return 1.0 }
        return isFocusedPane ? 1.0 : (isActive ? 0.72 : 0.5)
    }

    var body: some View {
        ZStack {
            Button(action: onSelect) {
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shuttleHint("Select \(title).")

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shuttleHint("Close \(title).")
                .foregroundStyle(closeIconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
            }
        }
        .background(fillColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if isActive && isFocusedPane && !showsAttentionTreatment {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 1)
            }
        }
        .overlay(alignment: .top) {
            if showsAttentionTreatment {
                Capsule()
                    .fill(Color.orange)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsAttentionTreatment {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .padding(4)
                    .help(attentionMessage ?? "Needs attention")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .shadow(color: chromePalette.tabShadow(isActive: isActive, isFocusedPane: isFocusedPane), radius: colorScheme == .dark ? 2 : 1, y: 1)
        .opacity(tabOpacity)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct SessionInfoPopoverView: View {
    let bundle: SessionBundle
    let restoreMessage: String?
    let onRename: () -> Void
    let onClose: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Info")
                .font(.headline)

            LabeledContent("Workspace") {
                Text(bundle.workspace.name)
                    .font(.caption)
            }

            LabeledContent("Session") {
                Text(bundle.session.name)
                    .font(.caption)
            }

            LabeledContent("Layout") {
                Text(bundle.session.layoutName ?? LayoutPresetStore.defaultPresetID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Root") {
                Text(bundle.session.sessionRootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let restoreMessage {
                Divider()
                Label("Restored", systemImage: "arrow.clockwise.circle")
                    .font(.subheadline.weight(.medium))
                Text(restoreMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !bundle.sessionProjects.isEmpty {
                Divider()
                Text("Projects")
                    .font(.subheadline.weight(.medium))
            }

            ForEach(bundle.sessionProjects, id: \.projectID) { sp in
                let project = bundle.projects.first(where: { $0.rawID == sp.projectID })
                let checkoutPresentation = shuttleCheckoutPresentation(
                    for: sp,
                    sessionRootPath: bundle.session.sessionRootPath
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: project?.kind == .try ? "sparkles" : "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(project?.name ?? "Unknown")
                            .fontWeight(.medium)
                    }
                    LabeledContent("Checkout") {
                        Text(checkoutPresentation.shortLabel)
                    }
                    .font(.caption)
                    if let detail = checkoutPresentation.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Path") {
                        Text(sp.checkoutPath)
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Rename…", action: onRename)
                        .shuttleHint("Rename this session.")
                    Button("Close", action: onClose)
                        .disabled(bundle.session.status == .closed)
                        .shuttleHint("Archive this session without deleting its on-disk metadata.")
                    Spacer()
                }

                HStack {
                    Spacer()
                    Button("Delete Session…", role: .destructive, action: onDelete)
                        .shuttleHint("Delete this session.")
                }
            }
        }
    }
}

private struct ResizablePaneSplitView: View {
    let paneRawID: Int64
    let axis: Axis.Set
    let ratio: Double
    let first: AnyView
    let second: AnyView
    let onRatioChanged: (Double) -> Void
    let onRatioCommitted: (Double) -> Void

    @State private var dragStartRatio: Double?
    @State private var liveRatio: Double?
    @State private var isHoveringDivider = false

    private let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let availableExtent = max(primaryExtent(in: proxy.size) - dividerThickness, 1)
            let effectiveRatio = clampedRatio(liveRatio ?? ratio, availableExtent: availableExtent)
            let firstExtent = availableExtent * effectiveRatio
            let secondExtent = availableExtent - firstExtent

            group(
                firstExtent: firstExtent,
                secondExtent: secondExtent,
                fullSize: proxy.size,
                effectiveRatio: effectiveRatio,
                availableExtent: availableExtent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            liveRatio = ratio
        }
        .onChange(of: ratio) { _, newValue in
            guard dragStartRatio == nil else { return }
            liveRatio = newValue
        }
    }

    @ViewBuilder
    private func group(
        firstExtent: CGFloat,
        secondExtent: CGFloat,
        fullSize: CGSize,
        effectiveRatio: Double,
        availableExtent: CGFloat
    ) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                first
                    .frame(width: firstExtent, height: fullSize.height)
                divider(effectiveRatio: effectiveRatio, availableExtent: availableExtent)
                    .frame(width: dividerThickness, height: fullSize.height)
                second
                    .frame(width: secondExtent, height: fullSize.height)
            }
        } else {
            VStack(spacing: 0) {
                first
                    .frame(width: fullSize.width, height: firstExtent)
                divider(effectiveRatio: effectiveRatio, availableExtent: availableExtent)
                    .frame(width: fullSize.width, height: dividerThickness)
                second
                    .frame(width: fullSize.width, height: secondExtent)
            }
        }
    }

    private func divider(effectiveRatio: Double, availableExtent: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Rectangle()
                .fill(isHoveringDivider ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.35))
                .frame(width: axis == .horizontal ? 2 : nil, height: axis == .vertical ? 2 : nil)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringDivider = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartRatio == nil {
                        dragStartRatio = effectiveRatio
                    }
                    let anchorRatio = dragStartRatio ?? effectiveRatio
                    let anchorExtent = CGFloat(anchorRatio) * availableExtent
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    let nextRatio = clampedRatio((anchorExtent + translation) / availableExtent, availableExtent: availableExtent)
                    liveRatio = nextRatio
                    onRatioChanged(nextRatio)
                }
                .onEnded { value in
                    let anchorRatio = dragStartRatio ?? effectiveRatio
                    let anchorExtent = CGFloat(anchorRatio) * availableExtent
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    let nextRatio = clampedRatio((anchorExtent + translation) / availableExtent, availableExtent: availableExtent)
                    liveRatio = nextRatio
                    dragStartRatio = nil
                    onRatioChanged(nextRatio)
                    onRatioCommitted(nextRatio)
                }
        )
    }

    private func primaryExtent(in size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func clampedRatio(_ rawRatio: Double, availableExtent: CGFloat) -> Double {
        let minimumPaneExtent: CGFloat = axis == .horizontal ? 180 : 120
        let minimumRatio = min(max(minimumPaneExtent / availableExtent, 0.1), 0.45)
        let maximumRatio = 1 - minimumRatio
        guard minimumRatio < maximumRatio else { return 0.5 }
        return min(max(rawRatio, minimumRatio), maximumRatio)
    }
}
