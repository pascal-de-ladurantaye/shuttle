import Foundation

public enum LayoutPresetOrigin: String, CaseIterable, Codable, Sendable {
    case builtIn = "built_in"
    case custom
}

public struct LayoutTabTemplate: Hashable, Codable, Sendable {
    public var title: String?
    public var command: String?

    public init(title: String? = nil, command: String? = nil) {
        self.title = title
        self.command = command
    }
}

public struct LayoutPaneTemplate: Hashable, Codable, Sendable {
    public var splitDirection: SplitDirection?
    public var ratio: Double?
    public var children: [LayoutPaneTemplate]
    public var tabs: [LayoutTabTemplate]

    public init(
        splitDirection: SplitDirection? = nil,
        ratio: Double? = nil,
        children: [LayoutPaneTemplate] = [],
        tabs: [LayoutTabTemplate] = [LayoutTabTemplate()]
    ) {
        self.splitDirection = splitDirection
        self.ratio = ratio
        self.children = children
        self.tabs = tabs
    }

    public var isLeaf: Bool {
        children.isEmpty
    }

    public var leafPaneCount: Int {
        if children.isEmpty {
            return 1
        }
        return children.reduce(0) { $0 + $1.leafPaneCount }
    }

    public var tabTemplateCount: Int {
        if children.isEmpty {
            return max(tabs.count, 1)
        }
        return children.reduce(0) { $0 + $1.tabTemplateCount }
    }

    public func normalized() -> LayoutPaneTemplate {
        if children.isEmpty {
            var leaf = self
            leaf.splitDirection = nil
            leaf.ratio = nil
            leaf.children = []
            leaf.tabs = tabs.isEmpty ? [LayoutTabTemplate()] : tabs.map { tab in
                LayoutTabTemplate(
                    title: normalizedString(tab.title),
                    command: normalizedString(tab.command)
                )
            }
            return leaf
        }

        let normalizedChildren = children.map { $0.normalized() }
        if normalizedChildren.count < 2 {
            return normalizedChildren.first ?? LayoutPaneTemplate()
        }

        return LayoutPaneTemplate(
            splitDirection: normalizedSplitDirection(splitDirection),
            ratio: normalizedRatio(ratio),
            children: normalizedChildren,
            tabs: []
        )
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedSplitDirection(_ direction: SplitDirection?) -> SplitDirection {
        switch direction {
        case .up, .down:
            return .down
        case .left, .right:
            return .right
        case .none:
            return .right
        }
    }

    private func normalizedRatio(_ ratio: Double?) -> Double {
        min(max(ratio ?? 0.5, 0.2), 0.8)
    }
}

public struct LayoutPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var origin: LayoutPresetOrigin
    public var root: LayoutPaneTemplate

    public init(
        id: String,
        name: String,
        description: String? = nil,
        origin: LayoutPresetOrigin = .custom,
        root: LayoutPaneTemplate
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.origin = origin
        self.root = root
    }

    public var isBuiltIn: Bool {
        origin == .builtIn
    }

    public var leafPaneCount: Int {
        root.normalized().leafPaneCount
    }

    public var tabTemplateCount: Int {
        root.normalized().tabTemplateCount
    }

    public var summary: String {
        "\(leafPaneCount) pane\(leafPaneCount == 1 ? "" : "s") • \(tabTemplateCount) tab template\(tabTemplateCount == 1 ? "" : "s")"
    }

    public func normalized() -> LayoutPreset {
        let normalizedDescription: String?
        if let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            normalizedDescription = trimmed
        } else {
            normalizedDescription = nil
        }

        return LayoutPreset(
            id: id,
            name: name,
            description: normalizedDescription,
            origin: origin,
            root: root.normalized()
        )
    }
}

public struct LayoutPresetStore: Sendable {
    public static let defaultPresetID = "single"
    public static let layoutsDirectoryName = "layouts"

    public let paths: ShuttlePaths

    public init(paths: ShuttlePaths = ShuttlePaths()) {
        self.paths = paths
    }

    public func listPresets() throws -> [LayoutPreset] {
        try paths.ensureDirectories()
        let builtIns = Self.builtInPresets
        let builtInIDs = Set(builtIns.map(\.id))
        let custom = try loadCustomPresets().filter { !builtInIDs.contains($0.id) }
        return builtIns + custom.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func preset(named token: String) throws -> LayoutPreset? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let presets = try listPresets()
        if let exactID = presets.first(where: { $0.id == trimmed }) {
            return exactID
        }
        if let exactName = presets.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exactName
        }
        return nil
    }

    public func saveCustomPreset(_ preset: LayoutPreset) throws {
        var normalized = preset.normalized()
        let normalizedID = slugify(normalized.id).nilIfEmpty ?? slugify(normalized.name).nilIfEmpty ?? "layout"
        normalized.id = normalizedID
        normalized.origin = .custom

        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: layoutsDirectoryURL(), withIntermediateDirectories: true)

        let url = layoutsDirectoryURL().appending(path: "\(normalizedID).json")
        let data = try Self.encoder.encode(normalized)
        try data.write(to: url, options: .atomic)
    }

    public func renameCustomPreset(_ preset: LayoutPreset, previousID: String) throws -> LayoutPreset {
        var normalized = preset.normalized()
        let trimmedName = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ShuttleError.invalidArguments("Layout name cannot be empty")
        }

        let existingIDs = Set(try listPresets().map(\.id)).subtracting([previousID])
        let nextID = uniqueName(
            base: slugify(trimmedName).nilIfEmpty ?? slugify(previousID).nilIfEmpty ?? "layout",
            existing: existingIDs
        )

        normalized.name = trimmedName
        normalized.id = nextID
        normalized.origin = .custom

        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: layoutsDirectoryURL(), withIntermediateDirectories: true)

        let newURL = layoutsDirectoryURL().appending(path: "\(nextID).json")
        let data = try Self.encoder.encode(normalized)
        try data.write(to: newURL, options: .atomic)

        let previousURL = layoutsDirectoryURL().appending(path: "\(slugify(previousID)).json")
        if previousURL.standardizedFileURL != newURL.standardizedFileURL,
           FileManager.default.fileExists(atPath: previousURL.path) {
            try FileManager.default.removeItem(at: previousURL)
        }

        return normalized
    }

    public func deleteCustomPreset(id: String) throws {
        let url = layoutsDirectoryURL().appending(path: "\(slugify(id)).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func layoutsDirectoryURL() -> URL {
        paths.appSupportURL.appending(path: Self.layoutsDirectoryName, directoryHint: .isDirectory)
    }

    private func loadCustomPresets() throws -> [LayoutPreset] {
        let directory = layoutsDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      var preset = try? Self.decoder.decode(LayoutPreset.self, from: data) else {
                    return nil
                }
                preset.origin = .custom
                return preset.normalized()
            }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    public static let builtInPresets: [LayoutPreset] = [
        LayoutPreset(
            id: "single",
            name: "Single",
            description: "One pane with a single starting shell in the session's default starting directory.",
            origin: .builtIn,
            root: LayoutPaneTemplate(tabs: [LayoutTabTemplate()])
        ).normalized(),
        LayoutPreset(
            id: "dev",
            name: "Dev",
            description: "Two side-by-side panes for a primary shell and a supporting shell.",
            origin: .builtIn,
            root: LayoutPaneTemplate(
                splitDirection: .right,
                ratio: 0.62,
                children: [
                    LayoutPaneTemplate(tabs: [LayoutTabTemplate()]),
                    LayoutPaneTemplate(tabs: [LayoutTabTemplate()]),
                ],
                tabs: []
            )
        ).normalized(),
        LayoutPreset(
            id: "agent",
            name: "Agent",
            description: "A larger primary pane with a smaller companion pane for support work.",
            origin: .builtIn,
            root: LayoutPaneTemplate(
                splitDirection: .right,
                ratio: 0.7,
                children: [
                    LayoutPaneTemplate(tabs: [LayoutTabTemplate()]),
                    LayoutPaneTemplate(tabs: [LayoutTabTemplate(title: "Support")]),
                ],
                tabs: []
            )
        ).normalized(),
    ]
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
