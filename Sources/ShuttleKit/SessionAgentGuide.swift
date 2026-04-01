import Foundation

public enum SessionAgentGuide {
    public static let fileName = "AGENTS.md"

    public static func shouldWrite(for bundle: SessionBundle) -> Bool {
        !bundle.sessionProjects.isEmpty
    }

    public static func fileURL(for session: Session) -> URL {
        URL(fileURLWithPath: session.sessionRootPath, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    @discardableResult
    public static func write(for bundle: SessionBundle, fileManager: FileManager = .default) throws -> URL {
        let url = fileURL(for: bundle.session)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try renderedContent(for: bundle).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func renderedContent(for bundle: SessionBundle) -> String {
        let projectsByID = Dictionary(uniqueKeysWithValues: bundle.projects.map { ($0.rawID, $0) })
        let projectLines = bundle.sessionProjects.compactMap { sessionProject -> String? in
            guard let project = projectsByID[sessionProject.projectID] else { return nil }
            let checkoutLocation = relativeSessionPath(
                sessionProject.checkoutPath,
                sessionRootPath: bundle.session.sessionRootPath
            ) ?? sessionProject.checkoutPath
            let checkoutKind = checkoutKindLabel(
                for: sessionProject,
                project: project,
                sessionRootPath: bundle.session.sessionRootPath
            )
            let projectGuidePath = detectedProjectGuideRelativePath(
                checkoutPath: sessionProject.checkoutPath,
                sessionRootPath: bundle.session.sessionRootPath
            )

            var line = "- `\(project.name)` — `\(checkoutLocation)` — \(checkoutKind)"
            if let projectGuidePath {
                line += " — read `\(projectGuidePath)` before editing"
            }
            return line
        }

        let projectGuideSummary: String
        let detectedGuides = projectLines.filter { $0.contains(" — read `") }
        if detectedGuides.isEmpty {
            projectGuideSummary = "No project-specific `AGENTS.md` files were detected when this session guide was written."
        } else {
            projectGuideSummary = "Project-specific guide files were detected in one or more checkouts. Read those before changing code in the matching project."
        }

        let projectCount = bundle.sessionProjects.count
        let body = """
        # AGENTS.md

        This directory is the Shuttle session root for workspace `\(bundle.workspace.name)`.

        Shuttle keeps session metadata here, while single-project sessions open directly in their source checkout.

        - Session: `\(bundle.session.name)` (`\(bundle.session.id)`)
        - Workspace: `\(bundle.workspace.name)`
        - Session root: `\(bundle.session.sessionRootPath)`
        - Projects: `\(projectCount)`

        ## Available project checkouts

        \(projectLines.joined(separator: "\n"))

        ## How to work in this session

        1. Use the checkout path above when switching into the active project.
        2. In single-project sessions, Shuttle opens app terminals directly in that source checkout by default.
        3. This session root mainly exists for Shuttle-managed metadata such as this guide and restore context.
        4. Before changing code in a project, read that project's `AGENTS.md` or `agents.md` file if one is listed above.
        5. Prefer paths relative to the active checkout when running commands.

        \(projectGuideSummary)
        """

        return body.hasSuffix("\n") ? body : body + "\n"
    }

    private static func relativeSessionPath(_ path: String, sessionRootPath: String) -> String? {
        let normalizedRoot = standardizedPath(sessionRootPath)
        let normalizedPath = standardizedPath(path)
        if normalizedPath == normalizedRoot {
            return "."
        }

        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedPath.hasPrefix(prefix) else { return nil }
        return "./" + String(normalizedPath.dropFirst(prefix.count))
    }

    private static func checkoutKindLabel(for _: SessionProject, project _: Project, sessionRootPath _: String) -> String {
        "direct source checkout"
    }

    private static func detectedProjectGuideRelativePath(checkoutPath: String, sessionRootPath: String) -> String? {
        let candidates = ["AGENTS.md", "agents.md"]
        for candidate in candidates {
            let candidatePath = URL(fileURLWithPath: checkoutPath, isDirectory: true)
                .appendingPathComponent(candidate, isDirectory: false)
                .path
            guard FileManager.default.fileExists(atPath: candidatePath) else { continue }
            return relativeSessionPath(candidatePath, sessionRootPath: sessionRootPath) ?? candidatePath
        }
        return nil
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
