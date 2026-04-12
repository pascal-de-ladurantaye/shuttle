import Foundation
import ShuttleKit

private let shuttleCLIJSONEnvelopeSchemaVersion = 2

private struct ShuttleCLIJSONErrorDetail: Encodable {
    let code: String
    let message: String
    let suggestions: [String]
    let usage: String?
}

private struct ShuttleCLIJSONEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion: Int
    let ok: Bool
    let type: String
    let data: Payload?
    let error: ShuttleCLIJSONErrorDetail?
}

private func shuttleCLIConfiguredJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
}

private func shuttleCLIPrintJSONEnvelope<Payload: Encodable>(type: String, data: Payload) {
    let encoder = shuttleCLIConfiguredJSONEncoder()
    guard let encoded = try? encoder.encode(
        ShuttleCLIJSONEnvelope(
            schemaVersion: shuttleCLIJSONEnvelopeSchemaVersion,
            ok: true,
            type: type,
            data: data,
            error: Optional<ShuttleCLIJSONErrorDetail>.none
        )
    ), let string = String(data: encoded, encoding: .utf8) else {
        return
    }
    print(string)
}

private func shuttleCLIPrintJSONErrorEnvelope(_ error: Error, arguments: [String]) {
    let shuttleError = (error as? ShuttleError) ?? ShuttleError.io(error.localizedDescription)
    let detail = ShuttleCLIJSONErrorDetail(
        code: shuttleError.code,
        message: shuttleError.localizedDescription,
        suggestions: CLI.commandSuggestions(arguments: arguments, error: shuttleError),
        usage: CLI.commandUsageHint(arguments: arguments, error: shuttleError)
    )
    let encoder = shuttleCLIConfiguredJSONEncoder()
    guard let encoded = try? encoder.encode(
        ShuttleCLIJSONEnvelope<String>(
            schemaVersion: shuttleCLIJSONEnvelopeSchemaVersion,
            ok: false,
            type: "error",
            data: nil,
            error: detail
        )
    ), let string = String(data: encoded, encoding: .utf8) else {
        return
    }
    fputs("\(string)\n", stderr)
}

@main
struct ShuttleCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let cli = CLI(arguments: arguments)
        do {
            try await cli.run()
        } catch let error as ShuttleError {
            if arguments.contains("--json") {
                shuttleCLIPrintJSONErrorEnvelope(error, arguments: arguments)
            } else {
                fputs("error: \(error.code): \(error.localizedDescription)\n", stderr)
            }
            exit(1)
        } catch {
            if arguments.contains("--json") {
                shuttleCLIPrintJSONErrorEnvelope(error, arguments: arguments)
            } else {
                fputs("error: \(error.localizedDescription)\n", stderr)
            }
            exit(1)
        }
    }
}

private struct CLI {
    let arguments: [String]

    func run() async throws {
        let parser = ArgumentParser(arguments: arguments)
        let json = parser.contains("--json")
        let cleanedArguments = parser.cleanedArguments(excludingFlags: ["--json"])

        if parser.isEmpty || parser.contains("--help") || parser.contains("-h") {
            if json {
                shuttleCLIPrintJSONEnvelope(type: "cli_schema", data: Self.schema())
            } else {
                printHelp()
            }
            return
        }

        guard let noun = cleanedArguments.first else {
            if json {
                shuttleCLIPrintJSONEnvelope(type: "cli_schema", data: Self.schema())
            } else {
                printHelp()
            }
            return
        }

        if noun == "help" {
            if json {
                shuttleCLIPrintJSONEnvelope(type: "cli_schema", data: Self.schema())
            } else {
                printHelp()
            }
            return
        }

        let store = try WorkspaceStore()

        switch noun {
        case "config":
            try await runConfig(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "project":
            try await runProject(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "workspace":
            try await runWorkspace(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "session":
            try await runSession(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "layout":
            try await runLayout(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "pane":
            try await runPane(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "tab":
            try await runTab(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "control":
            try await runControl(arguments: Array(cleanedArguments.dropFirst()), json: json)
        case "try":
            try await runTry(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        case "app":
            try await runApp(arguments: Array(cleanedArguments.dropFirst()), store: store, json: json)
        default:
            throw ShuttleError.invalidCommand("Unknown command: \(noun)")
        }
    }

    private func runConfig(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing config subcommand")
        }

        switch command {
        case "path":
            let paths = ShuttlePaths()
            if json {
                shuttleCLIPrintJSONEnvelope(
                    type: "config_path",
                    data: [
                        "profile": paths.profile.rawValue,
                        "config_path": paths.configURL.path,
                        "database_path": paths.databaseURL.path,
                        "app_support_path": paths.appSupportURL.path,
                    ]
                )
            } else {
                print(paths.configURL.path)
            }
        case "init":
            let manager = ConfigManager()
            try manager.ensureDefaultConfigExists()
            if json {
                shuttleCLIPrintJSONEnvelope(
                    type: "config_init",
                    data: [
                        "ok": AnyEncodable(true),
                        "config_path": AnyEncodable(ShuttlePaths().configURL.path),
                    ]
                )
            } else {
                print("Initialized config at \(ShuttlePaths().configURL.path)")
            }
        case "show":
            let config = try await store.config()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "config", data: config)
            } else {
                print("session_root: \(config.expandedSessionRoot)")
                if let triesRoot = config.expandedTriesRoot {
                    print("tries_root: \(triesRoot)")
                }
                print("project_roots:")
                for root in config.expandedProjectRoots {
                    print("  - \(root)")
                }
            }
        default:
            throw ShuttleError.invalidCommand("Unknown config subcommand: \(command)")
        }
    }

    private func runProject(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing project subcommand")
        }

        switch command {
        case "scan":
            let roots = try parseRepeatedOption("--root", in: Array(arguments.dropFirst()))
            let report = try await store.scanProjects(overrideRoots: roots)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "project_scan_report", data: report)
            } else {
                print("Scanned \(report.scannedRoots.count) roots, discovered \(report.discoveredProjects.count) projects")
                for project in report.discoveredProjects {
                    print("\(project.id)  \(project.name)  [\(project.kind.rawValue)]  \(project.path)")
                }
            }
        case "list":
            let projects = try await store.listProjects()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "project_list", data: JSONItems(items: projects))
            } else {
                for project in projects {
                    print("\(project.id)  \(project.name)  \(project.kind.rawValue)  \(project.path)")
                }
            }
        case "show":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("project show requires a project handle or name")
            }
            let details = try await store.projectDetails(token: token)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "project", data: details)
            } else {
                print("\(details.project.id)  \(details.project.name)")
                print("path: \(details.project.path)")
                print("kind: \(details.project.kind.rawValue)")
                if let workspace = details.defaultWorkspace {
                    print("default_workspace: \(workspace.id)  \(workspace.name)")
                }
            }
        default:
            throw ShuttleError.invalidCommand("Unknown project subcommand: \(command)")
        }
    }

    private func runWorkspace(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing workspace subcommand")
        }

        switch command {
        case "list":
            let workspaces = try await store.listWorkspaces()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "workspace_list", data: JSONItems(items: workspaces))
            } else {
                for details in workspaces {
                    let workspace = details.workspace
                    let kind = workspace.isDefault ? "default" : workspace.createdFrom.rawValue
                    print("\(workspace.id)  \(workspace.name)  \(kind)  projects=\(details.projects.count)  sessions=\(details.sessions.count)")
                }
            }
        case "show":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("workspace show requires a workspace handle or name")
            }
            let details = try await store.workspaceDetails(token: token)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "workspace", data: details)
            } else {
                print("\(details.workspace.id)  \(details.workspace.name)")
                print("projects:")
                for project in details.projects {
                    print("  - \(project.id)  \(project.name)  \(project.path)")
                }
                print("sessions:")
                for session in details.sessions {
                    print("  - \(session.id)  \(session.name)  \(session.status.rawValue)  \(session.sessionRootPath)")
                }
            }
        case "open":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("workspace open <workspace>")
            }
            let details = try await controlWorkspaceDetails(
                command: .workspaceOpen(workspaceToken: token),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "workspace_open", data: details)
            } else {
                print("Opened workspace \(details.workspace.id)  \(details.workspace.name)")
            }
        default:
            throw ShuttleError.invalidCommand("Unknown workspace subcommand: \(command)")
        }
    }

    private func runSession(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing session subcommand")
        }

        switch command {
        case "list":
            let workspaceToken = try parseOptionalValue("--workspace", in: Array(arguments.dropFirst()))
            let sessions = try await store.listSessions(workspaceToken: workspaceToken)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session_list", data: JSONItems(items: sessions))
            } else {
                for session in sessions {
                    print("\(session.id)  \(session.name)  workspace=\(Workspace.makeRef(session.workspaceID))  status=\(session.status.rawValue)  \(session.sessionRootPath)")
                }
            }
        case "show", "context":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("session \(command) requires a session handle or name")
            }
            let bundle = try await controlSessionBundle(
                sessionToken: token,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: command == "context" ? "session_context" : "session", data: bundle)
            } else {
                print("\(bundle.session.id)  \(bundle.session.name)")
                print("workspace: \(bundle.workspace.id)  \(bundle.workspace.name)")
                print("root: \(bundle.session.sessionRootPath)")
                print("projects:")
                for projectState in bundle.sessionProjects {
                    let project = bundle.projects.first(where: { $0.rawID == projectState.projectID })
                    let checkoutLabel = cliCheckoutLabel(
                        for: projectState,
                        sessionRootPath: bundle.session.sessionRootPath
                    )
                    print("  - \(project?.name ?? Project.makeRef(projectState.projectID))  \(checkoutLabel)  \(projectState.checkoutPath)")
                }
                let panesByRawID = Dictionary(uniqueKeysWithValues: bundle.panes.map { ($0.rawID, $0) })
                let tabsByPaneRawID = Dictionary(grouping: bundle.tabs, by: \.paneID)
                print("panes:")
                for pane in bundle.panes.sorted(by: { cliPaneSort($0, $1) }) {
                    let parent = pane.parentPaneID.flatMap { panesByRawID[$0]?.id } ?? "-"
                    let split = pane.splitDirection?.rawValue ?? "-"
                    let ratio = pane.ratio.map { String(format: "%.2f", $0) } ?? "-"
                    print("  - \(pane.id)  parent=\(parent)  split=\(split)  ratio=\(ratio)  position=\(pane.positionIndex)")
                    for tab in (tabsByPaneRawID[pane.rawID] ?? []).sorted(by: { cliTabSort($0, $1) }) {
                        print("      * \(tab.id)  \(tab.title)  cwd=\(tab.cwd)")
                    }
                }
            }
        case "open", "reopen":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("session \(command) <session>")
            }
            let activation = try await controlSessionActivation(
                command: .sessionOpen(sessionToken: token),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session_open", data: activation)
            } else {
                print("Opened session \(activation.bundle.session.id)  \(activation.bundle.session.name)")
                if activation.wasRestored {
                    print("restored: true")
                }
            }
        case "new":
            let args = Array(arguments.dropFirst())
            guard let workspaceToken = try parseOptionalValue("--workspace", in: args) else {
                throw ShuttleError.invalidArguments("session new requires --workspace <workspace>")
            }
            let name = try parseOptionalValue("--name", in: args)
            let layoutName = try parseOptionalValue("--layout", in: args)
            let bundle = try await controlSessionBundle(
                command: .sessionNew(workspaceToken: workspaceToken, name: name, layoutName: layoutName),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: bundle)
            } else {
                print("Created session \(bundle.session.id)  \(bundle.session.name)")
                print("root: \(bundle.session.sessionRootPath)")
            }
        case "ensure":
            let args = Array(arguments.dropFirst())
            guard let workspaceToken = try parseOptionalValue("--workspace", in: args) else {
                throw ShuttleError.invalidArguments("session ensure requires --workspace <workspace> --name <name>")
            }
            guard let name = try parseOptionalValue("--name", in: args) else {
                throw ShuttleError.invalidArguments("session ensure requires --name <name>")
            }
            let layoutName = try parseOptionalValue("--layout", in: args)
            let result = try await controlSessionMutationResult(
                command: .sessionEnsure(workspaceToken: workspaceToken, name: name, layoutName: layoutName),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session_ensure", data: result)
            } else if result.status.changed {
                print("Ensured session \(result.bundle.session.id)  \(result.bundle.session.name)")
                print("action: \(result.status.action)")
                print("root: \(result.bundle.session.sessionRootPath)")
            } else {
                print("Session \(result.bundle.session.id) already exists")
            }
        case "rename":
            let args = Array(arguments.dropFirst())
            guard args.count >= 2 else {
                throw ShuttleError.invalidArguments("session rename <session> <name>")
            }
            let token = args[0]
            let name = args.dropFirst().joined(separator: " ")
            let bundle = try await controlSessionBundle(
                command: .sessionRename(sessionToken: token, name: name),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: bundle)
            } else {
                print("Renamed session \(bundle.session.id)  \(bundle.session.name)")
            }
        case "close":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("session close <session>")
            }
            let bundle = try await controlSessionBundle(
                command: .sessionClose(sessionToken: token),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: bundle)
            } else {
                print("Closed session \(bundle.session.id)  \(bundle.session.name)")
                print("status: \(bundle.session.status.rawValue)")
            }
        case "ensure-closed":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("session ensure-closed <session>")
            }
            let result = try await controlSessionMutationResult(
                command: .sessionEnsureClosed(sessionToken: token),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session_ensure_closed", data: result)
            } else if result.status.changed {
                print("Ensured session \(result.bundle.session.id) is closed")
            } else {
                print("Session \(result.bundle.session.id) was already closed")
            }
        default:
            throw ShuttleError.invalidCommand("Unknown session subcommand: \(command)")
        }
    }

    private func runLayout(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing layout subcommand")
        }

        let layoutStore = LayoutPresetStore(paths: store.paths)

        switch command {
        case "list":
            let presets = try layoutStore.listPresets()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "layout_list", data: JSONItems(items: presets))
            } else {
                for preset in presets {
                    print("\(preset.id)  \(preset.name)  origin=\(preset.origin.rawValue)  \(preset.summary)")
                }
            }
        case "show":
            guard let token = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("layout show <layout>")
            }
            guard let preset = try layoutStore.preset(named: token) else {
                throw ShuttleError.notFound(entity: "Layout", token: token)
            }
            if json {
                shuttleCLIPrintJSONEnvelope(type: "layout", data: preset)
            } else {
                print("\(preset.id)  \(preset.name)")
                print("origin: \(preset.origin.rawValue)")
                print("summary: \(preset.summary)")
                if let description = preset.description {
                    print("description: \(description)")
                }
            }
        case "apply":
            let args = Array(arguments.dropFirst())
            guard let sessionToken = try parseOptionalValue("--session", in: args) else {
                throw ShuttleError.invalidArguments("layout apply --session <session> --layout <layout>")
            }
            guard let layoutName = try parseOptionalValue("--layout", in: args) else {
                throw ShuttleError.invalidArguments("layout apply requires --layout <layout>")
            }
            let bundle = try await controlSessionBundle(
                command: .layoutApply(sessionToken: sessionToken, layoutName: layoutName),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: bundle)
            } else {
                print("Applied layout \(bundle.session.layoutName ?? layoutName) to \(bundle.session.id)")
                print("panes: \(bundle.panes.count)")
                print("tabs: \(bundle.tabs.count)")
            }
        case "ensure-applied":
            let args = Array(arguments.dropFirst())
            guard let sessionToken = try parseOptionalValue("--session", in: args) else {
                throw ShuttleError.invalidArguments("layout ensure-applied --session <session> --layout <layout>")
            }
            guard let layoutName = try parseOptionalValue("--layout", in: args) else {
                throw ShuttleError.invalidArguments("layout ensure-applied requires --layout <layout>")
            }
            let result = try await controlLayoutMutationResult(
                command: .layoutEnsureApplied(sessionToken: sessionToken, layoutName: layoutName),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "layout_ensure_applied", data: result)
            } else if result.status.changed {
                print("Ensured layout \(result.layout.id) on \(result.bundle.session.id)")
                print("panes: \(result.bundle.panes.count)")
                print("tabs: \(result.bundle.tabs.count)")
            } else {
                print("Session \(result.bundle.session.id) already matches layout \(result.layout.id)")
            }
        case "save-current":
            let args = Array(arguments.dropFirst())
            guard let sessionToken = try parseOptionalValue("--session", in: args) else {
                throw ShuttleError.invalidArguments("layout save-current --session <session> --name <name> [--description <text>]")
            }
            guard let name = try parseOptionalValue("--name", in: args) else {
                throw ShuttleError.invalidArguments("layout save-current requires --name <name>")
            }
            let description = try parseOptionalValue("--description", in: args)
            let preset = try await controlLayoutPreset(
                command: .layoutSaveCurrent(sessionToken: sessionToken, name: name, description: description),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "layout", data: preset)
            } else {
                print("Saved layout \(preset.id)  \(preset.name)")
                print("summary: \(preset.summary)")
            }
        default:
            throw ShuttleError.invalidCommand("Unknown layout subcommand: \(command)")
        }
    }

    private func runPane(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing pane subcommand")
        }

        switch command {
        case "list":
            let args = Array(arguments.dropFirst())
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: try parseOptionalValue("--pane", in: args),
                childLabel: "pane"
            )
            let bundle = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let panes = if let paneToken = try parseOptionalValue("--pane", in: args) {
                [try resolvePane(in: bundle, token: paneToken)]
            } else {
                bundle.panes.sorted(by: { cliPaneSort($0, $1) })
            }
            if json {
                shuttleCLIPrintJSONEnvelope(type: "pane_list", data: JSONItems(items: panes))
            } else {
                let tabsByPaneRawID = Dictionary(grouping: bundle.tabs, by: \.paneID)
                let panesByRawID = Dictionary(uniqueKeysWithValues: bundle.panes.map { ($0.rawID, $0) })
                for pane in panes {
                    let parent = pane.parentPaneID.flatMap { panesByRawID[$0]?.id } ?? "-"
                    let split = pane.splitDirection?.rawValue ?? "-"
                    let ratio = pane.ratio.map { String(format: "%.2f", $0) } ?? "-"
                    let tabCount = tabsByPaneRawID[pane.rawID]?.count ?? 0
                    print("\(pane.id)  parent=\(parent)  split=\(split)  ratio=\(ratio)  position=\(pane.positionIndex)  tabs=\(tabCount)")
                }
            }
        case "show":
            let args = Array(arguments.dropFirst())
            guard let paneToken = resolvePaneToken(explicit: try parseOptionalValue("--pane", in: args)) else {
                throw ShuttleError.invalidArguments("pane show requires --pane <pane>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: paneToken,
                childLabel: "pane"
            )
            let bundle = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let pane = try resolvePane(in: bundle, token: paneToken)
            let tabs = bundle.tabs
                .filter { $0.paneID == pane.rawID }
                .sorted(by: { cliTabSort($0, $1) })
            let details = ShuttlePaneDetails(session: bundle.session, workspace: bundle.workspace, pane: pane, tabs: tabs)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "pane", data: details)
            } else {
                let parent = pane.parentPaneID.flatMap { parentRawID in
                    bundle.panes.first(where: { $0.rawID == parentRawID })?.id
                } ?? "-"
                let split = pane.splitDirection?.rawValue ?? "-"
                let ratio = pane.ratio.map { String(format: "%.2f", $0) } ?? "-"
                print("\(pane.id)")
                print("session: \(bundle.session.id)  \(bundle.session.name)")
                print("parent: \(parent)")
                print("split: \(split)")
                print("ratio: \(ratio)")
                print("position: \(pane.positionIndex)")
                print("tabs:")
                for tab in tabs {
                    print("  - \(tab.id)  \(tab.title)  cwd=\(tab.cwd)")
                }
            }
        case "split":
            let args = Array(arguments.dropFirst())
            guard let directionToken = args.first,
                  let direction = SplitDirection(rawValue: directionToken) else {
                throw ShuttleError.invalidArguments("pane split <left|right|up|down> --session <session> --pane <pane> [--source-tab <tab>]")
            }
            guard let paneToken = resolvePaneToken(explicit: try parseOptionalValue("--pane", in: args)) else {
                throw ShuttleError.invalidArguments("pane split requires --pane <pane>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: paneToken,
                childLabel: "pane"
            )
            let existing = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let pane = try resolvePane(in: existing, token: paneToken)
            let previousPaneIDs = Set(existing.panes.map(\.rawID))
            let previousTabIDs = Set(existing.tabs.map(\.rawID))
            let updated = try await controlSessionBundle(
                command: .paneSplit(
                    sessionToken: sessionToken,
                    paneToken: paneToken,
                    direction: direction,
                    sourceTabToken: try parseOptionalValue("--source-tab", in: args)
                ),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else {
                print("Split pane \(pane.id) \(direction.rawValue) in \(updated.session.id)")
                for newPane in updated.panes.filter({ !previousPaneIDs.contains($0.rawID) }).sorted(by: { cliPaneSort($0, $1) }) {
                    print("created_pane: \(newPane.id)")
                }
                for newTab in updated.tabs.filter({ !previousTabIDs.contains($0.rawID) }).sorted(by: { cliTabSort($0, $1) }) {
                    print("created_tab: \(newTab.id)  \(newTab.title)  cwd=\(newTab.cwd)")
                }
            }
        case "resize":
            let args = Array(arguments.dropFirst())
            guard let paneToken = resolvePaneToken(explicit: try parseOptionalValue("--pane", in: args)) else {
                throw ShuttleError.invalidArguments("pane resize requires --pane <pane> --ratio <ratio>")
            }
            guard let ratioToken = try parseOptionalValue("--ratio", in: args),
                  let ratio = Double(ratioToken) else {
                throw ShuttleError.invalidArguments("pane resize requires --ratio <ratio>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: paneToken,
                childLabel: "pane"
            )
            let bundle = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let pane = try resolvePane(in: bundle, token: paneToken)
            let updated = try await controlSessionBundle(
                command: .paneResize(sessionToken: sessionToken, paneToken: paneToken, ratio: ratio),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else {
                print("Resized pane \(pane.id) in \(updated.session.id) to ratio=\(String(format: "%.2f", ratio))")
            }
        default:
            throw ShuttleError.invalidCommand("Unknown pane subcommand: \(command)")
        }
    }

    private func runTab(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing tab subcommand")
        }

        switch command {
        case "list":
            let args = Array(arguments.dropFirst())
            let paneToken = try parseOptionalValue("--pane", in: args)
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: paneToken,
                childLabel: "pane"
            )
            let bundle = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let paneRawID = try paneToken.map { try resolvePane(in: bundle, token: $0).rawID }
            let tabs = bundle.tabs
                .filter { paneRawID == nil || $0.paneID == paneRawID }
                .sorted(by: { lhs, rhs in
                    if lhs.paneID == rhs.paneID {
                        return cliTabSort(lhs, rhs)
                    }
                    return lhs.paneID < rhs.paneID
                })
            if json {
                shuttleCLIPrintJSONEnvelope(type: "tab_list", data: JSONItems(items: tabs))
            } else {
                let panesByRawID = Dictionary(uniqueKeysWithValues: bundle.panes.map { ($0.rawID, $0) })
                for tab in tabs {
                    let paneLabel = panesByRawID[tab.paneID]?.id ?? Pane.makeRef(tab.paneID)
                    let attentionSuffix = tab.needsAttention ? "  ⚠ attention" + (tab.attentionMessage.map { ": \($0)" } ?? "") : ""
                    print("\(tab.id)  pane=\(paneLabel)  \(tab.title)  cwd=\(tab.cwd)\(attentionSuffix)")
                }
            }
        case "new":
            let args = Array(arguments.dropFirst())
            guard let paneToken = resolvePaneToken(explicit: try parseOptionalValue("--pane", in: args)) else {
                throw ShuttleError.invalidArguments("tab new requires --pane <pane>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: paneToken,
                childLabel: "pane"
            )
            let existing = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let pane = try resolvePane(in: existing, token: paneToken)
            let previousTabIDs = Set(existing.tabs.map(\.rawID))
            let updated = try await controlSessionBundle(
                command: .tabNew(
                    sessionToken: sessionToken,
                    paneToken: paneToken,
                    sourceTabToken: try parseOptionalValue("--source-tab", in: args)
                ),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else if let created = updated.tabs.first(where: { !previousTabIDs.contains($0.rawID) }) {
                print("Created tab \(created.id) in \(pane.id)")
                print("cwd: \(created.cwd)")
            } else {
                print("Opened new tab in \(pane.id)")
            }
        case "close":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab close requires --tab <tab>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let existing = try await controlSessionBundle(
                sessionToken: sessionToken,
                store: store,
                launchIfNeeded: false,
                allowLocalFallback: true
            )
            let tab = try resolveTab(in: existing, token: tabToken)
            let updated = try await controlSessionBundle(
                command: .tabClose(sessionToken: sessionToken, tabToken: tabToken),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else {
                print("Closed tab \(tab.id) from \(updated.session.id)")
                print("remaining_tabs: \(updated.tabs.count)")
            }
        case "send":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab send requires --tab <tab> plus --text <text>, --submit, or both")
            }
            let text = try parseOptionalValue("--text", in: args) ?? ""
            let submit = args.contains("--submit")
            guard !text.isEmpty || submit else {
                throw ShuttleError.invalidArguments("tab send requires --text <text>, --submit, or both")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let result = try await controlTabSendResult(
                command: .tabSend(sessionToken: sessionToken, tabToken: tabToken, text: text, submit: submit),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "tab_send", data: result)
            } else {
                if result.text.isEmpty {
                    print("Submitted \(result.tab.id)")
                } else {
                    print("Sent text to \(result.tab.id)")
                    print("bytes: \(result.text.utf8.count)")
                }
                if result.submitted {
                    print("submitted: true")
                }
                if let cursor = result.cursor {
                    print("cursor: \(cursor.token)")
                }
            }
        case "read":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab read requires --tab <tab>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let maxLines = try parseOptionalIntValue("--lines", in: args) ?? 200
            let mode = try parseOptionalReadMode("--mode", in: args) ?? .scrollback
            let afterCursorToken = try parseOptionalValue("--after-cursor", in: args)
            let result = try await controlTabReadResult(
                command: .tabRead(
                    sessionToken: sessionToken,
                    tabToken: tabToken,
                    mode: mode,
                    maxLines: maxLines,
                    afterCursorToken: afterCursorToken
                ),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "tab_read", data: result)
            } else {
                print(result.text, terminator: result.text.hasSuffix("\n") || result.text.isEmpty ? "" : "\n")
            }
        case "wait":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab wait requires --tab <tab> --text <text>")
            }
            guard let expectedText = try parseOptionalValue("--text", in: args) else {
                throw ShuttleError.invalidArguments("tab wait requires --text <text>")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let maxLines = try parseOptionalIntValue("--lines", in: args) ?? 400
            let mode = try parseOptionalReadMode("--mode", in: args) ?? .scrollback
            let timeoutMilliseconds = try parseOptionalIntValue("--timeout-ms", in: args) ?? 30_000
            let afterCursorToken = try parseOptionalValue("--after-cursor", in: args)
            let result = try await controlTabReadResult(
                command: .tabWait(
                    sessionToken: sessionToken,
                    tabToken: tabToken,
                    text: expectedText,
                    mode: mode,
                    maxLines: maxLines,
                    timeoutMilliseconds: timeoutMilliseconds,
                    afterCursorToken: afterCursorToken
                ),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "tab_wait", data: result)
            } else {
                print(result.text, terminator: result.text.hasSuffix("\n") || result.text.isEmpty ? "" : "\n")
            }
        case "mark-attention":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab mark-attention requires --tab <tab> or SHUTTLE_TAB_ID")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let message = try parseOptionalValue("--message", in: args)
            let updated = try await controlSessionBundle(
                command: .tabMarkAttention(sessionToken: sessionToken, tabToken: tabToken, message: message),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else {
                print("Marked \(tabToken) as needing attention")
                if let message {
                    print("message: \(message)")
                }
            }
        case "clear-attention":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab clear-attention requires --tab <tab> or SHUTTLE_TAB_ID")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let updated = try await controlSessionBundle(
                command: .tabClearAttention(sessionToken: sessionToken, tabToken: tabToken),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: true
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else {
                print("Cleared attention on \(tabToken)")
            }
        case "focus":
            let args = Array(arguments.dropFirst())
            guard let tabToken = resolveTabToken(explicit: try parseOptionalValue("--tab", in: args)) else {
                throw ShuttleError.invalidArguments("tab focus requires --tab <tab> or SHUTTLE_TAB_ID")
            }
            let sessionToken = try requiredSessionToken(
                explicit: try parseOptionalValue("--session", in: args),
                childToken: tabToken,
                childLabel: "tab"
            )
            let updated = try await controlSessionBundle(
                command: .tabFocus(sessionToken: sessionToken, tabToken: tabToken),
                store: store,
                launchIfNeeded: true,
                allowLocalFallback: false
            )
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: updated)
            } else {
                print("Focused \(tabToken)")
            }
        default:
            throw ShuttleError.invalidCommand("Unknown tab subcommand: \(command)")
        }
    }

    private func runTry(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing try subcommand")
        }

        switch command {
        case "new":
            guard let name = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("try new <name>")
            }
            let details = try await store.createTryProject(name: name)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "try_project", data: details)
            } else {
                print("Created try project \(details.project.id)  \(details.project.path)")
                if let workspace = details.defaultWorkspace {
                    print("default workspace: \(workspace.id)  \(workspace.name)")
                }
            }
        case "new-session":
            guard let name = arguments.dropFirst().first else {
                throw ShuttleError.invalidArguments("try new-session <name> [--layout <layout>]")
            }
            let layoutName = try parseOptionalValue("--layout", in: Array(arguments.dropFirst(2)))
            let bundle = try await store.createTrySession(name: name, layoutName: layoutName)
            if json {
                shuttleCLIPrintJSONEnvelope(type: "session", data: bundle)
            } else {
                print("Created try session \(bundle.session.id)  \(bundle.session.name)")
                print("root: \(bundle.session.sessionRootPath)")
            }
        default:
            throw ShuttleError.invalidCommand("Unknown try subcommand: \(command)")
        }
    }

    private func runControl(arguments: [String], json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing control subcommand")
        }

        switch command {
        case "ping":
            let client = ShuttleControlClient()
            let pong = try client.ping()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "control_pong", data: pong)
            } else {
                print("\(pong.message)  pid=\(pong.processID)  profile=\(pong.profile.rawValue)  socket=\(pong.socketPath)")
            }
        case "capabilities":
            let client = ShuttleControlClient()
            let capabilities = try client.capabilities()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "control_capabilities", data: capabilities)
            } else {
                print("profile: \(capabilities.profile.rawValue)")
                print("socket: \(capabilities.socketPath)")
                print("protocol: \(capabilities.protocolVersion)")
                print("commands:")
                for supported in capabilities.supportedCommands {
                    print("  - \(supported)")
                }
            }
        case "schema":
            if json {
                shuttleCLIPrintJSONEnvelope(type: "cli_schema", data: Self.schema())
            } else {
                print("Shuttle CLI schema is available via `shuttle control schema --json` or `shuttle --help --json`.")
            }
        case "socket-path":
            let socketPath = ShuttlePaths().controlSocketURL.path
            if json {
                shuttleCLIPrintJSONEnvelope(type: "control_socket_path", data: ["socket_path": socketPath])
            } else {
                print(socketPath)
            }
        default:
            throw ShuttleError.invalidCommand("Unknown control subcommand: \(command)")
        }
    }

    private func runApp(arguments: [String], store: WorkspaceStore, json: Bool) async throws {
        guard let command = arguments.first else {
            throw ShuttleError.invalidCommand("Missing app subcommand")
        }

        switch command {
        case "bootstrap-hint":
            let hint = await store.bootstrapHint()
            if json {
                shuttleCLIPrintJSONEnvelope(type: "bootstrap_hint", data: ["hint": hint])
            } else {
                print(hint)
            }
        default:
            throw ShuttleError.invalidCommand("Unknown app subcommand: \(command)")
        }
    }

    private func controlSessionBundle(
        sessionToken: String,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> SessionBundle {
        try await controlSessionBundle(
            command: .sessionBundle(sessionToken: sessionToken),
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
    }

    private func controlSessionBundle(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> SessionBundle {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .sessionBundle(let bundle) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return bundle
    }

    private func controlSessionActivation(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> SessionActivation {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .sessionActivation(let activation) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return activation
    }

    private func controlWorkspaceDetails(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> WorkspaceDetails {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .workspaceDetails(let details) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return details
    }

    private func controlLayoutPreset(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> LayoutPreset {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .layoutPreset(let preset) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return preset
    }

    private func controlSessionMutationResult(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> ShuttleSessionMutationResult {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .sessionMutationResult(let result) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return result
    }

    private func controlLayoutMutationResult(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> ShuttleLayoutMutationResult {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .layoutMutationResult(let result) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return result
    }

    private func controlTabSendResult(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> ShuttleTabSendResult {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .tabSendResult(let result) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return result
    }

    private func controlTabReadResult(
        command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> ShuttleTabReadResult {
        let value = try await executeControlCommand(
            command,
            store: store,
            launchIfNeeded: launchIfNeeded,
            allowLocalFallback: allowLocalFallback
        )
        guard case .tabReadResult(let result) = value else {
            throw ShuttleError.io("Unexpected control response for \(command.name)")
        }
        return result
    }

    private func executeControlCommand(
        _ command: ShuttleControlCommand,
        store: WorkspaceStore,
        launchIfNeeded: Bool,
        allowLocalFallback: Bool
    ) async throws -> ShuttleControlValue {
        let client = ShuttleControlClient()
        do {
            return try client.send(command, launchIfNeeded: launchIfNeeded)
        } catch let error as ShuttleError where allowLocalFallback && error.isLikelyControlPlaneUnavailable {
            return try await ShuttleControlCommandService(store: store).execute(command)
        }
    }

    private func envSessionToken() -> String? {
        ProcessInfo.processInfo.environment["SHUTTLE_SESSION_ID"]
    }

    private func envTabToken() -> String? {
        ProcessInfo.processInfo.environment["SHUTTLE_TAB_ID"]
    }

    private func envPaneToken() -> String? {
        ProcessInfo.processInfo.environment["SHUTTLE_PANE_ID"]
    }

    private func requiredSessionToken(explicit: String?, childToken: String?, childLabel: String) throws -> String {
        if let explicit {
            return explicit
        }
        if let childToken, let derived = scopedParentSessionToken(from: childToken) {
            return derived
        }
        if let envToken = envSessionToken() {
            return envToken
        }
        throw ShuttleError.invalidArguments("Missing --session <session> or fully scoped \(childLabel) handle")
    }

    private func resolveTabToken(explicit: String?) -> String? {
        explicit ?? envTabToken()
    }

    private func resolvePaneToken(explicit: String?) -> String? {
        explicit ?? envPaneToken()
    }

    private func scopedParentSessionToken(from token: String) -> String? {
        let components = token.split(separator: "/")
        guard components.count == 3,
              String(components[0]).hasPrefix("workspace:"),
              String(components[1]).hasPrefix("session:") else {
            return nil
        }
        return String(components[0]) + "/" + String(components[1])
    }

    private func resolvePane(in bundle: SessionBundle, token: String) throws -> Pane {
        try ShuttleControlCommandService.resolvePane(in: bundle, token: token)
    }

    private func resolveTab(in bundle: SessionBundle, token: String) throws -> Tab {
        try ShuttleControlCommandService.resolveTab(in: bundle, token: token)
    }

    private func parseRepeatedOption(_ option: String, in arguments: [String]) throws -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == option {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw ShuttleError.invalidArguments("Missing value for \(option)")
                }
                values.append(arguments[valueIndex])
                index += 2
            } else {
                index += 1
            }
        }
        return values
    }

    private func parseOptionalValue(_ option: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw ShuttleError.invalidArguments("Missing value for \(option)")
        }
        return arguments[valueIndex]
    }

    private func parseOptionalIntValue(_ option: String, in arguments: [String]) throws -> Int? {
        guard let value = try parseOptionalValue(option, in: arguments) else {
            return nil
        }
        guard let intValue = Int(value) else {
            throw ShuttleError.invalidArguments("Expected an integer value for \(option)")
        }
        return intValue
    }

    private func parseOptionalReadMode(_ option: String, in arguments: [String]) throws -> ShuttleTabReadMode? {
        guard let value = try parseOptionalValue(option, in: arguments) else {
            return nil
        }
        guard let mode = ShuttleTabReadMode(rawValue: value) else {
            throw ShuttleError.invalidArguments("Expected \(option) to be one of: screen, scrollback")
        }
        return mode
    }

    private func cliCheckoutLabel(for _: SessionProject, sessionRootPath _: String) -> String {
        "direct-source"
    }

    private func cliPaneSort(_ lhs: Pane, _ rhs: Pane) -> Bool {
        if lhs.positionIndex == rhs.positionIndex {
            return lhs.rawID < rhs.rawID
        }
        return lhs.positionIndex < rhs.positionIndex
    }

    private func cliTabSort(_ lhs: Tab, _ rhs: Tab) -> Bool {
        if lhs.positionIndex == rhs.positionIndex {
            return lhs.rawID < rhs.rawID
        }
        return lhs.positionIndex < rhs.positionIndex
    }

    private struct AnyEncodable: Encodable {
        private let encodeClosure: (Encoder) throws -> Void

        init<T: Encodable>(_ value: T) {
            self.encodeClosure = value.encode
        }

        func encode(to encoder: Encoder) throws {
            try encodeClosure(encoder)
        }
    }

    private struct JSONItems<Item: Encodable>: Encodable {
        let items: [Item]
    }

    private struct CLIEnumSchema: Encodable {
        let name: String
        let values: [String]
    }

    private struct CLIErrorCodeSchema: Encodable {
        let code: String
        let description: String
    }

    private struct CLICommandSchema: Encodable {
        let path: String
        let summary: String
        let responseType: String?
        let idempotency: String
        let transport: String?
        let arguments: [String]
        let options: [String]
    }

    private struct CLISchema: Encodable {
        let jsonEnvelopeSchemaVersion: Int
        let commands: [CLICommandSchema]
        let enums: [CLIEnumSchema]
        let errorCodes: [CLIErrorCodeSchema]
    }

    private static func schema() -> CLISchema {
        CLISchema(
            jsonEnvelopeSchemaVersion: shuttleCLIJSONEnvelopeSchemaVersion,
            commands: [
                CLICommandSchema(path: "help", summary: "Show human help or machine-readable schema", responseType: "cli_schema", idempotency: "idempotent_read", transport: nil, arguments: [], options: ["--json"]),
                CLICommandSchema(path: "config path", summary: "Print config/database/app-support paths", responseType: "config_path", idempotency: "idempotent_read", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "config init", summary: "Create the default config file if missing", responseType: "config_init", idempotency: "idempotent_mutation", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "config show", summary: "Show the resolved Shuttle config", responseType: "config", idempotency: "idempotent_read", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "project scan", summary: "Scan configured roots and discover projects", responseType: "project_scan_report", idempotency: "idempotent_mutation", transport: "local", arguments: [], options: ["--root <path> (repeatable)"]),
                CLICommandSchema(path: "project list", summary: "List known projects", responseType: "project_list", idempotency: "idempotent_read", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "project show", summary: "Show one project", responseType: "project", idempotency: "idempotent_read", transport: "local", arguments: ["<project>"], options: []),
                CLICommandSchema(path: "workspace list", summary: "List workspaces", responseType: "workspace_list", idempotency: "idempotent_read", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "workspace show", summary: "Show one workspace", responseType: "workspace", idempotency: "idempotent_read", transport: "local", arguments: ["<workspace>"], options: []),
                CLICommandSchema(path: "workspace open", summary: "Focus a workspace in the running app", responseType: "workspace_open", idempotency: "idempotent_mutation", transport: "socket_launch_if_needed", arguments: ["<workspace>"], options: []),
                CLICommandSchema(path: "session list", summary: "List sessions", responseType: "session_list", idempotency: "idempotent_read", transport: "local", arguments: [], options: ["--workspace <workspace>"]),
                CLICommandSchema(path: "session show", summary: "Show one session bundle", responseType: "session", idempotency: "idempotent_read", transport: "socket_or_local", arguments: ["<session>"], options: []),
                CLICommandSchema(path: "session context", summary: "Show machine-facing session/workspace/project/pane/tab context", responseType: "session_context", idempotency: "idempotent_read", transport: "socket_or_local", arguments: ["<session>"], options: []),
                CLICommandSchema(path: "session open", summary: "Open or focus a session in the running app", responseType: "session_open", idempotency: "idempotent_mutation", transport: "socket_launch_if_needed", arguments: ["<session>"], options: []),
                CLICommandSchema(path: "session reopen", summary: "Alias for session open with restore semantics", responseType: "session_open", idempotency: "idempotent_mutation", transport: "socket_launch_if_needed", arguments: ["<session>"], options: []),
                CLICommandSchema(path: "session new", summary: "Create a new session", responseType: "session", idempotency: "non_idempotent_mutation", transport: "socket_launch_if_needed", arguments: [], options: ["--workspace <workspace>", "--name <name>", "--layout <layout>"]),
                CLICommandSchema(path: "session ensure", summary: "Create or reuse a named session inside a workspace", responseType: "session_ensure", idempotency: "idempotent_create_or_reuse", transport: "socket_launch_if_needed", arguments: [], options: ["--workspace <workspace>", "--name <name>", "--layout <layout> (creation-time expectation)"]),
                CLICommandSchema(path: "session rename", summary: "Rename a session", responseType: "session", idempotency: "non_idempotent_mutation", transport: "socket_or_local", arguments: ["<session>", "<name>"], options: []),
                CLICommandSchema(path: "session close", summary: "Archive a session without deleting its data", responseType: "session", idempotency: "idempotent_mutation", transport: "socket_or_local", arguments: ["<session>"], options: []),
                CLICommandSchema(path: "session ensure-closed", summary: "Ensure a session is archived/closed", responseType: "session_ensure_closed", idempotency: "idempotent_mutation", transport: "socket_or_local", arguments: ["<session>"], options: []),
                CLICommandSchema(path: "layout list", summary: "List layout presets", responseType: "layout_list", idempotency: "idempotent_read", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "layout show", summary: "Show one layout preset", responseType: "layout", idempotency: "idempotent_read", transport: "local", arguments: ["<layout>"], options: []),
                CLICommandSchema(path: "layout apply", summary: "Replace a session's pane/tab tree with a preset", responseType: "session", idempotency: "idempotent_mutation", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--layout <layout>"]),
                CLICommandSchema(path: "layout ensure-applied", summary: "Apply a preset only when the current session layout differs", responseType: "layout_ensure_applied", idempotency: "idempotent_mutation", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--layout <layout>"]),
                CLICommandSchema(path: "layout save-current", summary: "Save the current session tree as a custom preset", responseType: "layout", idempotency: "non_idempotent_mutation", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--name <name>", "--description <text>"]),
                CLICommandSchema(path: "pane list", summary: "List panes", responseType: "pane_list", idempotency: "idempotent_read", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--pane <pane>"]),
                CLICommandSchema(path: "pane show", summary: "Show one pane and its tabs", responseType: "pane", idempotency: "idempotent_read", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--pane <pane>"]),
                CLICommandSchema(path: "pane split", summary: "Split a pane and clone or seed a tab into the new leaf", responseType: "session", idempotency: "non_idempotent_mutation", transport: "socket_launch_if_needed", arguments: ["<left|right|up|down>"], options: ["--session <session>", "--pane <pane>", "--source-tab <tab>"]),
                CLICommandSchema(path: "pane resize", summary: "Resize a split container ratio", responseType: "session", idempotency: "non_idempotent_mutation", transport: "socket_launch_if_needed", arguments: [], options: ["--session <session>", "--pane <pane>", "--ratio <ratio>"]),
                CLICommandSchema(path: "tab list", summary: "List tabs", responseType: "tab_list", idempotency: "idempotent_read", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--pane <pane>"]),
                CLICommandSchema(path: "tab new", summary: "Create a new tab in a pane", responseType: "session", idempotency: "non_idempotent_mutation", transport: "socket_launch_if_needed", arguments: [], options: ["--session <session>", "--pane <pane>", "--source-tab <tab>"]),
                CLICommandSchema(path: "tab close", summary: "Close a tab", responseType: "session", idempotency: "non_idempotent_mutation", transport: "socket_launch_if_needed", arguments: [], options: ["--session <session>", "--tab <tab>"]),
                CLICommandSchema(path: "tab send", summary: "Insert or paste text into a live tab and optionally submit it", responseType: "tab_send", idempotency: "non_idempotent_mutation", transport: "socket_launch_if_needed", arguments: [], options: ["--session <session>", "--tab <tab>", "--text <text>", "--submit"]),
                CLICommandSchema(path: "tab read", summary: "Capture screen or scrollback text from a live tab", responseType: "tab_read", idempotency: "idempotent_read", transport: "socket_launch_if_needed", arguments: [], options: ["--session <session>", "--tab <tab>", "--mode <screen|scrollback>", "--lines <n>", "--after-cursor <token>"]),
                CLICommandSchema(path: "tab wait", summary: "Wait until text appears in a live tab and return the captured output", responseType: "tab_wait", idempotency: "idempotent_read", transport: "socket_launch_if_needed", arguments: [], options: ["--session <session>", "--tab <tab>", "--text <text>", "--mode <screen|scrollback>", "--lines <n>", "--timeout-ms <ms>", "--after-cursor <token>"]),
                CLICommandSchema(path: "tab mark-attention", summary: "Mark a tab as needing attention", responseType: "session", idempotency: "idempotent_mutation", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--tab <tab>", "--message <text>"]),
                CLICommandSchema(path: "tab clear-attention", summary: "Clear the attention flag on a tab", responseType: "session", idempotency: "idempotent_mutation", transport: "socket_or_local", arguments: [], options: ["--session <session>", "--tab <tab>"]),
                CLICommandSchema(path: "control ping", summary: "Check control-plane reachability", responseType: "control_pong", idempotency: "idempotent_read", transport: "socket", arguments: [], options: []),
                CLICommandSchema(path: "control capabilities", summary: "List control protocol capabilities and supported commands", responseType: "control_capabilities", idempotency: "idempotent_read", transport: "socket", arguments: [], options: []),
                CLICommandSchema(path: "control schema", summary: "Dump the machine-readable CLI schema", responseType: "cli_schema", idempotency: "idempotent_read", transport: nil, arguments: [], options: []),
                CLICommandSchema(path: "control socket-path", summary: "Print the active control socket path", responseType: "control_socket_path", idempotency: "idempotent_read", transport: "local", arguments: [], options: []),
                CLICommandSchema(path: "try new", summary: "Create/register a try project", responseType: "try_project", idempotency: "non_idempotent_mutation", transport: "local", arguments: ["<name>"], options: []),
                CLICommandSchema(path: "try new-session", summary: "Create a try project and its first session", responseType: "session", idempotency: "non_idempotent_mutation", transport: "local", arguments: ["<name>"], options: ["--layout <layout>"]),
                CLICommandSchema(path: "app bootstrap-hint", summary: "Print shell/bootstrap guidance", responseType: "bootstrap_hint", idempotency: "idempotent_read", transport: "local", arguments: [], options: [])
            ],
            enums: [
                CLIEnumSchema(name: "split_direction", values: SplitDirection.allCases.map(\.rawValue)),
                CLIEnumSchema(name: "tab_read_mode", values: ShuttleTabReadMode.allCases.map(\.rawValue)),
                CLIEnumSchema(name: "session_status", values: SessionStatus.allCases.map(\.rawValue)),
                CLIEnumSchema(name: "runtime_status", values: RuntimeStatus.allCases.map(\.rawValue))
            ],
            errorCodes: [
                CLIErrorCodeSchema(code: ShuttleError.invalidCommand("").code, description: "Unknown top-level or subcommand"),
                CLIErrorCodeSchema(code: ShuttleError.invalidArguments("").code, description: "Arguments or flags were missing/invalid"),
                CLIErrorCodeSchema(code: ShuttleError.configMissing("").code, description: "Config file is missing"),
                CLIErrorCodeSchema(code: ShuttleError.configInvalid("").code, description: "Config file is invalid"),
                CLIErrorCodeSchema(code: ShuttleError.notFound(entity: "", token: "").code, description: "Requested entity was not found"),
                CLIErrorCodeSchema(code: ShuttleError.io("").code, description: "Filesystem/process/control-plane I/O failed"),
                CLIErrorCodeSchema(code: ShuttleError.database("").code, description: "SQLite persistence failed"),
                CLIErrorCodeSchema(code: ShuttleError.unsupported("").code, description: "Command is unsupported in the current execution context")
            ]
        )
    }

    static func commandUsageHint(arguments: [String], error: ShuttleError) -> String? {
        let cleaned = ArgumentParser(arguments: arguments).cleanedArguments(excludingFlags: ["--json"])
        let key = normalizedCommandPath(arguments: cleaned)
        let usageByPath: [String: String] = [
            "config path": "config path",
            "config init": "config init",
            "config show": "config show",
            "project scan": "project scan [--root PATH ...]",
            "project list": "project list",
            "project show": "project show <project>",
            "workspace show": "workspace show <workspace>",
            "workspace open": "workspace open <workspace>",
            "session show": "session show <session>",
            "session context": "session context <session>",
            "session open": "session open <session>",
            "session reopen": "session reopen <session>",
            "session new": "session new --workspace <workspace> [--name <name>] [--layout <layout>]",
            "session ensure": "session ensure --workspace <workspace> --name <name> [--layout <layout>]",
            "session rename": "session rename <session> <name>",
            "session close": "session close <session>",
            "session ensure-closed": "session ensure-closed <session>",
            "layout show": "layout show <layout>",
            "layout apply": "layout apply --session <session> --layout <layout>",
            "layout ensure-applied": "layout ensure-applied --session <session> --layout <layout>",
            "layout save-current": "layout save-current --session <session> --name <name> [--description <text>]",
            "pane show": "pane show --pane <pane> [--session <session>]",
            "pane split": "pane split <left|right|up|down> --pane <pane> [--session <session>] [--source-tab <tab>]",
            "pane resize": "pane resize --pane <pane> --ratio <ratio> [--session <session>]",
            "tab new": "tab new --pane <pane> [--session <session>] [--source-tab <tab>]",
            "tab close": "tab close --tab <tab> [--session <session>]",
            "tab send": "tab send --tab <tab> [--session <session>] [--text <text>] [--submit]",
            "tab read": "tab read --tab <tab> [--session <session>] [--mode screen|scrollback] [--lines <n>] [--after-cursor <token>]",
            "tab wait": "tab wait --tab <tab> --text <text> [--session <session>] [--mode screen|scrollback] [--lines <n>] [--timeout-ms <ms>] [--after-cursor <token>]",
            "tab mark-attention": "tab mark-attention [--tab <tab>] [--session <session>] [--message <text>]",
            "tab clear-attention": "tab clear-attention [--tab <tab>] [--session <session>]",
            "control ping": "control ping",
            "control capabilities": "control capabilities",
            "control schema": "control schema [--json]",
            "control socket-path": "control socket-path",
            "try new": "try new <name>",
            "try new-session": "try new-session <name> [--layout <layout>]",
            "app bootstrap-hint": "app bootstrap-hint"
        ]
        if let usage = usageByPath[key] {
            return usage
        }
        switch error {
        case .invalidCommand where cleaned.first == nil:
            return "Use `shuttle --help` or `shuttle --help --json`"
        default:
            return nil
        }
    }

    static func commandSuggestions(arguments: [String], error: ShuttleError) -> [String] {
        let cleaned = ArgumentParser(arguments: arguments).cleanedArguments(excludingFlags: ["--json"])
        let target = normalizedCommandPath(arguments: cleaned)
        guard !target.isEmpty else {
            return ["shuttle --help", "shuttle --help --json"]
        }

        let candidates = schema().commands.map(\.path) + ["--help", "--help --json"]
        return closestMatches(for: target, candidates: candidates, limit: 3)
    }

    private static func normalizedCommandPath(arguments: [String]) -> String {
        let positional = arguments.filter { !$0.hasPrefix("-") }
        return positional.prefix(2).joined(separator: " ")
    }

    private static func closestMatches(for target: String, candidates: [String], limit: Int) -> [String] {
        let normalizedTarget = target.lowercased()
        return candidates
            .map { candidate in
                (candidate, editDistance(normalizedTarget, candidate.lowercased()))
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 < rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var distances = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var previous = distances[0]
            distances[0] = leftIndex + 1

            for (rightIndex, rightCharacter) in right.enumerated() {
                let current = distances[rightIndex + 1]
                if leftCharacter == rightCharacter {
                    distances[rightIndex + 1] = previous
                } else {
                    distances[rightIndex + 1] = min(previous, distances[rightIndex], current) + 1
                }
                previous = current
            }
        }

        return distances[right.count]
    }

    private func printHelp() {
        print(
            """
            Shuttle CLI

            Commands:
              help
              config path|init|show
              project scan [--root PATH ...]
              project list
              project show <project>
              workspace list|show|open
              session list|show|context|open|reopen|new|ensure|rename|close|ensure-closed
              layout list|show|apply|ensure-applied|save-current
              pane list|show|split|resize
              tab list|new|close|send|read|wait|mark-attention|clear-attention
              control ping|capabilities|schema|socket-path
              try new|new-session
              app bootstrap-hint

            Command details:
              session ensure --workspace <workspace> --name <name> [--layout <layout>]
              session ensure-closed <session>
              layout ensure-applied --session <session> --layout <layout>
              tab send --tab <tab> [--text <text>] [--submit]
              tab read --tab <tab> [--mode screen|scrollback] [--lines <n>] [--after-cursor <token>]
              tab wait --tab <tab> --text <text> [--mode screen|scrollback] [--lines <n>] [--timeout-ms <ms>] [--after-cursor <token>]
              tab mark-attention [--tab <tab>] [--session <session>] [--message <text>]
              tab clear-attention [--tab <tab>] [--session <session>]

            Global flags:
              --json          machine-readable success/error envelopes
              --help          human help (or add --json for the full CLI schema)

            Handle examples:
              workspace:5
              workspace:5/session:3
              workspace:5/session:3/pane:2
              workspace:5/session:3/tab:1

            Environment:
              SHUTTLE_PROFILE=dev   use the dev config/app-support/session-root namespace
              SHUTTLE_APP_PATH      override the .app bundle used for launch-if-needed

            Notes:
              - workspace/session/pane/tab/layout commands prefer the app control socket and auto-launch Shuttle.app when live runtime access or UI selection changes are needed
              - JSON responses now use a versioned success/error envelope with `ok`, `type`, `data`, and `error`
              - `tab send`, `tab read`, and `tab wait` return cursor tokens so agents can perform incremental reads with `--after-cursor`
              - `shuttle --help --json` or `shuttle control schema --json` returns the machine-readable CLI schema
            """
        )
    }

}

private struct ArgumentParser {
    let arguments: [String]

    var isEmpty: Bool { arguments.isEmpty }

    func contains(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    func cleanedArguments(excludingFlags flags: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if flags.contains(argument) {
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }
}
