import SwiftUI
import AppKit
import ShuttleKit

struct ContentView: View {
    @Binding var isSidebarVisible: Bool
    @Binding var isCommandPalettePresented: Bool
    @EnvironmentObject private var model: ShuttleAppModel
    @EnvironmentObject private var layoutLibrary: LayoutLibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
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

    /// Sidebar background using dynamic NSColor that adapts to light/dark.
    private var sidebarBackground: Color {
        chromePalette.sidebarBackgroundBase
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { isSidebarVisible ? .all : .detailOnly },
            set: { newValue in isSidebarVisible = newValue != .detailOnly }
        )) {
            combinedSidebar
        } detail: {
            DetailView()
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
        .toolbar {
            toolbarContent
        }
        .overlay(alignment: .topTrailing) {
            toastOverlay
        }
        .overlay {
            CommandPaletteOverlay(
                isPresented: $isCommandPalettePresented,
                presentSheet: { sheet in presentedSheet = sheet },
                openLayoutBuilder: { openWindow(id: ShuttleLayoutBuilderWindow.id) },
                toggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarVisible.toggle()
                    }
                }
            )
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
        .onReceive(NotificationCenter.default.publisher(for: .shuttlePresentNewSession)) { _ in
            presentedSheet = .newSession
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
        .background(sidebarBackground)
        .navigationSplitViewColumnWidth(
            min: SidebarLayout.combinedMinWidth,
            ideal: SidebarLayout.combinedIdealWidth,
            max: SidebarLayout.combinedMaxWidth
        )
    }

    private var workspaceSidebarColumn: some View {
        VStack(spacing: 0) {
            if model.workspaces.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No Workspaces Yet",
                        systemImage: "square.stack.3d.up",
                        description: Text("Scan your configured project roots to discover workspaces.")
                    )
                    Button {
                        Task { await model.scanProjects() }
                    } label: {
                        Label("Scan Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isScanningProjects)
                }
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
                } else {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            normalizedSessionSearchText.isEmpty ? "No Sessions Yet" : "No Matching Sessions or Projects",
                            systemImage: normalizedSessionSearchText.isEmpty ? "terminal" : "magnifyingglass"
                        )
                        if normalizedSessionSearchText.isEmpty {
                            Button {
                                presentedSheet = .newSession
                            } label: {
                                Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("No Workspace Selected", systemImage: "square.stack.3d.up")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let totalSessions = details.sessions.count
        let activeSessions = details.sessions.filter { $0.status == .active }.count
        let sessionLabel = "\(totalSessions) session\(totalSessions == 1 ? "" : "s")"

        if details.workspace.createdFrom == .global {
            return activeSessions > 0
                ? "\(sessionLabel) • \(activeSessions) active • opens in ~"
                : "\(sessionLabel) • opens in ~"
        }
        return activeSessions > 0
            ? "\(sessionLabel) • \(activeSessions) active"
            : sessionLabel
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
                Text(workspace.workspace.name)
                    .font(.headline)
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
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity).animation(.spring(response: 0.35, dampingFraction: 0.8)),
                            removal: .move(edge: .top).combined(with: .opacity).animation(.easeIn(duration: 0.15))
                        )
                    )
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notifications")
        }
    }
}

