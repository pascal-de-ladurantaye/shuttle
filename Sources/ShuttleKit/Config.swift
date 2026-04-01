import Foundation

private struct PartialShuttleConfig: Decodable {
    var sessionRoot: String?
    var triesRoot: String?
    var projectRoots: [String]?
    var ignoredPaths: [String]?

    enum CodingKeys: String, CodingKey {
        case sessionRoot = "session_root"
        case triesRoot = "tries_root"
        case projectRoots = "project_roots"
        case ignoredPaths = "ignored_paths"
    }
}

public extension ShuttleConfig {
    var expandedSessionRoot: String {
        expandedPath(sessionRoot)
    }

    var expandedTriesRoot: String? {
        triesRoot.map(expandedPath)
    }

    var expandedProjectRoots: [String] {
        projectRoots.map(expandedPath)
    }
}

public struct ConfigManager: Sendable {
    public let paths: ShuttlePaths

    public init(paths: ShuttlePaths = ShuttlePaths()) {
        self.paths = paths
    }

    public func ensureDefaultConfigExists() throws {
        try paths.ensureDirectories()
        guard !FileManager.default.fileExists(atPath: paths.configURL.path) else {
            return
        }

        try sampleConfigText().write(to: paths.configURL, atomically: true, encoding: .utf8)
    }

    public func load(overrideRoots: [String] = []) throws -> ShuttleConfig {
        try ensureDefaultConfigExists()

        var config = defaultConfig()

        if FileManager.default.fileExists(atPath: paths.configURL.path) {
            let data = try Data(contentsOf: paths.configURL)
            do {
                let parsed = try Self.decoder.decode(PartialShuttleConfig.self, from: data)
                config = ShuttleConfig(
                    sessionRoot: parsed.sessionRoot ?? config.sessionRoot,
                    triesRoot: parsed.triesRoot ?? config.triesRoot,
                    projectRoots: parsed.projectRoots ?? config.projectRoots,
                    ignoredPaths: parsed.ignoredPaths ?? config.ignoredPaths
                )
            } catch {
                throw ShuttleError.configInvalid(
                    "Invalid JSON config at \(paths.configURL.path): \(error.localizedDescription)"
                )
            }
        }

        if !overrideRoots.isEmpty {
            config.projectRoots = overrideRoots
        }

        config.projectRoots = Array(NSOrderedSet(array: config.projectRoots.map(expandedPath))) as? [String] ?? config.projectRoots.map(expandedPath)
        config.ignoredPaths = Array(NSOrderedSet(array: config.ignoredPaths)) as? [String] ?? config.ignoredPaths
        config.sessionRoot = expandedPath(config.sessionRoot)
        config.triesRoot = config.triesRoot.map(expandedPath)

        return config
    }

    public func sampleConfigText() -> String {
        let data = (try? Self.encoder.encode(defaultConfig())) ?? Data()
        let string = String(data: data, encoding: .utf8) ?? "{}"
        return string.hasSuffix("\n") ? string : string + "\n"
    }

    private func defaultConfig() -> ShuttleConfig {
        ShuttleConfig(
            sessionRoot: paths.profile.defaultSessionRoot,
            triesRoot: paths.profile.defaultTriesRoot,
            projectRoots: [paths.profile.defaultTriesRoot],
            ignoredPaths: ["**/.git", "**/.DS_Store", "**/node_modules", "**/.build", "**/build"]
        )
    }

    private static let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
