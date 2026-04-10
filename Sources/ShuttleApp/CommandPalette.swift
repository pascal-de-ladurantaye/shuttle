import SwiftUI
import AppKit
import ShuttleKit

// MARK: - Action Registry

/// Every static action that Shuttle exposes through menus and the command palette.
///
/// Adding a new case here is a compiler error until you:
///   1. Add its `ShuttleActionDescriptor` in the `descriptors` dictionary.
///   2. Handle it in `ShuttleAppModel.buildPaletteCommands` for closure + enabled state.
///   3. Reference `ShuttleActionDescriptor[.yourCase]` in the matching `Commands` struct.
///
/// Dynamic entries (workspace/session navigation) are appended separately and
/// don't live in this enum.
enum ShuttleActionID: String, CaseIterable {
    // Session
    case sessionNew
    case sessionNewTry
    case sessionRename
    case sessionClose
    case sessionDelete

    // Pane
    case paneSplitVertical
    case paneSplitHorizontal
    case paneFocusNext
    case paneFocusPrevious

    // Tab
    case tabNew
    case tabClose
    case tabNext
    case tabPrevious
    case tabSelect1, tabSelect2, tabSelect3, tabSelect4, tabSelect5
    case tabSelect6, tabSelect7, tabSelect8, tabSelect9

    // View
    case viewToggleSidebar
    case viewCloseWindow
    case viewCommandPalette

    // Tools
    case toolsScanProjects
    case toolsLayoutBuilder
}

/// Static metadata for an action: label, icon, shortcut.
/// Closures and enabled-state are computed at runtime by the model.
struct ShuttleActionDescriptor {
    let id: ShuttleActionID
    let category: String
    let label: String
    let icon: String
    let shortcut: ShuttleShortcutDescriptor?

    /// SwiftUI `KeyboardShortcut` derived from the descriptor, if any.
    /// Used by `Commands` structs so menu items stay in sync.
    var keyboardShortcut: KeyboardShortcut? {
        guard let shortcut else { return nil }
        let key = KeyEquivalent(Character(shortcut.key.lowercased()))
        return KeyboardShortcut(key, modifiers: shortcut.modifiers)
    }
}

/// Describes a keyboard shortcut for display in the palette.
/// Separate from SwiftUI's `KeyboardShortcut` so we can render glyphs
/// without needing an actual shortcut binding.
struct ShuttleShortcutDescriptor: Equatable {
    let key: String
    let modifiers: EventModifiers

    /// Human-readable glyph string like "⇧⌘D".
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

// MARK: Descriptor Table

/// Single source of truth for every static action's metadata.
/// Menu bar `Commands` and the command palette both read from here.
extension ShuttleActionDescriptor {
    /// Look up a descriptor by action ID.
    static subscript(_ id: ShuttleActionID) -> ShuttleActionDescriptor {
        guard let descriptor = all[id] else {
            fatalError("Missing ShuttleActionDescriptor for \(id). Add it to ShuttleActionDescriptor.all.")
        }
        return descriptor
    }

    // swiftlint:disable function_body_length
    static let all: [ShuttleActionID: ShuttleActionDescriptor] = {
        var d: [ShuttleActionID: ShuttleActionDescriptor] = [:]

        func add(_ id: ShuttleActionID, category: String, label: String, icon: String, shortcut: ShuttleShortcutDescriptor? = nil) {
            d[id] = ShuttleActionDescriptor(id: id, category: category, label: label, icon: icon, shortcut: shortcut)
        }

        // Session
        add(.sessionNew,       category: "Session", label: "New Session…",       icon: "plus.rectangle.on.rectangle")
        add(.sessionNewTry,    category: "Session", label: "New Try Session…",   icon: "sparkles")
        add(.sessionRename,    category: "Session", label: "Rename Session…",    icon: "pencil")
        add(.sessionClose,     category: "Session", label: "Close Session",      icon: "xmark.circle")
        add(.sessionDelete,    category: "Session", label: "Delete Session…",    icon: "trash")

        // Pane
        add(.paneSplitVertical,   category: "Pane", label: "Split Vertically",     icon: "rectangle.split.1x2",
            shortcut: ShuttleShortcutDescriptor(key: "D", modifiers: .command))
        add(.paneSplitHorizontal, category: "Pane", label: "Split Horizontally",   icon: "rectangle.split.2x1",
            shortcut: ShuttleShortcutDescriptor(key: "D", modifiers: [.command, .shift]))
        add(.paneFocusNext,       category: "Pane", label: "Focus Next Pane",      icon: "arrow.right.square",
            shortcut: ShuttleShortcutDescriptor(key: "]", modifiers: [.command, .option]))
        add(.paneFocusPrevious,   category: "Pane", label: "Focus Previous Pane",  icon: "arrow.left.square",
            shortcut: ShuttleShortcutDescriptor(key: "[", modifiers: [.command, .option]))

        // Tab
        add(.tabNew,      category: "Tab", label: "New Tab",             icon: "plus",
            shortcut: ShuttleShortcutDescriptor(key: "T", modifiers: .command))
        add(.tabClose,    category: "Tab", label: "Close Tab",           icon: "xmark",
            shortcut: ShuttleShortcutDescriptor(key: "W", modifiers: .command))
        add(.tabNext,     category: "Tab", label: "Select Next Tab",     icon: "arrow.right",
            shortcut: ShuttleShortcutDescriptor(key: "]", modifiers: [.command, .shift]))
        add(.tabPrevious, category: "Tab", label: "Select Previous Tab", icon: "arrow.left",
            shortcut: ShuttleShortcutDescriptor(key: "[", modifiers: [.command, .shift]))

        for i in 1...9 {
            let id: ShuttleActionID = [
                .tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5,
                .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9
            ][i - 1]
            add(id, category: "Tab", label: "Select Tab \(i)", icon: "number",
                shortcut: ShuttleShortcutDescriptor(key: "\(i)", modifiers: .command))
        }

        // View
        add(.viewToggleSidebar,   category: "View", label: "Toggle Sidebar",    icon: "sidebar.leading",
            shortcut: ShuttleShortcutDescriptor(key: "S", modifiers: [.command, .control]))
        add(.viewCloseWindow,     category: "View", label: "Close Window",      icon: "xmark.rectangle",
            shortcut: ShuttleShortcutDescriptor(key: "W", modifiers: [.command, .shift]))
        add(.viewCommandPalette,  category: "View", label: "Command Palette",   icon: "command",
            shortcut: ShuttleShortcutDescriptor(key: "P", modifiers: [.command, .shift]))

        // Tools
        add(.toolsScanProjects,   category: "Tools", label: "Scan Projects",    icon: "arrow.clockwise")
        add(.toolsLayoutBuilder,  category: "Tools", label: "Layout Builder…",  icon: "square.grid.2x2")

        // Verify completeness at init time (debug builds).
        assert(d.count == ShuttleActionID.allCases.count,
               "ShuttleActionDescriptor.all is missing entries. Have \(d.count), need \(ShuttleActionID.allCases.count).")

        return d
    }()
    // swiftlint:enable function_body_length
}

// MARK: - Runtime Command (palette entry)

/// A single entry in the command palette, combining a descriptor with
/// runtime enabled-state and an action closure.
struct ShuttleCommand: Identifiable {
    let id: String
    let descriptor: ShuttleActionDescriptor?
    let category: String
    let label: String
    let icon: String
    let shortcut: ShuttleShortcutDescriptor?
    let isEnabled: Bool
    let children: [ShuttleCommand]?
    let action: () -> Void

    /// Build from a registered action descriptor.
    init(
        _ actionID: ShuttleActionID,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        let desc = ShuttleActionDescriptor[actionID]
        self.id = actionID.rawValue
        self.descriptor = desc
        self.category = desc.category
        self.label = desc.label
        self.icon = desc.icon
        self.shortcut = desc.shortcut
        self.isEnabled = isEnabled
        self.children = nil
        self.action = action
    }

    /// Build a dynamic or drill-down entry not backed by the enum.
    init(
        id: String,
        category: String,
        label: String,
        icon: String,
        shortcut: ShuttleShortcutDescriptor? = nil,
        isEnabled: Bool = true,
        children: [ShuttleCommand]? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.id = id
        self.descriptor = nil
        self.category = category
        self.label = label
        self.icon = icon
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.children = children
        self.action = action
    }

    var hasChildren: Bool { children != nil && !(children?.isEmpty ?? true) }
}

// MARK: - Command Builder

extension ShuttleAppModel {
    /// Builds the full command list for the palette.
    /// Closures capture `[weak self]` and read model state at invocation time.
    @MainActor
    func buildPaletteCommands(
        presentSheet: @escaping (ShuttleSheet) -> Void,
        openLayoutBuilder: @escaping () -> Void,
        toggleSidebar: @escaping () -> Void
    ) -> [ShuttleCommand] {
        var commands: [ShuttleCommand] = []

        let hasWorkspace = selectedWorkspace != nil
        let hasSession = sessionBundle != nil

        // Session
        commands.append(ShuttleCommand(.sessionNew, isEnabled: hasWorkspace) {
            presentSheet(.newSession)
        })
        commands.append(ShuttleCommand(.sessionNewTry) {
            presentSheet(.newTry)
        })
        if let bundle = sessionBundle {
            commands.append(ShuttleCommand(.sessionRename, isEnabled: hasSession) {
                presentSheet(.renameSession(bundle.session.rawID))
            })
            commands.append(ShuttleCommand(.sessionClose, isEnabled: bundle.session.status == .active) { [weak self] in
                Task { try? await self?.closeSession(sessionRawID: bundle.session.rawID) }
            })
            commands.append(ShuttleCommand(.sessionDelete, isEnabled: hasSession) {
                presentSheet(.deleteSession(bundle.session.rawID))
            })
        }

        // Pane
        commands.append(ShuttleCommand(.paneSplitVertical, isEnabled: canSplitFocusedPane) { [weak self] in
            Task { await self?.splitFocusedPane(direction: .right) }
        })
        commands.append(ShuttleCommand(.paneSplitHorizontal, isEnabled: canSplitFocusedPane) { [weak self] in
            Task { await self?.splitFocusedPane(direction: .down) }
        })
        commands.append(ShuttleCommand(.paneFocusNext, isEnabled: hasMultiplePanes) { [weak self] in
            self?.focusNextPane()
        })
        commands.append(ShuttleCommand(.paneFocusPrevious, isEnabled: hasMultiplePanes) { [weak self] in
            self?.focusPreviousPane()
        })

        // Tab
        commands.append(ShuttleCommand(.tabNew, isEnabled: canCreateTabInFocusedPane) { [weak self] in
            Task { await self?.createTabInFocusedPane() }
        })
        commands.append(ShuttleCommand(.tabClose, isEnabled: canCloseFocusedTab) { [weak self] in
            Task { await self?.closeFocusedTab() }
        })
        commands.append(ShuttleCommand(.tabNext, isEnabled: hasMultipleTabsInFocusedPane) { [weak self] in
            self?.selectNextTab()
        })
        commands.append(ShuttleCommand(.tabPrevious, isEnabled: hasMultipleTabsInFocusedPane) { [weak self] in
            self?.selectPreviousTab()
        })

        // View
        commands.append(ShuttleCommand(.viewToggleSidebar, action: toggleSidebar))
        commands.append(ShuttleCommand(.viewCloseWindow) {
            _ = NSApplication.shared.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
        })

        // Tools
        commands.append(ShuttleCommand(.toolsScanProjects, isEnabled: !isScanningProjects) { [weak self] in
            Task { await self?.scanProjects() }
        })
        commands.append(ShuttleCommand(.toolsLayoutBuilder, action: openLayoutBuilder))

        // Navigation — Workspaces (2-level)
        let workspaceChildren = workspaces.map { details -> ShuttleCommand in
            let isSelected = selectedWorkspace?.workspace.rawID == details.workspace.rawID
            return ShuttleCommand(
                id: "nav-workspace-\(details.workspace.rawID)",
                category: "Navigation",
                label: details.workspace.name,
                icon: details.workspace.createdFrom == .global ? "house" : "folder",
                isEnabled: !isSelected,
                action: { [weak self] in Task { await self?.selectWorkspace(details.workspace.rawID) } }
            )
        }
        commands.append(ShuttleCommand(
            id: "nav-workspace",
            category: "Navigation",
            label: "Switch to Workspace",
            icon: "square.stack.3d.up",
            isEnabled: !workspaces.isEmpty,
            children: workspaceChildren
        ))

        // Navigation — Sessions (2-level)
        if let workspace = selectedWorkspace, !workspace.sessions.isEmpty {
            let sessionChildren = workspace.sessions.map { session -> ShuttleCommand in
                let isSelected = selectedSessionID == session.rawID
                let statusIcon: String = {
                    switch session.status {
                    case .active: return "terminal"
                    case .restorable: return "arrow.clockwise.circle"
                    case .closed: return "clock"
                    }
                }()
                return ShuttleCommand(
                    id: "nav-session-\(session.rawID)",
                    category: "Navigation",
                    label: session.name,
                    icon: statusIcon,
                    isEnabled: !isSelected,
                    action: { [weak self] in Task { await self?.selectSession(session.rawID) } }
                )
            }
            commands.append(ShuttleCommand(
                id: "nav-session",
                category: "Navigation",
                label: "Switch to Session",
                icon: "terminal",
                isEnabled: !workspace.sessions.isEmpty,
                children: sessionChildren
            ))
        }

        return commands
    }
}

// MARK: - Fuzzy Match

func fuzzyMatch(query: String, target: String) -> (matches: Bool, score: Int, ranges: [Range<String.Index>]) {
    guard !query.isEmpty else { return (true, 0, []) }

    let queryChars = Array(query.lowercased())
    let targetLower = target.lowercased()
    var queryIndex = 0
    var ranges: [Range<String.Index>] = []
    var score = 0
    var lastMatchTargetIndex: String.Index?

    for targetCharIndex in targetLower.indices {
        guard queryIndex < queryChars.count else { break }
        if targetLower[targetCharIndex] == queryChars[queryIndex] {
            if let last = lastMatchTargetIndex,
               targetLower.index(after: last) == targetCharIndex {
                score += 2
            }
            if targetCharIndex == targetLower.startIndex {
                score += 3
            } else {
                let prev = targetLower.index(before: targetCharIndex)
                let prevChar = targetLower[prev]
                if prevChar == " " || prevChar == "-" || prevChar == "/" || prevChar == "." {
                    score += 3
                }
            }
            score += 1

            let end = targetLower.index(after: targetCharIndex)
            if let lastRange = ranges.last, lastRange.upperBound == targetCharIndex {
                ranges[ranges.count - 1] = lastRange.lowerBound..<end
            } else {
                ranges.append(targetCharIndex..<end)
            }
            lastMatchTargetIndex = targetCharIndex
            queryIndex += 1
        }
    }

    let matched = queryIndex == queryChars.count
    return (matched, matched ? score : 0, matched ? ranges : [])
}

// MARK: - Palette View

struct CommandPaletteView: View {
    @EnvironmentObject private var model: ShuttleAppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool

    let presentSheet: (ShuttleSheet) -> Void
    let openLayoutBuilder: () -> Void
    let toggleSidebar: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var drillDownParent: ShuttleCommand?
    @FocusState private var isSearchFieldFocused: Bool

    private var commands: [ShuttleCommand] {
        if let parent = drillDownParent {
            return parent.children ?? []
        }
        return model.buildPaletteCommands(
            presentSheet: presentSheet,
            openLayoutBuilder: openLayoutBuilder,
            toggleSidebar: toggleSidebar
        )
    }

    private var filteredCommands: [ShuttleCommand] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }

        return commands
            .compactMap { command -> (command: ShuttleCommand, score: Int)? in
                let (matches, score, _) = fuzzyMatch(query: query, target: command.label)
                guard matches else { return nil }
                return (command, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.command)
    }

    private var breadcrumb: String? {
        drillDownParent?.label
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let breadcrumb {
                    Button {
                        popDrillDown()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.semibold))
                            Text(breadcrumb)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to \(breadcrumb)")

                    Divider()
                        .frame(height: 16)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }

                TextField(
                    breadcrumb != nil ? "Filter…" : "Type a command…",
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFieldFocused)
                .onSubmit { executeSelected() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                ShortcutGlyphView(descriptor: ShuttleActionDescriptor[.viewCommandPalette].shortcut!)
                    .opacity(0.6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if filteredCommands.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No matching commands")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding()
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                CommandPaletteRow(
                                    command: command,
                                    isHighlighted: index == selectedIndex,
                                    searchQuery: searchText,
                                    onSelect: { execute(command) }
                                )
                                .id(command.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selectedIndex) { _, newValue in
                        guard filteredCommands.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            scrollProxy.scrollTo(filteredCommands[newValue].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 16) {
                paletteHintLabel("↑↓", text: "Navigate")
                paletteHintLabel("↩", text: "Execute")
                if drillDownParent != nil {
                    paletteHintLabel("⌫", text: "Back")
                }
                paletteHintLabel("esc", text: "Close")
                Spacer()
                Text("\(filteredCommands.count) command\(filteredCommands.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 520)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: ShuttleCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.large, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.2), radius: 40, y: 10)
        .onAppear {
            selectedIndex = 0
            searchText = ""
            drillDownParent = nil
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            if drillDownParent != nil {
                popDrillDown()
            } else {
                isPresented = false
            }
            return .handled
        }
        .onKeyPress(.delete) {
            if searchText.isEmpty && drillDownParent != nil {
                popDrillDown()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.tab) {
            let cmds = filteredCommands
            guard cmds.indices.contains(selectedIndex) else { return .ignored }
            let command = cmds[selectedIndex]
            if command.hasChildren {
                pushDrillDown(command)
                return .handled
            }
            return .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
    }

    private func moveSelection(by delta: Int) {
        let count = filteredCommands.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func executeSelected() {
        let cmds = filteredCommands
        guard cmds.indices.contains(selectedIndex) else { return }
        execute(cmds[selectedIndex])
    }

    private func execute(_ command: ShuttleCommand) {
        if command.hasChildren {
            pushDrillDown(command)
            return
        }
        guard command.isEnabled else { return }
        isPresented = false
        DispatchQueue.main.async {
            command.action()
        }
    }

    private func pushDrillDown(_ command: ShuttleCommand) {
        drillDownParent = command
        searchText = ""
        selectedIndex = 0
    }

    private func popDrillDown() {
        drillDownParent = nil
        searchText = ""
        selectedIndex = 0
    }

    private func paletteHintLabel(_ glyph: String, text: String) -> some View {
        HStack(spacing: 4) {
            Text(glyph)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Row

private struct CommandPaletteRow: View {
    let command: ShuttleCommand
    let isHighlighted: Bool
    let searchQuery: String
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(command.isEnabled ? .secondary : .tertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    highlightedLabel
                        .font(.system(size: 13))
                        .foregroundStyle(command.isEnabled ? .primary : .tertiary)
                        .lineLimit(1)

                    if !command.category.isEmpty {
                        Text(command.category)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                if command.hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if let shortcut = command.shortcut {
                    ShortcutGlyphView(descriptor: shortcut)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.15) : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.label)
        .accessibilityValue(command.shortcut?.displayString ?? "")
        .accessibilityHint(command.isEnabled ? "" : "Currently unavailable")
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }

    private var highlightedLabel: Text {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(command.label) }

        let (matches, _, ranges) = fuzzyMatch(query: query, target: command.label)
        guard matches, !ranges.isEmpty else { return Text(command.label) }

        var result = Text("")
        var currentIndex = command.label.startIndex

        for range in ranges {
            if currentIndex < range.lowerBound {
                result = result + Text(command.label[currentIndex..<range.lowerBound])
            }
            result = result + Text(command.label[range]).bold()
            currentIndex = range.upperBound
        }

        if currentIndex < command.label.endIndex {
            result = result + Text(command.label[currentIndex..<command.label.endIndex])
        }

        return result
    }
}

// MARK: - Shortcut Glyph

struct ShortcutGlyphView: View {
    let descriptor: ShuttleShortcutDescriptor

    var body: some View {
        Text(descriptor.displayString)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            }
    }
}

// MARK: - Backdrop

struct CommandPaletteOverlay: View {
    @Binding var isPresented: Bool
    let presentSheet: (ShuttleSheet) -> Void
    let openLayoutBuilder: () -> Void
    let toggleSidebar: () -> Void

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false
                    }
                    .accessibilityHidden(true)

                VStack {
                    CommandPaletteView(
                        isPresented: $isPresented,
                        presentSheet: presentSheet,
                        openLayoutBuilder: openLayoutBuilder,
                        toggleSidebar: toggleSidebar
                    )
                    .padding(.top, 80)

                    Spacer()
                }
            }
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
        }
    }
}
