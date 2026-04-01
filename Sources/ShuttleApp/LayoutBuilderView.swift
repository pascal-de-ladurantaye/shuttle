import SwiftUI
import ShuttleKit

enum ShuttleLayoutBuilderWindow {
    static let id = "layout-builder"
}

private enum LayoutEditorSelection: Hashable {
    case layout
    case pane([Int])
    case tab([Int], Int)
}

private enum LayoutSplitChoice: String, CaseIterable, Identifiable {
    case sideBySide
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side by Side"
        case .stacked: return "Stacked"
        }
    }

    var direction: SplitDirection {
        switch self {
        case .sideBySide: return .right
        case .stacked: return .down
        }
    }

    static func from(_ direction: SplitDirection?) -> LayoutSplitChoice {
        switch direction {
        case .up, .down:
            return .stacked
        case .left, .right, .none:
            return .sideBySide
        }
    }
}

struct ShuttleLayoutBuilderView: View {
    @EnvironmentObject private var layouts: LayoutLibraryModel
    @State private var selection: LayoutEditorSelection = .layout

    var body: some View {
        NavigationSplitView {
            presetSidebar
        } detail: {
            if let preset = layouts.selectedPreset {
                HSplitView {
                    VSplitView {
                        LayoutPreviewCanvas(
                            root: preset.root,
                            selection: selection,
                            onSelectPane: { selection = .pane($0) },
                            onSelectTab: { selection = .tab($0, $1) }
                        )
                        .frame(minHeight: 300)

                        LayoutStructureOutline(
                            root: preset.root,
                            selection: selection,
                            onSelectLayout: { selection = .layout },
                            onSelectPane: { selection = .pane($0) },
                            onSelectTab: { selection = .tab($0, $1) }
                        )
                        .frame(minHeight: 220)
                    }
                    .frame(minWidth: 420)

                    LayoutInspectorView(
                        preset: preset,
                        selection: selection,
                        onSelect: { selection = $0 },
                        onDuplicatePreset: {
                            layouts.duplicateSelectedPreset()
                            selection = .layout
                        },
                        onRenamePreset: { newName in
                            layouts.renameSelectedPreset(to: newName)
                            selection = .layout
                        },
                        onUpdatePreset: { update in
                            layouts.updateSelectedPreset(update)
                        },
                        onUpdateRoot: { root, nextSelection in
                            layouts.updateSelectedPreset { preset in
                                preset.root = root.normalized()
                            }
                            selection = nextSelection ?? selection
                        }
                    )
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                }
            } else {
                ContentUnavailableView("No Layout Selected", systemImage: "square.grid.2x2")
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    layouts.createPreset()
                    selection = .layout
                } label: {
                    Label("New Layout", systemImage: "plus")
                }
                .shuttleHint("Create a new custom layout preset.")

                Button {
                    layouts.duplicateSelectedPreset()
                    selection = .layout
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .shuttleHint("Duplicate the selected layout preset.")
                .disabled(layouts.selectedPreset == nil)

                Button {
                    layouts.deleteSelectedPreset()
                    selection = .layout
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .shuttleHint("Delete the selected custom layout preset.")
                .disabled(layouts.selectedPreset?.isBuiltIn != false)
            }
        }
        .onChange(of: layouts.selectedPresetID) { _, _ in
            selection = .layout
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var presetSidebar: some View {
        List(selection: $layouts.selectedPresetID) {
            let builtIns = layouts.presets.filter(\.isBuiltIn)
            let custom = layouts.presets.filter { !$0.isBuiltIn }

            if !builtIns.isEmpty {
                Section("Built-In") {
                    ForEach(builtIns, id: \.id) { preset in
                        presetSidebarRow(preset)
                            .tag(Optional(preset.id))
                    }
                }
            }

            Section("Custom") {
                if custom.isEmpty {
                    Text("No custom layouts yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(custom, id: \.id) { preset in
                        presetSidebarRow(preset)
                            .tag(Optional(preset.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func presetSidebarRow(_ preset: LayoutPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preset.name)
                .fontWeight(.medium)
            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct LayoutStructureOutline: View {
    let root: LayoutPaneTemplate
    let selection: LayoutEditorSelection
    let onSelectLayout: () -> Void
    let onSelectPane: ([Int]) -> Void
    let onSelectTab: ([Int], Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                outlineRow(
                    title: "Layout",
                    subtitle: nil,
                    depth: 0,
                    isSelected: selection == .layout,
                    action: onSelectLayout
                )

                paneRows(root, path: [], depth: 1)
            }
            .padding(12)
        }
        .background(.background)
        .overlay(alignment: .topLeading) {
            Text("Structure")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
    }

    private func paneRows(_ pane: LayoutPaneTemplate, path: [Int], depth: Int) -> AnyView {
        let header = AnyView(
            outlineRow(
                title: pane.isLeaf ? "Pane" : "Split",
                subtitle: paneOutlineSubtitle(pane),
                depth: depth,
                isSelected: selection == .pane(path),
                action: { onSelectPane(path) }
            )
        )

        if pane.isLeaf {
            let tabs = pane.tabs.isEmpty ? [LayoutTabTemplate()] : pane.tabs
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    header
                    ForEach(Array(tabs.enumerated()), id: \.offset) { tab in
                        outlineRow(
                            title: "Tab \(tab.offset + 1)",
                            subtitle: tabOutlineSubtitle(tab.element),
                            depth: depth + 1,
                            isSelected: selection == .tab(path, tab.offset),
                            action: { onSelectTab(path, tab.offset) }
                        )
                    }
                }
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                header
                ForEach(Array(pane.children.enumerated()), id: \.offset) { child in
                    paneRows(child.element, path: path + [child.offset], depth: depth + 1)
                }
            }
        )
    }

    private func paneOutlineSubtitle(_ pane: LayoutPaneTemplate) -> String {
        if pane.isLeaf {
            let tabs = max(pane.tabs.count, 1)
            return "\(tabs) tab\(tabs == 1 ? "" : "s")"
        }
        return LayoutSplitChoice.from(pane.splitDirection).title
    }

    private func tabOutlineSubtitle(_ tab: LayoutTabTemplate) -> String {
        tab.title?.nilIfEmpty ?? tab.command?.nilIfEmpty ?? "Automatic"
    }

    private func outlineRow(
        title: String,
        subtitle: String?,
        depth: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .shuttleHint("Select \(title) in the structure outline.")
    }
}

private struct LayoutPreviewCanvas: View {
    let root: LayoutPaneTemplate
    let selection: LayoutEditorSelection
    let onSelectPane: ([Int]) -> Void
    let onSelectTab: ([Int], Int) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            paneView(root.normalized(), path: [])
                .padding(16)

            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        .background(.background)
    }

    private func paneView(_ pane: LayoutPaneTemplate, path: [Int]) -> AnyView {
        if pane.isLeaf {
            let tabs = pane.tabs.isEmpty ? [LayoutTabTemplate()] : pane.tabs
            return AnyView(
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Pane")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    FlowLayout(spacing: 8) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { tab in
                            let isSelectedTab = selection == .tab(path, tab.offset)
                            Button {
                                onSelectTab(path, tab.offset)
                            } label: {
                                Text(tabLabel(tab.element, index: tab.offset))
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelectedTab ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .shuttleHint("Select \(tabLabel(tab.element, index: tab.offset)) in the preview.")
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(leafBackground(path: path))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selection == .pane(path) ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selection == .pane(path) ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    onSelectPane(path)
                }
            )
        }

        let children = AnyView(
            Group {
                if LayoutSplitChoice.from(pane.splitDirection) == .sideBySide {
                    HStack(spacing: 10) {
                        ForEach(Array(pane.children.enumerated()), id: \.offset) { child in
                            paneView(child.element, path: path + [child.offset])
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(pane.children.enumerated()), id: \.offset) { child in
                            paneView(child.element, path: path + [child.offset])
                        }
                    }
                }
            }
        )

        return AnyView(
            children
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selection == .pane(path) ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                )
                .overlay(alignment: .topLeading) {
                    Text(LayoutSplitChoice.from(pane.splitDirection).title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture {
                    onSelectPane(path)
                }
        )
    }

    private func leafBackground(path: [Int]) -> Color {
        selection == .pane(path) ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)
    }

    private func tabLabel(_ tab: LayoutTabTemplate, index: Int) -> String {
        tab.title?.nilIfEmpty ?? tab.command?.nilIfEmpty ?? "Tab \(index + 1)"
    }
}

private struct LayoutInspectorView: View {
    let preset: LayoutPreset
    let selection: LayoutEditorSelection
    let onSelect: (LayoutEditorSelection) -> Void
    let onDuplicatePreset: () -> Void
    let onRenamePreset: (String) -> Void
    let onUpdatePreset: ((inout LayoutPreset) -> Void) -> Void
    let onUpdateRoot: (LayoutPaneTemplate, LayoutEditorSelection?) -> Void

    @State private var layoutNameDraft = ""
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField {
        case layoutName
    }

    private var selectedPanePath: [Int]? {
        switch selection {
        case .layout:
            return nil
        case .pane(let path):
            return path
        case .tab(let path, _):
            return path
        }
    }

    private var selectedTabIndex: Int? {
        switch selection {
        case .tab(_, let tabIndex):
            return tabIndex
        case .layout, .pane:
            return nil
        }
    }

    private var selectedPane: LayoutPaneTemplate? {
        selectedPanePath.flatMap { preset.root.normalized().pane(at: $0) }
    }

    private var selectedTab: LayoutTabTemplate? {
        guard let path = selectedPanePath, let tabIndex = selectedTabIndex else { return nil }
        return preset.root.normalized().tab(at: path, index: tabIndex)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if preset.isBuiltIn {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Built-in preset", systemImage: "lock")
                            .font(.headline)
                        Text("Duplicate this preset to customize it. Built-in layouts stay read-only so defaults remain stable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Duplicate to Edit") {
                            onDuplicatePreset()
                        }
                        .shuttleHint("Duplicate this built-in layout so you can customize it.")
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                switch selection {
                case .layout:
                    layoutSection
                case .pane(let path):
                    paneSection(path: path)
                case .tab(let path, let tabIndex):
                    tabSection(path: path, tabIndex: tabIndex)
                }
            }
            .padding(16)
        }
        .background(.bar)
        .onAppear {
            layoutNameDraft = preset.name
        }
        .onChange(of: preset.id) { _, _ in
            layoutNameDraft = preset.name
        }
        .onChange(of: preset.name) { _, newValue in
            if focusedField != .layoutName {
                layoutNameDraft = newValue
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .layoutName, newValue != .layoutName {
                commitLayoutNameIfNeeded()
            }
        }
    }

    private var layoutSection: some View {
        Group {
            Text("Layout")
                .font(.headline)

            TextField("Name", text: $layoutNameDraft)
                .focused($focusedField, equals: .layoutName)
                .onSubmit {
                    commitLayoutNameIfNeeded()
                }
                .disabled(preset.isBuiltIn)

            TextField(
                "Description",
                text: Binding(
                    get: { preset.description ?? "" },
                    set: { newValue in
                        onUpdatePreset { preset in
                            preset.description = newValue.nilIfEmpty
                        }
                    }
                ),
                axis: .vertical
            )
            .disabled(preset.isBuiltIn)

            LabeledContent("Summary") {
                Text(preset.summary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitLayoutNameIfNeeded() {
        guard !preset.isBuiltIn else {
            layoutNameDraft = preset.name
            return
        }

        let trimmed = layoutNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            layoutNameDraft = preset.name
            return
        }

        guard trimmed != preset.name else { return }
        onRenamePreset(trimmed)
    }

    @ViewBuilder
    private func paneSection(path: [Int]) -> some View {
        if let pane = selectedPane {
            Text("Pane")
                .font(.headline)

            if pane.isLeaf {
                Stepper(
                    value: Binding(
                        get: { max(pane.tabs.count, 1) },
                        set: { newValue in
                            let nextRoot = preset.root.normalized().settingTabCount(at: path, count: newValue)
                            onUpdateRoot(nextRoot, .pane(path))
                        }
                    ),
                    in: 1...6
                ) {
                    Text("Tabs: \(max(pane.tabs.count, 1))")
                }
                .disabled(preset.isBuiltIn)

                HStack {
                    Button("Split Side by Side") {
                        let nextRoot = preset.root.normalized().splittingPane(at: path, direction: .right)
                        onUpdateRoot(nextRoot, .pane(path))
                    }
                    .shuttleHint("Split this pane into left and right panes.")
                    .disabled(preset.isBuiltIn)

                    Button("Split Stacked") {
                        let nextRoot = preset.root.normalized().splittingPane(at: path, direction: .down)
                        onUpdateRoot(nextRoot, .pane(path))
                    }
                    .shuttleHint("Split this pane into top and bottom panes.")
                    .disabled(preset.isBuiltIn)
                }
            } else {
                Picker(
                    "Split",
                    selection: Binding(
                        get: { LayoutSplitChoice.from(pane.splitDirection) },
                        set: { newValue in
                            let nextRoot = preset.root.normalized().updatedPane(at: path) { pane in
                                pane.splitDirection = newValue.direction
                            }
                            onUpdateRoot(nextRoot, .pane(path))
                        }
                    )
                ) {
                    ForEach(LayoutSplitChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .disabled(preset.isBuiltIn)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Split ratio")
                        .font(.subheadline.weight(.medium))
                    Slider(
                        value: Binding(
                            get: { pane.ratio ?? 0.5 },
                            set: { newValue in
                                let nextRoot = preset.root.normalized().updatedPane(at: path) { pane in
                                    pane.ratio = newValue
                                }
                                onUpdateRoot(nextRoot, .pane(path))
                            }
                        ),
                        in: 0.2...0.8
                    )
                    .disabled(preset.isBuiltIn)
                    Text("\(Int((pane.ratio ?? 0.5) * 100))% / \(Int((1 - (pane.ratio ?? 0.5)) * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Flatten Split") {
                    let nextRoot = preset.root.normalized().flatteningPane(at: path)
                    onUpdateRoot(nextRoot, .pane(path))
                }
                .shuttleHint("Remove this split and merge its contents into a single pane.")
                .disabled(preset.isBuiltIn)
            }

            if !path.isEmpty {
                Divider()
                Button("Delete Pane", role: .destructive) {
                    let nextRoot = preset.root.normalized().removingPane(at: path)
                    onUpdateRoot(nextRoot, .layout)
                    onSelect(.layout)
                }
                .shuttleHint("Delete this pane from the layout.")
                .disabled(preset.isBuiltIn)
            }
        }
    }

    @ViewBuilder
    private func tabSection(path: [Int], tabIndex: Int) -> some View {
        if let tab = selectedTab, let pane = selectedPane {
            Text("Tab")
                .font(.headline)

            TextField(
                "Title",
                text: Binding(
                    get: { tab.title ?? "" },
                    set: { newValue in
                        let nextRoot = preset.root.normalized().updatedTab(at: path, index: tabIndex) { tab in
                            tab.title = newValue.nilIfEmpty
                        }
                        onUpdateRoot(nextRoot, .tab(path, tabIndex))
                    }
                )
            )
            .disabled(preset.isBuiltIn)

            TextField(
                "Startup command",
                text: Binding(
                    get: { tab.command ?? "" },
                    set: { newValue in
                        let nextRoot = preset.root.normalized().updatedTab(at: path, index: tabIndex) { tab in
                            tab.command = newValue.nilIfEmpty
                        }
                        onUpdateRoot(nextRoot, .tab(path, tabIndex))
                    }
                ),
                axis: .vertical
            )
            .shuttleHint("Sent to the shell after the tab launches. The shell stays open after the command exits.")
            .disabled(preset.isBuiltIn)

            if max(pane.tabs.count, 1) > 1 {
                Divider()
                Button("Delete Tab", role: .destructive) {
                    let nextRoot = preset.root.normalized().removingTab(at: path, index: tabIndex)
                    onUpdateRoot(nextRoot, .pane(path))
                    onSelect(.pane(path))
                }
                .shuttleHint("Delete this tab from the selected pane.")
                .disabled(preset.isBuiltIn)
            }
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
            Spacer(minLength: 0)
        }
    }
}

private extension LayoutPaneTemplate {
    func pane(at path: [Int]) -> LayoutPaneTemplate? {
        guard let first = path.first else { return self }
        guard children.indices.contains(first) else { return nil }
        return children[first].pane(at: Array(path.dropFirst()))
    }

    func tab(at path: [Int], index: Int) -> LayoutTabTemplate? {
        pane(at: path)?.tabs[safe: index]
    }

    func updatedPane(at path: [Int], update: (inout LayoutPaneTemplate) -> Void) -> LayoutPaneTemplate {
        guard let first = path.first else {
            var copy = self
            update(&copy)
            return copy.normalized()
        }
        guard children.indices.contains(first) else { return self }
        var copy = self
        copy.children[first] = copy.children[first].updatedPane(at: Array(path.dropFirst()), update: update)
        return copy.normalized()
    }

    func updatedTab(at path: [Int], index: Int, update: (inout LayoutTabTemplate) -> Void) -> LayoutPaneTemplate {
        updatedPane(at: path) { pane in
            var tabs = pane.tabs.isEmpty ? [LayoutTabTemplate()] : pane.tabs
            guard tabs.indices.contains(index) else { return }
            update(&tabs[index])
            pane.tabs = tabs
        }
    }

    func settingTabCount(at path: [Int], count: Int) -> LayoutPaneTemplate {
        updatedPane(at: path) { pane in
            guard pane.isLeaf else { return }
            var tabs = pane.tabs.isEmpty ? [LayoutTabTemplate()] : pane.tabs
            if count > tabs.count {
                tabs.append(contentsOf: Array(repeating: LayoutTabTemplate(), count: count - tabs.count))
            } else {
                tabs = Array(tabs.prefix(max(count, 1)))
            }
            pane.tabs = tabs
        }
    }

    func splittingPane(at path: [Int], direction: SplitDirection) -> LayoutPaneTemplate {
        updatedPane(at: path) { pane in
            let baseTabs = pane.firstLeafTabs
            pane = LayoutPaneTemplate(
                splitDirection: direction,
                ratio: 0.5,
                children: [
                    LayoutPaneTemplate(tabs: baseTabs),
                    LayoutPaneTemplate(tabs: [baseTabs.first ?? LayoutTabTemplate()]),
                ],
                tabs: []
            )
        }
    }

    func flatteningPane(at path: [Int]) -> LayoutPaneTemplate {
        updatedPane(at: path) { pane in
            pane = LayoutPaneTemplate(tabs: pane.firstLeafTabs)
        }
    }

    func removingPane(at path: [Int]) -> LayoutPaneTemplate {
        guard let first = path.first else { return self }
        guard children.indices.contains(first) else { return self }

        var copy = self
        if path.count == 1 {
            copy.children.remove(at: first)
        } else {
            copy.children[first] = copy.children[first].removingPane(at: Array(path.dropFirst()))
        }
        return copy.normalized()
    }

    func removingTab(at path: [Int], index: Int) -> LayoutPaneTemplate {
        updatedPane(at: path) { pane in
            var tabs = pane.tabs.isEmpty ? [LayoutTabTemplate()] : pane.tabs
            guard tabs.indices.contains(index), tabs.count > 1 else { return }
            tabs.remove(at: index)
            pane.tabs = tabs
        }
    }

    var firstLeafTabs: [LayoutTabTemplate] {
        if isLeaf {
            return tabs.isEmpty ? [LayoutTabTemplate()] : tabs
        }
        return children.first?.firstLeafTabs ?? [LayoutTabTemplate()]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
