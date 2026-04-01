import Foundation

/// Environment variables passed to every terminal spawned by Shuttle.
public struct TerminalEnvironmentContext: Hashable, Sendable, Codable {
    public var workspace: Workspace
    public var session: Session
    public var project: Project?
    public var pane: Pane
    public var tab: Tab
    public var socketPath: String?

    public init(workspace: Workspace, session: Session, project: Project?, pane: Pane, tab: Tab, socketPath: String?) {
        self.workspace = workspace
        self.session = session
        self.project = project
        self.pane = pane
        self.tab = tab
        self.socketPath = socketPath
    }

    public var environmentVariables: [String: String] {
        var result: [String: String] = [
            "SHUTTLE_WORKSPACE_ID": workspace.id,
            "SHUTTLE_WORKSPACE_NAME": workspace.name,
            "SHUTTLE_SESSION_ID": session.id,
            "SHUTTLE_SESSION_NAME": session.name,
            "SHUTTLE_PANE_ID": pane.id,
            "SHUTTLE_TAB_ID": tab.id,
            "SHUTTLE_SESSION_ROOT": session.sessionRootPath,
        ]

        if let project {
            result["SHUTTLE_PROJECT_ID"] = project.id
            result["SHUTTLE_PROJECT_NAME"] = project.name
            result["SHUTTLE_PROJECT_PATH"] = project.path
            result["SHUTTLE_PROJECT_KIND"] = project.kind.rawValue
        }

        if let socketPath {
            result["SHUTTLE_SOCKET_PATH"] = socketPath
        }

        return result
    }
}

/// Protocol for terminal engine implementations.
/// The app uses GhosttyKit as the concrete implementation.
/// ShuttleKit defines this protocol so the domain layer stays decoupled from
/// the terminal runtime.
public protocol TerminalEngine: Sendable {
    func bootstrapHint() -> String
}

/// Placeholder engine used when GhosttyKit is not yet available.
public struct PlaceholderTerminalEngine: TerminalEngine {
    public init() {}

    public func bootstrapHint() -> String {
        if GhosttyBootstrap.artifactExists() {
            return "GhosttyKit artifact found. The live terminal bridge is active."
        }
        return "GhosttyKit is not installed yet. Run scripts/download-prebuilt-ghosttykit.sh after pinning a release."
    }
}

/// Helpers for locating the GhosttyKit xcframework artifact.
public enum GhosttyBootstrap {
    public static func artifactSearchPaths(currentDirectoryPath: String = FileManager.default.currentDirectoryPath) -> [String] {
        [
            URL(fileURLWithPath: currentDirectoryPath).appending(path: "Vendor/GhosttyKit.xcframework").path,
            URL(fileURLWithPath: currentDirectoryPath).appending(path: "GhosttyKit.xcframework").path,
        ]
    }

    public static func artifactExists(currentDirectoryPath: String = FileManager.default.currentDirectoryPath) -> Bool {
        artifactSearchPaths(currentDirectoryPath: currentDirectoryPath).contains { FileManager.default.fileExists(atPath: $0) }
    }
}
