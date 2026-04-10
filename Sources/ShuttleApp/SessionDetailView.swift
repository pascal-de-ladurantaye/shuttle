import SwiftUI
import AppKit
import ShuttleKit

extension Notification.Name {
    static let shuttlePresentNewSession = Notification.Name("ShuttlePresentNewSession")
}

// MARK: - Detail View with Live Terminal

struct DetailView: View {
    @EnvironmentObject private var model: ShuttleAppModel

    var body: some View {
        if let bundle = model.sessionBundle {
            SessionDetailView(bundle: bundle)
                .id(bundle.session.rawID)
        } else if let workspace = model.selectedWorkspace {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label(workspace.workspace.name, systemImage: "rectangle.split.3x1")
                } description: {
                    Text("Select or create a session to start working.")
                }
                Button {
                    NotificationCenter.default.post(name: .shuttlePresentNewSession, object: nil)
                } label: {
                    Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Welcome to Shuttle",
                systemImage: "rectangle.split.3x1",
                description: Text("Select a workspace from the sidebar to get started.")
            )
        }
    }
}

// MARK: - Session Detail with Terminal Panes

struct SessionDetailView: View {
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

                Divider()
                    .frame(height: PaneTabBarMetrics.tabHeight * 0.6)
                    .opacity(0.4)

                Button {
                    Task { await model.createTab(inPaneRawID: pane.rawID, sourceTabRawID: activeTab.rawID) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: PaneTabBarMetrics.addButtonWidth, height: PaneTabBarMetrics.tabHeight)
                        .background(Color(nsColor: NSColor.controlBackgroundColor).opacity(isFocusedPane ? 0.62 : 0.42))
                        .clipShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous)
                                .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.18), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .shuttleHint("Create a new tab in this pane.")
                .accessibilityLabel("New tab")
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

