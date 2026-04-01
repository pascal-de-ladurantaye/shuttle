import XCTest
@testable import ShuttleKit

final class SessionDeletionTests: XCTestCase {
    func testPreviewDeleteSessionKeepsDirectCheckoutsOnDisk() async throws {
        let harness = try DeletionTestHarness()
        defer { harness.cleanup() }

        try harness.writeDefaultConfig()

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)

        let preview = try await store.previewDeleteSession(token: bundle.session.id)
        let projectPreview = try XCTUnwrap(preview.projects.first)

        XCTAssertEqual(projectPreview.sessionProject.checkoutType, .direct)
        XCTAssertEqual(projectPreview.sessionProject.checkoutPath, alphaURL.path)
        XCTAssertEqual(preview.sourceCheckoutProjectCount, 1)
    }

    func testPreviewDeleteSessionTreatsGitProjectsAsSimpleDirectSourceSessions() async throws {
        let harness = try DeletionTestHarness()
        defer { harness.cleanup() }

        try harness.writeDefaultConfig()
        let repoURL = try harness.createGitProject(named: "alpha", withRemote: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "git-dev", layoutName: nil)

        let preview = try await store.previewDeleteSession(token: bundle.session.id)
        let projectPreview = try XCTUnwrap(preview.projects.first)

        XCTAssertEqual(projectPreview.project.path, repoURL.path)
        XCTAssertEqual(projectPreview.sessionProject.checkoutType, .direct)
        XCTAssertEqual(projectPreview.sessionProject.checkoutPath, repoURL.path)
        XCTAssertEqual(preview.sourceCheckoutProjectCount, 1)
    }

    func testDeleteSessionKeepsDirectSourceCheckoutAndRemovesSessionArtifacts() async throws {
        let harness = try DeletionTestHarness()
        defer { harness.cleanup() }

        try harness.writeDefaultConfig()

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "direct-delete", layoutName: nil)
        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        XCTAssertEqual(sessionProject.checkoutPath, alphaURL.path)
        try "Session guide\n".write(
            to: SessionAgentGuide.fileURL(for: bundle.session),
            atomically: true,
            encoding: .utf8
        )

        _ = try await store.deleteSession(token: bundle.session.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionProject.checkoutPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionAgentGuide.fileURL(for: bundle.session).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.session.sessionRootPath))
    }

    func testDeleteSessionRemovesSessionArtifactsAndSnapshotState() async throws {
        let harness = try DeletionTestHarness()
        defer { harness.cleanup() }

        try harness.writeDefaultConfig()

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "delete-me", layoutName: nil)
        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        let tab = try XCTUnwrap(bundle.tabs.first)

        try await store.checkpointTab(
            rawID: tab.rawID,
            title: "shell",
            cwd: sessionProject.checkoutPath,
            scrollback: "hello\n",
            updateScrollback: true
        )

        let snapshot = ShuttleAppSessionSnapshot(
            savedAt: Date(),
            selectedWorkspaceID: bundle.workspace.rawID,
            selectedSessionID: bundle.session.rawID,
            selectedSession: nil
        )
        XCTAssertTrue(ShuttleSessionSnapshotStore.save(snapshot, paths: harness.paths))
        XCTAssertNotNil(ShuttleSessionSnapshotStore.load(paths: harness.paths))

        _ = try await store.deleteSession(token: bundle.session.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionProject.checkoutPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.session.sessionRootPath))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ShuttleScrollbackReplayStore.snapshotFileURL(forTabRawID: tab.rawID, paths: harness.paths).path
            )
        )
        XCTAssertNil(ShuttleSessionSnapshotStore.load(paths: harness.paths))
        let remainingSessions = try await store.listSessions()
        XCTAssertFalse(remainingSessions.contains(where: { $0.rawID == bundle.session.rawID }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.path))
    }

    func testDeleteSessionRemovesNonEmptySessionRootIncludingLegacySourceLinkArtifacts() async throws {
        let harness = try DeletionTestHarness()
        defer { harness.cleanup() }

        try harness.writeDefaultConfig()

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "legacy-link", layoutName: nil)

        let legacyLinkURL = URL(fileURLWithPath: bundle.session.sessionRootPath, isDirectory: true)
            .appendingPathComponent("alpha-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: legacyLinkURL.path, withDestinationPath: alphaURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLinkURL.path))

        _ = try await store.deleteSession(token: bundle.session.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLinkURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.session.sessionRootPath))
    }
}

private struct DeletionTestHarness {
    let rootURL: URL
    let projectsRootURL: URL
    let paths: ShuttlePaths

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectsRootURL = rootURL.appendingPathComponent("projects", isDirectory: true)
        let configDirectoryURL = rootURL.appendingPathComponent("config", isDirectory: true)
        let appSupportURL = rootURL.appendingPathComponent("app-support", isDirectory: true)

        try FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        self.rootURL = rootURL
        self.projectsRootURL = projectsRootURL
        self.paths = ShuttlePaths(configDirectoryURL: configDirectoryURL, appSupportURL: appSupportURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeDefaultConfig() throws {
        try writeConfig(
            sessionRoot: rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [projectsRootURL.path]
        )
    }

    func writeConfig(sessionRoot: String, triesRoot: String, projectRoots: [String]) throws {
        let config: [String: Any] = [
            "session_root": sessionRoot,
            "tries_root": triesRoot,
            "project_roots": projectRoots,
            "ignored_paths": [
                "**/.git",
                "**/.DS_Store",
                "**/node_modules"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: paths.configURL, options: .atomic)
    }

    @discardableResult
    func createGitProject(named name: String, withRemote: Bool) throws -> URL {
        let repoURL = projectsRootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try git(["init"], in: repoURL.path)
        try git(["checkout", "-b", "main"], in: repoURL.path)
        try git(["config", "user.email", "shuttle-tests@example.com"], in: repoURL.path)
        try git(["config", "user.name", "Shuttle Tests"], in: repoURL.path)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repoURL.path)
        try git(["commit", "-m", "initial"], in: repoURL.path)

        if withRemote {
            let remoteURL = rootURL.appendingPathComponent("\(name)-remote.git", isDirectory: true)
            try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
            try git(["init", "--bare"], in: remoteURL.path)
            try git(["remote", "add", "origin", remoteURL.path], in: repoURL.path)
            try git(["push", "-u", "origin", "main"], in: repoURL.path)
        }

        return repoURL
    }

    func git(_ arguments: [String], in directory: String) throws {
        let result = try runProcess("/usr/bin/env", arguments: ["git"] + arguments, currentDirectoryPath: directory)
        if !result.succeeded {
            throw ShuttleError.io(result.stderr.isEmpty ? "git command failed" : result.stderr)
        }
    }
}
