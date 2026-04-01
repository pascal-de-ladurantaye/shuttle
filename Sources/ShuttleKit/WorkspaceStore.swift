import Foundation

public struct WorkspaceSnapshot: Hashable, Sendable, Codable {
    public var workspaces: [WorkspaceDetails]

    public init(workspaces: [WorkspaceDetails]) {
        self.workspaces = workspaces
    }
}

public struct SessionActivation: Hashable, Sendable, Codable {
    public var bundle: SessionBundle
    public var wasRestored: Bool

    public init(bundle: SessionBundle, wasRestored: Bool) {
        self.bundle = bundle
        self.wasRestored = wasRestored
    }
}

public actor WorkspaceStore {
    public nonisolated let paths: ShuttlePaths
    private let configManager: ConfigManager
    private let persistence: PersistenceStore
    private let discoveryManager: DiscoveryManager
    private let terminalEngine: TerminalEngine

    public init(
        paths: ShuttlePaths = ShuttlePaths(),
        configManager: ConfigManager? = nil,
        persistence: PersistenceStore? = nil,
        discoveryManager: DiscoveryManager = DiscoveryManager(),
        terminalEngine: TerminalEngine = PlaceholderTerminalEngine()
    ) throws {
        let resolvedPersistence = try persistence ?? PersistenceStore(paths: paths)

        self.paths = paths
        self.configManager = configManager ?? ConfigManager(paths: paths)
        self.persistence = resolvedPersistence
        self.discoveryManager = discoveryManager
        self.terminalEngine = terminalEngine

        _ = try resolvedPersistence.ensureGlobalWorkspace()
    }

    public func config() throws -> ShuttleConfig {
        try configManager.load()
    }

    public func bootstrapHint() -> String {
        terminalEngine.bootstrapHint()
    }

    public func scanProjects(overrideRoots: [String] = []) throws -> ScanReport {
        let config = try configManager.load(overrideRoots: overrideRoots)
        var report = try discoveryManager.scan(config: config, persistence: persistence)
        report.removedWorkspaces = try pruneMissingProjectWorkspaces()
        return report
    }

    public func listProjects() throws -> [Project] {
        try persistence.listProjects()
    }

    public func projectDetails(token: String) throws -> ProjectDetails {
        guard let project = try persistence.project(matching: token) else {
            throw ShuttleError.notFound(entity: "Project", token: token)
        }

        let workspace = project.defaultWorkspaceID.flatMap { try? persistence.workspace(id: $0) }
        return ProjectDetails(project: project, defaultWorkspace: workspace)
    }

    public func listWorkspaces() throws -> [WorkspaceDetails] {
        try persistence.listWorkspaceDetails()
    }

    public func workspaceDetails(token: String) throws -> WorkspaceDetails {
        guard let details = try persistence.workspaceDetails(matching: token) else {
            throw ShuttleError.notFound(entity: "Workspace", token: token)
        }
        return details
    }

    public func workspaceSnapshot() throws -> WorkspaceSnapshot {
        WorkspaceSnapshot(workspaces: try listWorkspaces())
    }

    public func listSessions(workspaceToken: String? = nil) throws -> [Session] {
        if let workspaceToken {
            let workspace = try resolveWorkspace(workspaceToken)
            return try persistence.listSessions(workspaceID: workspace.rawID)
        }
        return try persistence.listSessions()
    }

    public func sessionBundle(token: String) throws -> SessionBundle {
        guard let bundle = try persistence.sessionBundle(matching: token) else {
            throw ShuttleError.notFound(entity: "Session", token: token)
        }
        return bundle
    }

    public func renameSession(token: String, name: String) throws -> SessionBundle {
        let bundle = try sessionBundle(token: token)
        guard let requestedName = sanitizeSessionName(name) else {
            throw ShuttleError.invalidArguments("Session name cannot be empty")
        }

        let existingSessions = try persistence.listSessions(workspaceID: bundle.workspace.rawID)
        let existingNames = Set(existingSessions.filter { $0.rawID != bundle.session.rawID }.map(\.name))
        let existingSlugs = Set(existingSessions.filter { $0.rawID != bundle.session.rawID }.map(\.slug))
        let uniqueDisplayName = uniqueName(base: requestedName, existing: existingNames)
        let uniqueSlug = uniqueName(base: slugify(uniqueDisplayName), existing: existingSlugs)
        let updated = try persistence.renameSession(id: bundle.session.rawID, name: uniqueDisplayName, slug: uniqueSlug)
        guard let updatedBundle = try persistence.sessionBundle(id: updated.rawID) else {
            throw ShuttleError.notFound(entity: "Session", token: token)
        }
        return updatedBundle
    }

    public func closeSession(token: String) throws -> SessionBundle {
        let bundle = try sessionBundle(token: token)
        try persistence.updateSessionLifecycle(
            sessionID: bundle.session.rawID,
            status: .closed,
            lastActiveAt: Date(),
            closedAt: Date()
        )
        guard let updatedBundle = try persistence.sessionBundle(id: bundle.session.rawID) else {
            throw ShuttleError.notFound(entity: "Session", token: token)
        }
        return updatedBundle
    }

    public func applyLayout(toSession sessionToken: String, layoutName: String) throws -> SessionBundle {
        let bundle = try sessionBundle(token: sessionToken)
        guard let preset = try LayoutPresetStore(paths: paths).preset(named: layoutName) else {
            throw ShuttleError.notFound(entity: "Layout", token: layoutName)
        }

        let existingTabRawIDs = bundle.tabs.map(\.rawID)
        let updatedSession = try persistence.transaction {
            let session = try persistence.updateSessionLayoutName(id: bundle.session.rawID, layoutName: preset.id)
            try persistence.deleteSessionLayout(sessionID: bundle.session.rawID)
            try applyInitialLayout(session: session, preset: preset)
            try persistence.updateSessionLifecycle(sessionID: bundle.session.rawID, status: .active, lastActiveAt: Date(), closedAt: nil)
            guard let updatedBundle = try persistence.sessionBundle(id: bundle.session.rawID) else {
                throw ShuttleError.notFound(entity: "Session", token: sessionToken)
            }
            return updatedBundle
        }
        removePersistentArtifacts(for: existingTabRawIDs)
        return updatedSession
    }

    public func saveCurrentLayout(sessionToken: String, name: String, description: String? = nil) throws -> LayoutPreset {
        let bundle = try sessionBundle(token: sessionToken)
        guard let trimmedName = sanitizeSessionName(name) else {
            throw ShuttleError.invalidArguments("Layout name cannot be empty")
        }

        let layoutStore = LayoutPresetStore(paths: paths)
        let existing = try layoutStore.preset(named: trimmedName)
        let existingIDs = Set(try layoutStore.listPresets().map(\.id))
        let basePresetID = slugify(trimmedName).isEmpty ? "layout" : slugify(trimmedName)
        let presetID: String
        let origin: LayoutPresetOrigin
        if let existing, !existing.isBuiltIn {
            presetID = existing.id
            origin = .custom
        } else {
            presetID = uniqueName(base: basePresetID, existing: existingIDs)
            origin = .custom
        }

        let preset = LayoutPreset(
            id: presetID,
            name: trimmedName,
            description: description,
            origin: origin,
            root: layoutTemplate(from: bundle)
        ).normalized()
        try layoutStore.saveCustomPreset(preset)
        return preset
    }

    public func ensureSession(
        workspaceToken: String,
        name: String,
        layoutName: String?,
        seedAgentGuide: Bool = false
    ) throws -> ShuttleSessionMutationResult {
        let workspace = try resolveWorkspace(workspaceToken)
        guard let requestedName = sanitizeSessionName(name) else {
            throw ShuttleError.invalidArguments("Session name cannot be empty")
        }

        if let existing = try sessionBundle(inWorkspaceID: workspace.rawID, named: requestedName) {
            if let layoutName {
                let preset = try resolveLayoutPreset(named: layoutName)
                let matchesRequestedLayout = existing.session.layoutName == preset.id
                    || sessionLayout(existing) == preset.root.normalized()
                guard matchesRequestedLayout else {
                    throw ShuttleError.invalidArguments(
                        "Session '\(existing.session.name)' already exists with a different recorded layout; use layout ensure-applied --session \(existing.session.id) --layout \(preset.id)"
                    )
                }
            }
            return ShuttleSessionMutationResult(
                status: ShuttleMutationStatus(changed: false, action: "noop", noopReason: "already_present"),
                bundle: existing
            )
        }

        let bundle = try createSession(
            workspaceToken: workspace.id,
            name: requestedName,
            layoutName: layoutName,
            seedAgentGuide: seedAgentGuide
        )
        return ShuttleSessionMutationResult(
            status: ShuttleMutationStatus(changed: true, action: "created"),
            bundle: bundle
        )
    }

    public func ensureSessionClosed(token: String) throws -> ShuttleSessionMutationResult {
        let bundle = try sessionBundle(token: token)
        guard bundle.session.status != .closed else {
            return ShuttleSessionMutationResult(
                status: ShuttleMutationStatus(changed: false, action: "noop", noopReason: "already_closed"),
                bundle: bundle
            )
        }

        let closed = try closeSession(token: token)
        return ShuttleSessionMutationResult(
            status: ShuttleMutationStatus(changed: true, action: "closed"),
            bundle: closed
        )
    }

    public func ensureLayoutApplied(sessionToken: String, layoutName: String) throws -> ShuttleLayoutMutationResult {
        let bundle = try sessionBundle(token: sessionToken)
        let preset = try resolveLayoutPreset(named: layoutName)
        let alreadyApplied = bundle.session.layoutName == preset.id || sessionLayout(bundle) == preset.root.normalized()
        if alreadyApplied {
            return ShuttleLayoutMutationResult(
                status: ShuttleMutationStatus(changed: false, action: "noop", noopReason: "already_applied"),
                bundle: bundle,
                layout: preset
            )
        }

        let updated = try applyLayout(toSession: sessionToken, layoutName: preset.id)
        return ShuttleLayoutMutationResult(
            status: ShuttleMutationStatus(changed: true, action: "applied"),
            bundle: updated,
            layout: preset
        )
    }

    public func previewDeleteSession(token: String) throws -> SessionDeletionPreview {
        try deletionPreview(for: sessionBundle(token: token))
    }

    public func deleteSession(token: String) throws -> SessionDeletionResult {
        let bundle = try sessionBundle(token: token)
        let preview = try deletionPreview(for: bundle)

        var warnings = preview.projects.flatMap(\.warnings)
        removeGlobalSessionSnapshotIfNeeded(sessionRawID: bundle.session.rawID)
        removePersistentArtifacts(for: bundle.tabs.map(\.rawID))
        try persistence.deleteSession(id: bundle.session.rawID)
        if let warning = removeDirectoryRecursively(atPath: bundle.session.sessionRootPath) {
            warnings.append(warning)
        }

        return SessionDeletionResult(
            sessionID: bundle.session.rawID,
            sessionName: bundle.session.name,
            warnings: uniqueWarnings(warnings)
        )
    }

    public func prepareForAppLaunch() throws {
        try persistence.markAllActiveSessionsRestorable()
    }

    public func activateSession(token: String) throws -> SessionActivation {
        guard let existing = try persistence.session(matching: token) else {
            throw ShuttleError.notFound(entity: "Session", token: token)
        }
        let existingBundle = try persistence.sessionBundle(id: existing.rawID)
        let hasCheckpoint = existingBundle?.tabs.contains(where: { $0.runtimeStatus == .idle }) ?? false
        let wasRestored = (existing.status == .restorable || existing.status == .closed) && hasCheckpoint
        try persistence.updateSessionLifecycle(
            sessionID: existing.rawID,
            status: .active,
            lastActiveAt: Date(),
            closedAt: nil
        )
        guard let bundle = try persistence.sessionBundle(id: existing.rawID) else {
            throw ShuttleError.notFound(entity: "Session", token: token)
        }
        return SessionActivation(bundle: bundle, wasRestored: wasRestored)
    }

    public func splitPane(sessionToken: String, paneRawID: Int64, direction: SplitDirection, sourceTabRawID: Int64? = nil) throws -> SessionBundle {
        guard let session = try persistence.session(matching: sessionToken) else {
            throw ShuttleError.notFound(entity: "Session", token: sessionToken)
        }

        guard let existingBundle = try persistence.sessionBundle(id: session.rawID),
              existingBundle.panes.contains(where: { $0.rawID == paneRawID }) else {
            throw ShuttleError.invalidArguments("Pane \(Pane.makeRef(paneRawID)) does not belong to session \(sessionToken)")
        }

        return try persistence.splitPane(
            paneID: paneRawID,
            direction: direction,
            sourceTabID: sourceTabRawID
        )
    }

    public func resizePane(sessionToken: String, paneRawID: Int64, ratio: Double) throws {
        guard let session = try persistence.session(matching: sessionToken) else {
            throw ShuttleError.notFound(entity: "Session", token: sessionToken)
        }

        guard let existingBundle = try persistence.sessionBundle(id: session.rawID),
              existingBundle.panes.contains(where: { $0.rawID == paneRawID }) else {
            throw ShuttleError.invalidArguments("Pane \(Pane.makeRef(paneRawID)) does not belong to session \(sessionToken)")
        }

        try persistence.updatePaneRatio(paneID: paneRawID, ratio: ratio)
    }

    public func createTab(sessionToken: String, paneRawID: Int64, sourceTabRawID: Int64? = nil) throws -> SessionBundle {
        guard let session = try persistence.session(matching: sessionToken) else {
            throw ShuttleError.notFound(entity: "Session", token: sessionToken)
        }

        guard let existingBundle = try persistence.sessionBundle(id: session.rawID),
              existingBundle.panes.contains(where: { $0.rawID == paneRawID }) else {
            throw ShuttleError.invalidArguments("Pane \(Pane.makeRef(paneRawID)) does not belong to session \(sessionToken)")
        }

        return try persistence.openTab(paneID: paneRawID, sourceTabID: sourceTabRawID)
    }

    public func closeTab(sessionToken: String, tabRawID: Int64) throws -> SessionBundle {
        guard let session = try persistence.session(matching: sessionToken) else {
            throw ShuttleError.notFound(entity: "Session", token: sessionToken)
        }

        guard let existingBundle = try persistence.sessionBundle(id: session.rawID),
              existingBundle.tabs.contains(where: { $0.rawID == tabRawID }) else {
            throw ShuttleError.invalidArguments("Tab \(Tab.makeRef(tabRawID)) does not belong to session \(sessionToken)")
        }

        return try persistence.closeTab(tabID: tabRawID)
    }

    public func checkpointTab(
        rawID: Int64,
        title: String? = nil,
        cwd: String? = nil,
        scrollback: String? = nil,
        updateScrollback: Bool = false
    ) throws {
        try persistence.updateTabRestorationState(
            tabID: rawID,
            title: normalizedCheckpointValue(title),
            cwd: normalizedCheckpointValue(cwd),
            runtimeStatus: .idle
        )
        if updateScrollback {
            try ShuttleScrollbackReplayStore.persist(
                scrollback: scrollback,
                forTabRawID: rawID,
                paths: paths
            )
        }
    }

    public func createSession(
        workspaceToken: String,
        name: String?,
        layoutName: String?,
        seedAgentGuide: Bool = false
    ) throws -> SessionBundle {
        let config = try configManager.load()
        let workspace = try resolveWorkspace(workspaceToken)
        let projects = try persistence.projectsForWorkspaceID(workspace.rawID)
        let isGlobalWorkspace = workspace.createdFrom == .global
        guard isGlobalWorkspace || !projects.isEmpty else {
            throw ShuttleError.invalidArguments("Workspace '\(workspace.name)' has no projects")
        }
        guard isGlobalWorkspace || projects.count == 1 else {
            throw ShuttleError.unsupported("Creating sessions in multi-project workspaces is unavailable in Shuttle's single-project mode")
        }

        let resolvedPreset: LayoutPreset?
        if let layoutName {
            guard let preset = try LayoutPresetStore(paths: paths).preset(named: layoutName) else {
                throw ShuttleError.notFound(entity: "Layout", token: layoutName)
            }
            resolvedPreset = preset
        } else {
            resolvedPreset = nil
        }

        let existingSessions = try persistence.listSessions(workspaceID: workspace.rawID)
        let displayBase = sanitizeSessionName(name) ?? defaultSessionName()
        let uniqueDisplayName = uniqueName(base: displayBase, existing: Set(existingSessions.map(\.name)))
        let uniqueSlug = uniqueName(base: slugify(uniqueDisplayName), existing: Set(existingSessions.map(\.slug)))
        let sessionRoot = try createSessionRoot(config: config, workspace: workspace, sessionSlug: uniqueSlug)
        let session = try persistence.createSession(
            workspaceID: workspace.rawID,
            name: uniqueDisplayName,
            slug: uniqueSlug,
            sessionRootPath: sessionRoot,
            layoutName: layoutName
        )

        if !isGlobalWorkspace {
            for project in projects {
                let sessionProject = try prepareSessionProject(
                    session: session,
                    project: project
                )
                try persistence.insertSessionProject(sessionProject)
            }
        }

        try applyInitialLayout(
            session: session,
            preset: resolvedPreset
        )

        let bundle = try persistence.sessionBundle(id: session.rawID)!
        if shouldWriteSessionAgentGuide(for: bundle, requested: seedAgentGuide) {
            _ = try? SessionAgentGuide.write(for: bundle)
        }
        return bundle
    }

    private struct CreatedLeafPane {
        let pane: Pane
        let template: LayoutPaneTemplate
    }

    private func applyInitialLayout(
        session: Session,
        preset: LayoutPreset?
    ) throws {
        let preset = preset
            ?? LayoutPresetStore.builtInPresets.first(where: { $0.id == LayoutPresetStore.defaultPresetID })
            ?? LayoutPreset(
                id: LayoutPresetStore.defaultPresetID,
                name: "Single",
                origin: .builtIn,
                root: LayoutPaneTemplate()
            )

        let normalizedRoot = preset.root.normalized()
        let leafPanes = try createPaneTree(
            template: normalizedRoot,
            sessionID: session.rawID,
            parentPaneID: nil,
            positionIndex: 0
        )
        let defaultTabTemplate = try persistence.defaultTabTemplate(sessionID: session.rawID)

        for leafPane in leafPanes {
            let tabTemplates = leafPane.template.tabs.isEmpty ? [LayoutTabTemplate()] : leafPane.template.tabs

            for tabIndex in tabTemplates.indices {
                let template = tabTemplates[tabIndex]
                _ = try persistence.createTab(
                    paneID: leafPane.pane.rawID,
                    title: initialTabTitle(
                        template: template,
                        fallbackTitle: defaultTabTemplate.title
                    ),
                    cwd: defaultTabTemplate.cwd,
                    projectID: defaultTabTemplate.projectID,
                    command: normalizedCheckpointValue(template.command),
                    envJSON: nil,
                    runtimeStatus: .placeholder,
                    positionIndex: tabIndex
                )
            }
        }
    }

    private func createPaneTree(
        template: LayoutPaneTemplate,
        sessionID: Int64,
        parentPaneID: Int64?,
        positionIndex: Int
    ) throws -> [CreatedLeafPane] {
        let normalized = template.normalized()
        let pane = try persistence.createPane(
            sessionID: sessionID,
            parentPaneID: parentPaneID,
            splitDirection: normalized.children.isEmpty ? nil : normalized.splitDirection,
            ratio: normalized.children.isEmpty ? nil : normalized.ratio,
            positionIndex: positionIndex
        )

        if normalized.children.isEmpty {
            return [CreatedLeafPane(pane: pane, template: normalized)]
        }

        return try normalized.children.enumerated().reduce(into: [CreatedLeafPane]()) { result, child in
            result.append(contentsOf: try createPaneTree(
                template: child.element,
                sessionID: sessionID,
                parentPaneID: pane.rawID,
                positionIndex: child.offset
            ))
        }
    }

    private func layoutTemplate(from bundle: SessionBundle) -> LayoutPaneTemplate {
        let panesByParent = Dictionary(grouping: bundle.panes, by: \.parentPaneID)
        let tabsByPaneID = Dictionary(grouping: bundle.tabs, by: \.paneID)

        func sortedPanes(_ panes: [Pane]) -> [Pane] {
            panes.sorted { lhs, rhs in
                if lhs.positionIndex == rhs.positionIndex {
                    return lhs.rawID < rhs.rawID
                }
                return lhs.positionIndex < rhs.positionIndex
            }
        }

        func sortedTabs(_ tabs: [Tab]) -> [Tab] {
            tabs.sorted { lhs, rhs in
                if lhs.positionIndex == rhs.positionIndex {
                    return lhs.rawID < rhs.rawID
                }
                return lhs.positionIndex < rhs.positionIndex
            }
        }

        func template(for pane: Pane) -> LayoutPaneTemplate {
            let children = sortedPanes(panesByParent[pane.rawID] ?? [])
            if children.isEmpty {
                let tabs = sortedTabs(tabsByPaneID[pane.rawID] ?? []).map { tab in
                    LayoutTabTemplate(
                        title: normalizedCheckpointValue(tab.title),
                        command: normalizedCheckpointValue(tab.command)
                    )
                }
                return LayoutPaneTemplate(tabs: tabs.isEmpty ? [LayoutTabTemplate()] : tabs)
            }

            return LayoutPaneTemplate(
                splitDirection: pane.splitDirection,
                ratio: pane.ratio,
                children: children.map(template(for:)),
                tabs: []
            ).normalized()
        }

        let roots = sortedPanes(panesByParent[nil] ?? [])
        if roots.count == 1, let root = roots.first {
            return template(for: root).normalized()
        }
        if !roots.isEmpty {
            return LayoutPaneTemplate(
                splitDirection: .right,
                ratio: 0.5,
                children: roots.map(template(for:)),
                tabs: []
            ).normalized()
        }
        return LayoutPaneTemplate()
    }

    private func initialTabTitle(
        template: LayoutTabTemplate,
        fallbackTitle: String
    ) -> String {
        if let title = normalizedCheckpointValue(template.title) {
            return title
        }
        if let command = normalizedCheckpointValue(template.command) {
            return command
        }
        return fallbackTitle
    }

    public func createTryProject(name: String) throws -> ProjectDetails {
        let config = try configManager.load()
        guard let triesRoot = config.expandedTriesRoot else {
            throw ShuttleError.configInvalid("tries_root is not configured")
        }

        let datePrefix = currentDatePrefix()
        let baseName = "\(datePrefix)-\(slugify(name))"
        let rootURL = URL(fileURLWithPath: triesRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? [])
        let directoryName = uniqueName(base: baseName, existing: existing)
        let projectURL = rootURL.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let project = try persistence.upsertProject(
            name: directoryName,
            path: projectURL.standardizedFileURL.path,
            kind: .try
        )
        let workspace = try persistence.ensureDefaultWorkspace(for: project)
        return ProjectDetails(project: project, defaultWorkspace: workspace)
    }

    public func createTrySession(
        name: String,
        sessionName: String? = nil,
        layoutName: String?,
        seedAgentGuide: Bool = false
    ) throws -> SessionBundle {
        let tryProject = try createTryProject(name: name)
        guard let workspace = tryProject.defaultWorkspace else {
            throw ShuttleError.io("Failed to create default workspace for try project")
        }
        let normalizedSessionName = normalizedCheckpointValue(sessionName) ?? "initial"
        return try createSession(
            workspaceToken: workspace.id,
            name: normalizedSessionName,
            layoutName: layoutName,
            seedAgentGuide: seedAgentGuide
        )
    }

    private func normalizedCheckpointValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func shouldWriteSessionAgentGuide(for bundle: SessionBundle, requested: Bool) -> Bool {
        guard SessionAgentGuide.shouldWrite(for: bundle) else {
            return false
        }
        if requested {
            return true
        }
        return FileManager.default.fileExists(atPath: SessionAgentGuide.fileURL(for: bundle.session).path)
    }

    private func resolveWorkspace(_ token: String) throws -> Workspace {
        guard let workspace = try persistence.workspace(matching: token) else {
            throw ShuttleError.notFound(entity: "Workspace", token: token)
        }
        return workspace
    }

    private func resolveLayoutPreset(named token: String) throws -> LayoutPreset {
        guard let preset = try LayoutPresetStore(paths: paths).preset(named: token) else {
            throw ShuttleError.notFound(entity: "Layout", token: token)
        }
        return preset.normalized()
    }

    private func sessionBundle(inWorkspaceID workspaceID: Int64, named name: String) throws -> SessionBundle? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSlug = slugify(normalizedName)
        let sessions = try persistence.listSessions(workspaceID: workspaceID)
        guard let match = sessions.first(where: { session in
            session.name.caseInsensitiveCompare(normalizedName) == .orderedSame || session.slug == normalizedSlug
        }) else {
            return nil
        }
        return try persistence.sessionBundle(id: match.rawID)
    }

    private func sessionLayout(_ bundle: SessionBundle) -> LayoutPaneTemplate {
        layoutTemplate(from: bundle).normalized()
    }

    private struct StaleProjectWorkspace {
        let project: Project
        let workspaceToDelete: WorkspaceDetails?
        let sessionBundles: [SessionBundle]
    }

    private func pruneMissingProjectWorkspaces() throws -> [Workspace] {
        let workspaceDetails = try persistence.listWorkspaceDetails()
        let workspaceDetailsByID = Dictionary(uniqueKeysWithValues: workspaceDetails.map { ($0.workspace.rawID, $0) })
        let staleProjects = try persistence.listProjects().compactMap { project in
            try staleProjectWorkspace(for: project, workspaceDetailsByID: workspaceDetailsByID)
        }

        guard !staleProjects.isEmpty else { return [] }

        let removedWorkspaces = staleProjects
            .compactMap { $0.workspaceToDelete?.workspace }
            .reduce(into: [Workspace]()) { result, workspace in
                guard !result.contains(where: { $0.rawID == workspace.rawID }) else { return }
                result.append(workspace)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        let workspaceIDsToDelete = removedWorkspaces.map(\.rawID)
        let removedWorkspaceIDs = Set(workspaceIDsToDelete)
        let sessionBundles = staleProjects.flatMap(\.sessionBundles)
        let removedSessionIDs = Set(sessionBundles.map { $0.session.rawID })

        try persistence.transaction {
            for workspaceID in workspaceIDsToDelete {
                try persistence.deleteWorkspace(id: workspaceID)
            }
            for project in staleProjects.map(\.project) {
                try persistence.deleteProject(id: project.rawID)
            }
        }

        removeSessionSnapshotIfNeeded(
            removedWorkspaceIDs: removedWorkspaceIDs,
            removedSessionIDs: removedSessionIDs
        )

        for bundle in sessionBundles {
            removePersistentArtifacts(for: bundle.tabs.map(\.rawID))
            _ = removeDirectoryRecursively(atPath: bundle.session.sessionRootPath)
        }

        return removedWorkspaces
    }

    private func staleProjectWorkspace(
        for project: Project,
        workspaceDetailsByID: [Int64: WorkspaceDetails]
    ) throws -> StaleProjectWorkspace? {
        guard !directoryExistsOnDisk(atPath: project.path) else {
            return nil
        }

        let workspaceToDelete = removableDefaultWorkspaceDetails(
            for: project,
            workspaceDetailsByID: workspaceDetailsByID
        )
        let prunedSessionBundles = try workspaceToDelete.map { try workspaceSessionBundles(for: $0) } ?? []
        return StaleProjectWorkspace(
            project: project,
            workspaceToDelete: workspaceToDelete,
            sessionBundles: prunedSessionBundles
        )
    }

    private func removableDefaultWorkspaceDetails(
        for project: Project,
        workspaceDetailsByID: [Int64: WorkspaceDetails]
    ) -> WorkspaceDetails? {
        guard let workspaceID = project.defaultWorkspaceID,
              let details = workspaceDetailsByID[workspaceID],
              details.workspace.createdFrom == .auto,
              details.workspace.isDefault,
              details.workspace.sourceProjectID == project.rawID,
              details.projects.allSatisfy({ $0.rawID == project.rawID }) else {
            return nil
        }
        return details
    }

    private func workspaceSessionBundles(for workspaceDetails: WorkspaceDetails) throws -> [SessionBundle] {
        try workspaceDetails.sessions.compactMap { session in
            try persistence.sessionBundle(id: session.rawID)
        }
    }

    private func directoryExistsOnDisk(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: standardizedPath(path), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func createSessionRoot(config: ShuttleConfig, workspace: Workspace, sessionSlug: String) throws -> String {
        let fileManager = FileManager.default
        let baseURL = URL(fileURLWithPath: config.expandedSessionRoot, isDirectory: true)
            .appendingPathComponent(workspace.slug, isDirectory: true)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)

        var rootURL = baseURL.appendingPathComponent(sessionSlug, isDirectory: true)
        var candidate = sessionSlug
        var index = 2
        while fileManager.fileExists(atPath: rootURL.path) {
            candidate = "\(sessionSlug)-\(index)"
            rootURL = baseURL.appendingPathComponent(candidate, isDirectory: true)
            index += 1
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL.path
    }

    private func prepareSessionProject(session: Session, project: Project) throws -> SessionProject {
        try directSessionProject(
            session: session,
            project: project,
            warning: nil
        )
    }

    private func directSessionProject(session: Session, project: Project, warning: String?) throws -> SessionProject {
        let checkoutPath = standardizedPath(project.path)
        return SessionProject(
            sessionID: session.rawID,
            projectID: project.rawID,
            checkoutType: .direct,
            checkoutPath: checkoutPath,
            metadataJSON: warning
        )
    }

    private func deletionPreview(for bundle: SessionBundle) throws -> SessionDeletionPreview {
        let projectsByID = Dictionary(uniqueKeysWithValues: bundle.projects.map { ($0.rawID, $0) })
        let projectPreviews = try bundle.sessionProjects.compactMap { sessionProject -> SessionDeletionProjectPreview? in
            guard let project = projectsByID[sessionProject.projectID] else { return nil }
            return try deletionProjectPreview(
                project: project,
                sessionProject: sessionProject,
                session: bundle.session
            )
        }

        return SessionDeletionPreview(
            session: bundle.session,
            workspace: bundle.workspace,
            projects: projectPreviews
        )
    }

    private func deletionProjectPreview(
        project: Project,
        sessionProject: SessionProject,
        session _: Session
    ) throws -> SessionDeletionProjectPreview {
        let checkoutPath = sessionProject.checkoutPath

        var warnings = metadataWarnings(from: sessionProject.metadataJSON)
        if !FileManager.default.fileExists(atPath: checkoutPath) {
            warnings.append("Checkout path does not exist on disk.")
        }

        return SessionDeletionProjectPreview(
            project: project,
            sessionProject: sessionProject,
            warnings: uniqueWarnings(warnings)
        )
    }

    private func metadataWarnings(from metadataJSON: String?) -> [String] {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return []
        }

        var warnings: [String] = []
        if let warning = dictionary["warning"] as? String, !warning.isEmpty {
            warnings.append(warning)
        }

        for (key, value) in dictionary where key != "warning" {
            guard let stringValue = value as? String, !stringValue.isEmpty else { continue }
            warnings.append("\(key): \(stringValue)")
        }
        return warnings
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for warning in warnings {
            let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func removeGlobalSessionSnapshotIfNeeded(sessionRawID: Int64) {
        let snapshot = ShuttleSessionSnapshotStore.load(paths: paths)
        let matchesSelectedSession = snapshot?.selectedSessionID == sessionRawID
            || snapshot?.selectedSession?.bundle.session.rawID == sessionRawID
        guard matchesSelectedSession else { return }
        ShuttleSessionSnapshotStore.remove(paths: paths)
    }

    private func removeSessionSnapshotIfNeeded(removedWorkspaceIDs: Set<Int64>, removedSessionIDs: Set<Int64>) {
        guard !removedWorkspaceIDs.isEmpty || !removedSessionIDs.isEmpty else { return }
        guard let snapshot = ShuttleSessionSnapshotStore.load(paths: paths) else { return }

        let selectedWorkspaceID = snapshot.selectedWorkspaceID ?? snapshot.selectedSession?.bundle.workspace.rawID
        if let selectedWorkspaceID, removedWorkspaceIDs.contains(selectedWorkspaceID) {
            ShuttleSessionSnapshotStore.remove(paths: paths)
            return
        }

        let selectedSessionID = snapshot.selectedSessionID ?? snapshot.selectedSession?.bundle.session.rawID
        guard let selectedSessionID, removedSessionIDs.contains(selectedSessionID) else { return }
        ShuttleSessionSnapshotStore.remove(paths: paths)
    }

    private func removePersistentArtifacts(for tabRawIDs: [Int64]) {
        let fileManager = FileManager.default
        for tabRawID in tabRawIDs {
            let scrollbackFile = ShuttleScrollbackReplayStore.snapshotFileURL(forTabRawID: tabRawID, paths: paths)
            try? fileManager.removeItem(at: scrollbackFile)
        }
    }

    private func removeDirectoryRecursively(atPath path: String) -> String? {
        let fileManager = FileManager.default
        let standardizedPath = standardizedPath(path)
        guard fileManager.fileExists(atPath: standardizedPath) else { return nil }
        do {
            try fileManager.removeItem(atPath: standardizedPath)
            return nil
        } catch {
            return "Failed to remove session root at \(standardizedPath): \(error.localizedDescription)"
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func sanitizeSessionName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func defaultSessionName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "session-\(formatter.string(from: Date()))"
    }

    private func currentDatePrefix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
