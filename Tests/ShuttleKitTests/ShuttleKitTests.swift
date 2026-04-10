import XCTest
@testable import ShuttleKit

final class ShuttleKitTests: XCTestCase {
    func testProgrammaticTerminalInputChunksTreatNewlinesAsSubmitOperations() {
        XCTAssertEqual(
            shuttleProgrammaticTerminalInputChunks(for: "echo hi\n"),
            [.text("echo hi"), .submit]
        )
        XCTAssertEqual(
            shuttleProgrammaticTerminalInputChunks(for: "printf foo\r\nprintf bar\n\nexit"),
            [.text("printf foo"), .submit, .text("printf bar"), .submit, .submit, .text("exit")]
        )
        XCTAssertEqual(
            shuttleProgrammaticTerminalInputChunks(for: ""),
            []
        )
    }

    func testIncrementalTerminalTextReturnsOnlyNewOutput() {
        XCTAssertEqual(
            shuttleIncrementalTerminalText(previous: "hello\n", current: "hello\nworld\n"),
            "world\n"
        )
        XCTAssertEqual(
            shuttleIncrementalTerminalText(previous: "line1\nline2\nline3\n", current: "line2\nline3\nline4\n"),
            "line4\n"
        )
        XCTAssertEqual(
            shuttleIncrementalTerminalText(previous: "same\n", current: "same\n"),
            ""
        )
    }

    func testControlCapabilitiesAdvertiseSimplifiedCommandSet() throws {
        let store = try WorkspaceStore()
        let service = ShuttleControlCommandService(store: store)
        let supported = Set(service.capabilities().supportedCommands)

        XCTAssertTrue(supported.contains("workspace.open"))
        XCTAssertTrue(supported.contains("session.new"))
        XCTAssertTrue(supported.contains("layout.apply"))
        XCTAssertFalse(supported.contains("workspace.new"))
        XCTAssertFalse(supported.contains("workspace.ensure"))
        XCTAssertFalse(supported.contains("workspace.add-project"))
        XCTAssertFalse(supported.contains("session.add-project"))
        XCTAssertFalse(supported.contains("session.promote-project"))
    }

    func testStoreAlwaysProvidesBuiltInGlobalWorkspace() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let store = try WorkspaceStore(paths: harness.paths)
        let workspaces = try await store.listWorkspaces()
        let global = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(global.workspace.createdFrom, .global)
        XCTAssertEqual(global.workspace.name, "Global")
        XCTAssertTrue(global.workspace.projectIDs.isEmpty)
        XCTAssertTrue(global.projects.isEmpty)
        XCTAssertTrue(global.sessions.isEmpty)

        let resolved = try await store.workspaceDetails(token: "global")
        XCTAssertEqual(resolved.workspace.rawID, global.workspace.rawID)
    }

    func testCreateGlobalSessionStartsTabsInHomeDirectory() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let store = try WorkspaceStore(paths: harness.paths)
        let bundle = try await store.createSession(workspaceToken: "global", name: "scratch", layoutName: nil)
        let initialTab = try XCTUnwrap(bundle.tabs.first)

        XCTAssertEqual(bundle.workspace.createdFrom, .global)
        XCTAssertTrue(bundle.projects.isEmpty)
        XCTAssertTrue(bundle.sessionProjects.isEmpty)
        XCTAssertEqual(initialTab.cwd, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertNil(initialTab.projectID)
    }

    func testEnsureSessionAndEnsureClosedAreIdempotent() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()

        let created = try await store.ensureSession(workspaceToken: "alpha", name: "agent", layoutName: "single")
        XCTAssertTrue(created.status.changed)
        XCTAssertEqual(created.status.action, "created")

        let reused = try await store.ensureSession(workspaceToken: "alpha", name: "agent", layoutName: "single")
        XCTAssertFalse(reused.status.changed)
        XCTAssertEqual(reused.status.noopReason, "already_present")
        XCTAssertEqual(reused.bundle.session.id, created.bundle.session.id)

        let closed = try await store.ensureSessionClosed(token: created.bundle.session.id)
        XCTAssertTrue(closed.status.changed)
        XCTAssertEqual(closed.status.action, "closed")
        XCTAssertEqual(closed.bundle.session.status, .closed)

        let alreadyClosed = try await store.ensureSessionClosed(token: created.bundle.session.id)
        XCTAssertFalse(alreadyClosed.status.changed)
        XCTAssertEqual(alreadyClosed.status.noopReason, "already_closed")
        XCTAssertEqual(alreadyClosed.bundle.session.status, .closed)
    }

    func testEnsureLayoutAppliedNoopsWhenPresetAlreadyMatches() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)

        let applied = try await store.ensureLayoutApplied(sessionToken: bundle.session.id, layoutName: "dev")
        XCTAssertTrue(applied.status.changed)
        XCTAssertEqual(applied.status.action, "applied")
        XCTAssertEqual(applied.bundle.session.layoutName, "dev")

        let noop = try await store.ensureLayoutApplied(sessionToken: bundle.session.id, layoutName: "dev")
        XCTAssertFalse(noop.status.changed)
        XCTAssertEqual(noop.status.noopReason, "already_applied")
        XCTAssertEqual(noop.layout.id, "dev")
    }

    func testScanCreatesDefaultWorkspaceAndSessionForPlainDirectory() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        let betaURL = harness.projectsRootURL.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        let report = try await store.scanProjects()
        XCTAssertEqual(report.discoveredProjects.count, 2)
        XCTAssertTrue(report.removedWorkspaces.isEmpty)

        let workspaces = try await store.listWorkspaces()
        XCTAssertEqual(workspaces.count, 3)
        XCTAssertEqual(workspaces.filter { $0.workspace.createdFrom == .global }.count, 1)
        XCTAssertEqual(
            Set(workspaces.filter { $0.workspace.createdFrom != .global }.map(\.workspace.name)),
            Set(["alpha", "beta"])
        )

        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        XCTAssertEqual(bundle.workspace.name, "alpha")
        XCTAssertEqual(bundle.sessionProjects.count, 1)
        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        XCTAssertEqual(sessionProject.checkoutType, .direct)
        XCTAssertEqual(sessionProject.checkoutPath, alphaURL.path)
        XCTAssertEqual(bundle.tabs.count, 1)
        let initialTab = try XCTUnwrap(bundle.tabs.first)
        XCTAssertEqual(initialTab.cwd, sessionProject.checkoutPath)
        XCTAssertEqual(initialTab.projectID, sessionProject.projectID)
    }

    func testScanRemovesMissingProjectWorkspaceAndSessionArtifacts() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        let betaURL = harness.projectsRootURL.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let tab = try XCTUnwrap(bundle.tabs.first)

        try await store.checkpointTab(
            rawID: tab.rawID,
            title: "shell",
            cwd: alphaURL.path,
            scrollback: "hello\n",
            updateScrollback: true
        )
        try "Session guide\n".write(
            to: SessionAgentGuide.fileURL(for: bundle.session),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = ShuttleAppSessionSnapshot(
            savedAt: Date(),
            selectedWorkspaceID: bundle.workspace.rawID,
            selectedSessionID: bundle.session.rawID,
            selectedSession: nil
        )
        XCTAssertTrue(ShuttleSessionSnapshotStore.save(snapshot, paths: harness.paths))

        try FileManager.default.removeItem(at: alphaURL)

        let report = try await store.scanProjects()
        XCTAssertEqual(report.discoveredProjects.map(\.name), ["beta"])
        XCTAssertEqual(report.removedWorkspaces.map(\.name), ["alpha"])
        let remainingProjects = try await store.listProjects()
        XCTAssertEqual(remainingProjects.map(\.name), ["beta"])

        let workspaces = try await store.listWorkspaces()
        XCTAssertEqual(Set(workspaces.map(\.workspace.name)), Set(["Global", "beta"]))
        XCTAssertFalse(workspaces.contains(where: { $0.workspace.name == "alpha" }))
        let remainingSessions = try await store.listSessions()
        XCTAssertTrue(remainingSessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionAgentGuide.fileURL(for: bundle.session).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ShuttleScrollbackReplayStore.snapshotFileURL(forTabRawID: tab.rawID, paths: harness.paths).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.session.sessionRootPath))
        XCTAssertNil(ShuttleSessionSnapshotStore.load(paths: harness.paths))
    }

    func testConcurrentReadOnlyStoreInitializationDoesNotLockDatabase() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let seedStore = try WorkspaceStore(paths: harness.paths)
        _ = try await seedStore.scanProjects()
        let bundle = try await seedStore.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sessionToken = bundle.session.id

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let store = try WorkspaceStore(paths: harness.paths)
                    let resolved = try await store.sessionBundle(token: sessionToken)
                    XCTAssertFalse(resolved.panes.isEmpty)
                    XCTAssertFalse(resolved.tabs.isEmpty)
                }
            }
            try await group.waitForAll()
        }
    }

    func testControlServerClientRoundTripsPing() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let server = ShuttleControlServer(paths: harness.paths) { command in
            switch command {
            case .ping:
                return .pong(
                    ShuttleControlPong(
                        profile: harness.paths.profile,
                        socketPath: harness.paths.controlSocketURL.path,
                        processID: 1234
                    )
                )
            case .capabilities:
                return .capabilities(
                    ShuttleControlCapabilities(
                        protocolVersion: ShuttleControlRequest.protocolVersion,
                        profile: harness.paths.profile,
                        socketPath: harness.paths.controlSocketURL.path,
                        supportedCommands: ShuttleControlCommand.supportedCommandNames
                    )
                )
            default:
                throw ShuttleError.invalidArguments("Unexpected command")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = ShuttleControlClient(paths: harness.paths)
        let pong = try client.ping()
        XCTAssertEqual(pong.message, "pong")
        XCTAssertEqual(pong.socketPath, harness.paths.controlSocketURL.path)
        XCTAssertEqual(pong.processID, 1234)
    }

    func testControlCommandServiceCreatesTabFromScopedPaneToken() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let service = ShuttleControlCommandService(store: store)

        let value = try await service.execute(
            .tabNew(sessionToken: bundle.session.id, paneToken: bundle.panes[0].id, sourceTabToken: nil)
        )
        guard case .sessionBundle(let updated) = value else {
            return XCTFail("Expected updated session bundle")
        }

        XCTAssertEqual(updated.tabs.count, bundle.tabs.count + 1)
        XCTAssertEqual(updated.panes.count, bundle.panes.count)
        XCTAssertEqual(updated.session.id, bundle.session.id)
    }

    func testControlCommandServiceMarksAndClearsTabAttention() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let tab = try XCTUnwrap(bundle.tabs.first)
        let service = ShuttleControlCommandService(store: store)

        // Mark attention
        let markValue = try await service.execute(
            .tabMarkAttention(sessionToken: bundle.session.id, tabToken: tab.id, message: "Build done")
        )
        guard case .sessionBundle(let markedBundle) = markValue else {
            return XCTFail("Expected session bundle")
        }
        let markedTab = try XCTUnwrap(markedBundle.tabs.first(where: { $0.rawID == tab.rawID }))
        XCTAssertTrue(markedTab.needsAttention)
        XCTAssertEqual(markedTab.attentionMessage, "Build done")

        // Verify attention counts
        let counts = try await store.attentionCountsBySession()
        XCTAssertEqual(counts[bundle.session.rawID], 1)

        // Clear attention
        let clearValue = try await service.execute(
            .tabClearAttention(sessionToken: bundle.session.id, tabToken: tab.id)
        )
        guard case .sessionBundle(let clearedBundle) = clearValue else {
            return XCTFail("Expected session bundle")
        }
        let clearedTab = try XCTUnwrap(clearedBundle.tabs.first(where: { $0.rawID == tab.rawID }))
        XCTAssertFalse(clearedTab.needsAttention)
        XCTAssertNil(clearedTab.attentionMessage)

        // Verify attention counts are empty
        let clearedCounts = try await store.attentionCountsBySession()
        XCTAssertNil(clearedCounts[bundle.session.rawID])
    }

    func testSessionIDsAreScopedToWorkspace() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        let betaURL = harness.projectsRootURL.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()

        let alphaOne = try await store.createSession(workspaceToken: "alpha", name: "one", layoutName: nil)
        let alphaTwo = try await store.createSession(workspaceToken: "alpha", name: "two", layoutName: nil)
        let betaOne = try await store.createSession(workspaceToken: "beta", name: "one", layoutName: nil)

        XCTAssertEqual(alphaOne.session.sessionNumber, 1)
        XCTAssertEqual(alphaTwo.session.sessionNumber, 2)
        XCTAssertEqual(betaOne.session.sessionNumber, 1)
        XCTAssertEqual(alphaOne.session.id, "workspace:\(alphaOne.workspace.rawID)/session:1")
        XCTAssertEqual(alphaTwo.session.id, "workspace:\(alphaTwo.workspace.rawID)/session:2")
        XCTAssertEqual(betaOne.session.id, "workspace:\(betaOne.workspace.rawID)/session:1")
        let resolvedAlphaTwo = try await store.sessionBundle(token: alphaTwo.session.id)
        XCTAssertEqual(resolvedAlphaTwo.session.rawID, alphaTwo.session.rawID)
    }

    func testPaneIDsAreScopedToSession() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()

        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let rootPane = try XCTUnwrap(bundle.panes.first)
        let split = try await store.splitPane(
            sessionToken: bundle.session.id,
            paneRawID: rootPane.rawID,
            direction: .right,
            sourceTabRawID: bundle.tabs.first?.rawID
        )
        let newPanes = split.panes.filter { pane in
            !bundle.panes.contains(where: { $0.rawID == pane.rawID })
        }
        let secondSession = try await store.createSession(workspaceToken: "alpha", name: "review", layoutName: nil)
        let secondSessionRootPane = try XCTUnwrap(secondSession.panes.first)

        XCTAssertEqual(rootPane.paneNumber, 1)
        XCTAssertEqual(Set(newPanes.map(\.paneNumber)), Set([2, 3]))
        XCTAssertEqual(secondSessionRootPane.paneNumber, 1)
        XCTAssertEqual(rootPane.id, "workspace:\(bundle.workspace.rawID)/session:\(bundle.session.sessionNumber)/pane:1")
        XCTAssertEqual(secondSessionRootPane.id, "workspace:\(secondSession.workspace.rawID)/session:\(secondSession.session.sessionNumber)/pane:1")
        XCTAssertNotEqual(rootPane.id, secondSessionRootPane.id)
    }

    func testTabIDsAreScopedToSession() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()

        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let firstPane = try XCTUnwrap(bundle.panes.first)
        let firstTab = try XCTUnwrap(bundle.tabs.first)
        let split = try await store.splitPane(
            sessionToken: bundle.session.id,
            paneRawID: firstPane.rawID,
            direction: .right,
            sourceTabRawID: firstTab.rawID
        )
        let secondTab = try XCTUnwrap(split.tabs.first(where: { $0.rawID != firstTab.rawID }))
        let secondSession = try await store.createSession(workspaceToken: "alpha", name: "review", layoutName: nil)
        let secondSessionFirstTab = try XCTUnwrap(secondSession.tabs.first)

        XCTAssertEqual(firstTab.tabNumber, 1)
        XCTAssertEqual(secondTab.tabNumber, 2)
        XCTAssertEqual(secondSessionFirstTab.tabNumber, 1)
        XCTAssertEqual(firstTab.id, "workspace:\(bundle.workspace.rawID)/session:\(bundle.session.sessionNumber)/tab:1")
        XCTAssertEqual(secondTab.id, "workspace:\(split.workspace.rawID)/session:\(split.session.sessionNumber)/tab:2")
        XCTAssertEqual(secondSessionFirstTab.id, "workspace:\(secondSession.workspace.rawID)/session:\(secondSession.session.sessionNumber)/tab:1")
        XCTAssertNotEqual(firstTab.id, secondSessionFirstTab.id)
    }

    func testCreateSessionUsesDirectSourcePathForGitRepositories() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let sessionRoot = harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path
        let triesRoot = harness.rootURL.appendingPathComponent("tries", isDirectory: true).path
        try harness.writeConfig(
            sessionRoot: sessionRoot,
            triesRoot: triesRoot,
            projectRoots: [harness.projectsRootURL.path]
        )

        let repoURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try harness.git(["init"], in: repoURL.path)
        try harness.git(["checkout", "-b", "main"], in: repoURL.path)
        try harness.git(["config", "user.email", "shuttle-tests@example.com"], in: repoURL.path)
        try harness.git(["config", "user.name", "Shuttle Tests"], in: repoURL.path)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try harness.git(["add", "."], in: repoURL.path)
        try harness.git(["commit", "-m", "initial"], in: repoURL.path)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "direct", layoutName: nil)
        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)

        XCTAssertEqual(sessionProject.checkoutType, .direct)
        XCTAssertEqual(sessionProject.checkoutPath, repoURL.path)
    }

    func testCreateSessionUsesDirectSourcePathWhenRepositoryDetected() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let repoURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try harness.git(["init"], in: repoURL.path)
        try harness.git(["checkout", "-b", "main"], in: repoURL.path)
        try harness.git(["config", "user.email", "shuttle-tests@example.com"], in: repoURL.path)
        try harness.git(["config", "user.name", "Shuttle Tests"], in: repoURL.path)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try harness.git(["add", "."], in: repoURL.path)
        try harness.git(["commit", "-m", "initial"], in: repoURL.path)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)

        XCTAssertEqual(bundle.sessionProjects.count, 1)
        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        XCTAssertEqual(sessionProject.checkoutType, .direct)
        XCTAssertEqual(sessionProject.checkoutPath, repoURL.path)
        let initialTab = try XCTUnwrap(bundle.tabs.first)
        XCTAssertEqual(initialTab.cwd, sessionProject.checkoutPath)
        XCTAssertEqual(initialTab.projectID, sessionProject.projectID)
    }

    func testCreateSessionAppliesBuiltInDevLayout() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: "dev")

        XCTAssertEqual(bundle.session.layoutName, "dev")
        XCTAssertEqual(bundle.tabs.count, 2)
        XCTAssertEqual(bundle.panes.count, 3)

        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        XCTAssertTrue(bundle.tabs.allSatisfy { $0.cwd == sessionProject.checkoutPath })
        XCTAssertTrue(bundle.tabs.allSatisfy { $0.projectID == sessionProject.projectID })

        let rootPane = try XCTUnwrap(bundle.panes.first(where: { $0.parentPaneID == nil }))
        XCTAssertEqual(rootPane.splitDirection, .right)
        XCTAssertEqual(try XCTUnwrap(rootPane.ratio), 0.62, accuracy: 0.0001)
        XCTAssertEqual(bundle.panes.filter { $0.parentPaneID == rootPane.rawID }.count, 2)
    }

    func testCreateSessionAppliesCustomLayoutPresetFromStore() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let layoutStore = LayoutPresetStore(paths: harness.paths)
        try layoutStore.saveCustomPreset(
            LayoutPreset(
                id: "review-stack",
                name: "Review Stack",
                root: LayoutPaneTemplate(
                    splitDirection: .down,
                    ratio: 0.55,
                    children: [
                        LayoutPaneTemplate(tabs: [
                            LayoutTabTemplate(title: "Editor"),
                            LayoutTabTemplate(title: "Tests", command: "npm test")
                        ]),
                        LayoutPaneTemplate(tabs: [LayoutTabTemplate(title: "Logs")]),
                    ],
                    tabs: []
                )
            )
        )

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "review", layoutName: "review-stack")

        XCTAssertEqual(bundle.session.layoutName, "review-stack")
        XCTAssertEqual(bundle.panes.count, 3)
        XCTAssertEqual(bundle.tabs.count, 3)

        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        XCTAssertTrue(bundle.tabs.allSatisfy { $0.cwd == sessionProject.checkoutPath })
        XCTAssertTrue(bundle.tabs.allSatisfy { $0.projectID == sessionProject.projectID })

        let titledTabs = bundle.tabs.map(\.title)
        XCTAssertTrue(titledTabs.contains("Editor"))
        XCTAssertTrue(titledTabs.contains("Tests"))
        XCTAssertTrue(titledTabs.contains("Logs"))
        XCTAssertEqual(bundle.tabs.first(where: { $0.title == "Tests" })?.command, "npm test")
    }

    func testLayoutPresetStoreOverwritesExistingCustomPresetName() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let layoutStore = LayoutPresetStore(paths: harness.paths)
        try layoutStore.saveCustomPreset(
            LayoutPreset(
                id: "agent-copy",
                name: "Agent Copy",
                root: LayoutPaneTemplate(tabs: [LayoutTabTemplate()])
            )
        )

        try layoutStore.saveCustomPreset(
            LayoutPreset(
                id: "agent-copy",
                name: "Agent Review",
                root: LayoutPaneTemplate(tabs: [LayoutTabTemplate()])
            )
        )

        let preset = try XCTUnwrap(layoutStore.preset(named: "agent-copy"))
        XCTAssertEqual(preset.name, "Agent Review")
    }

    func testLayoutPresetStoreRenameMovesCustomPresetFile() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let layoutStore = LayoutPresetStore(paths: harness.paths)
        try layoutStore.saveCustomPreset(
            LayoutPreset(
                id: "agent-copy",
                name: "Agent Copy",
                root: LayoutPaneTemplate(tabs: [LayoutTabTemplate()])
            )
        )

        let renamed = try layoutStore.renameCustomPreset(
            LayoutPreset(
                id: "agent-copy",
                name: "Agent Review",
                root: LayoutPaneTemplate(tabs: [LayoutTabTemplate()])
            ),
            previousID: "agent-copy"
        )

        XCTAssertEqual(renamed.id, "agent-review")
        XCTAssertEqual(renamed.name, "Agent Review")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layoutStore.layoutsDirectoryURL().appending(path: "agent-copy.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layoutStore.layoutsDirectoryURL().appending(path: "agent-review.json").path
            )
        )
    }

    func testRenameSessionKeepsSessionRootAndEnsuresUniqueName() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        _ = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "review", layoutName: nil)

        let renamed = try await store.renameSession(token: bundle.session.id, name: "dev")

        XCTAssertEqual(renamed.session.name, "dev-2")
        XCTAssertEqual(renamed.session.slug, "dev-2")
        XCTAssertEqual(renamed.session.sessionRootPath, bundle.session.sessionRootPath)
    }

    func testCloseSessionCanBeReopenedFromCheckpointedState() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let tab = try XCTUnwrap(bundle.tabs.first)

        try await store.checkpointTab(
            rawID: tab.rawID,
            title: "npm test",
            cwd: alphaURL.path,
            scrollback: "prompt> pwd\n\(alphaURL.path)\n",
            updateScrollback: true
        )

        let closed = try await store.closeSession(token: bundle.session.id)
        XCTAssertEqual(closed.session.status, .closed)
        XCTAssertNotNil(closed.session.closedAt)

        let reopened = try await store.activateSession(token: bundle.session.id)
        XCTAssertTrue(reopened.wasRestored)
        XCTAssertEqual(reopened.bundle.session.status, .active)
        XCTAssertNil(reopened.bundle.session.closedAt)
        XCTAssertEqual(reopened.bundle.tabs.first?.title, "npm test")
    }

    func testApplyLayoutReplacesExistingPaneTreeAndUpdatesLayoutName() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let originalTabIDs = Set(bundle.tabs.map(\.rawID))

        let updated = try await store.applyLayout(toSession: bundle.session.id, layoutName: "dev")

        XCTAssertEqual(updated.session.layoutName, "dev")
        XCTAssertEqual(updated.panes.count, 3)
        XCTAssertEqual(updated.tabs.count, 2)
        XCTAssertTrue(originalTabIDs.isDisjoint(with: Set(updated.tabs.map(\.rawID))))
    }

    func testSaveCurrentLayoutCapturesCurrentPaneTree() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)
        let split = try await store.splitPane(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            direction: .right,
            sourceTabRawID: sourceTab.rawID
        )
        let clonedPane = try XCTUnwrap(split.panes.first(where: { $0.rawID != sourcePane.rawID && $0.parentPaneID != nil }))
        let withSecondTab = try await store.createTab(sessionToken: split.session.id, paneRawID: clonedPane.rawID, sourceTabRawID: nil)

        let preset = try await store.saveCurrentLayout(sessionToken: withSecondTab.session.id, name: "Captured Layout")
        let layoutStore = LayoutPresetStore(paths: harness.paths)
        let saved = try XCTUnwrap(layoutStore.preset(named: preset.id))

        XCTAssertEqual(saved.name, "Captured Layout")
        XCTAssertEqual(saved.leafPaneCount, 2)
        XCTAssertEqual(saved.tabTemplateCount, 3)
        XCTAssertEqual(saved.root.splitDirection, .right)
    }

    func testCreateTrySessionUsesProvidedInitialSessionName() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let store = try WorkspaceStore(paths: harness.paths)
        let bundle = try await store.createTrySession(name: "sheet-flow", sessionName: "bootstrap", layoutName: "single")

        XCTAssertEqual(bundle.workspace.name, bundle.projects.first?.name)
        XCTAssertEqual(bundle.session.name, "bootstrap")
        XCTAssertEqual(bundle.session.layoutName, "single")
        XCTAssertEqual(bundle.projects.first?.kind, .try)
    }

    func testSessionRelaunchRestoreUsesCheckpointedTerminalState() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let tab = try XCTUnwrap(bundle.tabs.first)

        let restoredCWD = alphaURL.appendingPathComponent("nested", isDirectory: true).path
        let scrollback = "prompt> ls\nREADME.md\n"
        try await store.checkpointTab(
            rawID: tab.rawID,
            title: "npm test",
            cwd: restoredCWD,
            scrollback: scrollback,
            updateScrollback: true
        )
        try await store.prepareForAppLaunch()

        let activation = try await store.activateSession(token: bundle.session.id)
        let restoredTab = try XCTUnwrap(activation.bundle.tabs.first)
        let replayEnvironment = ShuttleScrollbackReplayStore.replayEnvironment(
            forTabRawID: tab.rawID,
            paths: harness.paths
        )
        let replayPath = try XCTUnwrap(replayEnvironment[ShuttleScrollbackReplayStore.environmentKey])
        let replayContents = try String(contentsOfFile: replayPath, encoding: .utf8)

        XCTAssertTrue(activation.wasRestored)
        XCTAssertEqual(activation.bundle.session.status, .active)
        XCTAssertEqual(restoredTab.title, "npm test")
        XCTAssertEqual(restoredTab.cwd, restoredCWD)
        XCTAssertEqual(restoredTab.runtimeStatus, .idle)
        XCTAssertEqual(replayContents, scrollback)
    }

    func testSplitPaneCreatesParentContainerAndClonedTab() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)

        let updated = try await store.splitPane(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            direction: .right,
            sourceTabRawID: sourceTab.rawID
        )

        XCTAssertEqual(updated.tabs.count, 2)
        XCTAssertEqual(updated.panes.count, 3)

        let rootPanes = updated.panes.filter { $0.parentPaneID == nil }
        XCTAssertEqual(rootPanes.count, 1)
        let splitRoot = try XCTUnwrap(rootPanes.first)
        XCTAssertEqual(splitRoot.splitDirection, .right)
        XCTAssertEqual(try XCTUnwrap(splitRoot.ratio), 0.5, accuracy: 0.0001)

        let childPanes = updated.panes
            .filter { $0.parentPaneID == splitRoot.rawID }
            .sorted {
                if $0.positionIndex == $1.positionIndex {
                    return $0.rawID < $1.rawID
                }
                return $0.positionIndex < $1.positionIndex
            }
        XCTAssertEqual(childPanes.count, 2)
        XCTAssertEqual(childPanes.map(\.positionIndex), [0, 1])
        XCTAssertTrue(childPanes.contains(where: { $0.rawID == sourcePane.rawID }))

        let clonedPane = try XCTUnwrap(childPanes.first(where: { $0.rawID != sourcePane.rawID }))
        let clonedTab = try XCTUnwrap(updated.tabs.first(where: { $0.paneID == clonedPane.rawID }))
        XCTAssertEqual(clonedTab.cwd, sourceTab.cwd)
        XCTAssertEqual(clonedTab.projectID, sourceTab.projectID)
        XCTAssertNil(clonedTab.command)
        XCTAssertEqual(clonedTab.runtimeStatus, .placeholder)
    }

    func testUncheckpointedSessionDoesNotClaimRestoreBannerOnLaunch() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        try await store.prepareForAppLaunch()

        let activation = try await store.activateSession(token: bundle.session.id)
        XCTAssertFalse(activation.wasRestored)
        XCTAssertEqual(activation.bundle.session.status, .active)
    }

    func testResizePanePersistsUpdatedSplitRatio() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)

        let splitBundle = try await store.splitPane(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            direction: .right,
            sourceTabRawID: sourceTab.rawID
        )
        let splitRoot = try XCTUnwrap(splitBundle.panes.first(where: { $0.parentPaneID == nil }))

        try await store.resizePane(sessionToken: bundle.session.id, paneRawID: splitRoot.rawID, ratio: 0.72)
        let refreshed = try await store.sessionBundle(token: bundle.session.id)
        let refreshedRoot = try XCTUnwrap(refreshed.panes.first(where: { $0.rawID == splitRoot.rawID }))

        XCTAssertEqual(try XCTUnwrap(refreshedRoot.ratio), 0.72, accuracy: 0.0001)
    }

    func testCreateTabAddsAnotherTabToSamePane() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)

        let updated = try await store.createTab(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            sourceTabRawID: sourceTab.rawID
        )

        let paneTabs = updated.tabs
            .filter { $0.paneID == sourcePane.rawID }
            .sorted { $0.positionIndex < $1.positionIndex }
        XCTAssertEqual(paneTabs.count, 2)
        XCTAssertEqual(paneTabs.map(\.positionIndex), [0, 1])
        XCTAssertEqual(paneTabs[1].cwd, sourceTab.cwd)
        XCTAssertEqual(paneTabs[1].projectID, sourceTab.projectID)
    }

    func testCloseTabRemovesTabFromPaneAndReindexes() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)
        let withSecondTab = try await store.createTab(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            sourceTabRawID: sourceTab.rawID
        )
        let secondTab = try XCTUnwrap(withSecondTab.tabs.first(where: { $0.rawID != sourceTab.rawID }))

        let updated = try await store.closeTab(sessionToken: bundle.session.id, tabRawID: sourceTab.rawID)
        let paneTabs = updated.tabs.filter { $0.paneID == sourcePane.rawID }

        XCTAssertEqual(paneTabs.count, 1)
        XCTAssertEqual(paneTabs.first?.rawID, secondTab.rawID)
        XCTAssertEqual(paneTabs.first?.positionIndex, 0)
    }

    func testCloseLastTabInPaneRemovesPaneAndCollapsesSplit() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)

        let splitBundle = try await store.splitPane(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            direction: .right,
            sourceTabRawID: sourceTab.rawID
        )
        let clonedTab = try XCTUnwrap(splitBundle.tabs.first(where: { $0.rawID != sourceTab.rawID }))

        let updated = try await store.closeTab(sessionToken: bundle.session.id, tabRawID: clonedTab.rawID)

        XCTAssertEqual(updated.tabs.count, 1)
        XCTAssertEqual(updated.panes.count, 1)
        XCTAssertEqual(updated.tabs.first?.rawID, sourceTab.rawID)
        XCTAssertEqual(updated.tabs.first?.paneID, updated.panes.first?.rawID)
    }

    func testCloseFinalTabLeavesEmptyPaneAndNewTabCanReopenIt() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sessionProject = try XCTUnwrap(bundle.sessionProjects.first)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let sourceTab = try XCTUnwrap(bundle.tabs.first)

        let emptied = try await store.closeTab(sessionToken: bundle.session.id, tabRawID: sourceTab.rawID)
        XCTAssertEqual(emptied.panes.count, 1)
        XCTAssertTrue(emptied.tabs.isEmpty)
        XCTAssertEqual(emptied.panes.first?.rawID, sourcePane.rawID)

        let reopened = try await store.createTab(sessionToken: bundle.session.id, paneRawID: sourcePane.rawID, sourceTabRawID: nil)
        XCTAssertEqual(reopened.tabs.count, 1)
        XCTAssertEqual(reopened.tabs.first?.paneID, sourcePane.rawID)
        XCTAssertEqual(reopened.tabs.first?.cwd, sessionProject.checkoutPath)
        XCTAssertEqual(reopened.tabs.first?.projectID, sessionProject.projectID)
    }

    func testSessionSnapshotStoreRoundTripsSelectedSessionBundle() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)
        let sourcePane = try XCTUnwrap(bundle.panes.first)
        let firstTab = try XCTUnwrap(bundle.tabs.first)
        let withSecondTab = try await store.createTab(
            sessionToken: bundle.session.id,
            paneRawID: sourcePane.rawID,
            sourceTabRawID: firstTab.rawID
        )
        let secondTab = try XCTUnwrap(withSecondTab.tabs.first(where: { $0.rawID != firstTab.rawID }))

        let snapshot = ShuttleAppSessionSnapshot(
            savedAt: Date(),
            selectedWorkspaceID: withSecondTab.workspace.rawID,
            selectedSessionID: withSecondTab.session.rawID,
            selectedSession: ShuttleSelectedSessionSnapshot(
                bundle: withSecondTab,
                tabSnapshots: [
                    ShuttleRestorableTabSnapshot(
                        tabRawID: firstTab.rawID,
                        title: "npm test",
                        cwd: alphaURL.path,
                        scrollback: "prompt> ls\nREADME.md\n"
                    ),
                    ShuttleRestorableTabSnapshot(
                        tabRawID: secondTab.rawID,
                        title: secondTab.title,
                        cwd: secondTab.cwd,
                        scrollback: nil
                    )
                ],
                paneSelections: [
                    ShuttlePaneSelectionSnapshot(paneRawID: sourcePane.rawID, activeTabRawID: secondTab.rawID)
                ],
                focusedTabRawID: secondTab.rawID
            )
        )

        XCTAssertTrue(ShuttleSessionSnapshotStore.save(snapshot, paths: harness.paths))
        let loaded = try XCTUnwrap(ShuttleSessionSnapshotStore.load(paths: harness.paths))
        let restored = try XCTUnwrap(loaded.selectedSession).applying(to: withSecondTab)

        XCTAssertEqual(loaded.selectedSessionID, withSecondTab.session.rawID)
        XCTAssertEqual(restored.tabs.first(where: { $0.rawID == firstTab.rawID })?.title, "npm test")
        XCTAssertEqual(restored.tabs.first(where: { $0.rawID == firstTab.rawID })?.cwd, alphaURL.path)
        XCTAssertEqual(loaded.selectedSession?.focusedTabRawID, secondTab.rawID)
        XCTAssertEqual(loaded.selectedSession?.paneSelections, [
            ShuttlePaneSelectionSnapshot(paneRawID: sourcePane.rawID, activeTabRawID: secondTab.rawID)
        ])
        XCTAssertEqual(loaded.selectedSession?.tabSnapshot(rawID: firstTab.rawID)?.scrollback, "prompt> ls\nREADME.md\n")
    }

    func testListWorkspacesReturnsProjectsAndSessions() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let alphaURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        let betaURL = harness.projectsRootURL.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        _ = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil)

        let workspaces = try await store.listWorkspaces()
        let alpha = try XCTUnwrap(workspaces.first(where: { $0.workspace.name == "alpha" }))

        XCTAssertEqual(alpha.projects.map(\.name), ["alpha"])
        XCTAssertEqual(alpha.workspace.projectIDs, alpha.projects.map(\.rawID))
        XCTAssertEqual(alpha.sessions.count, 1)
        XCTAssertEqual(alpha.sessions.first?.name, "dev")
    }

    func testSingleProjectGitSessionCanSeedAgentGuideAtSessionRoot() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.writeConfig(
            sessionRoot: harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path,
            triesRoot: harness.rootURL.appendingPathComponent("tries", isDirectory: true).path,
            projectRoots: [harness.projectsRootURL.path]
        )

        let repoURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try harness.git(["init"], in: repoURL.path)
        try harness.git(["checkout", "-b", "main"], in: repoURL.path)
        try harness.git(["config", "user.email", "shuttle-tests@example.com"], in: repoURL.path)
        try harness.git(["config", "user.name", "Shuttle Tests"], in: repoURL.path)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try harness.git(["add", "."], in: repoURL.path)
        try harness.git(["commit", "-m", "initial"], in: repoURL.path)

        let store = try WorkspaceStore(paths: harness.paths)
        _ = try await store.scanProjects()
        let bundle = try await store.createSession(workspaceToken: "alpha", name: "dev", layoutName: nil, seedAgentGuide: true)

        let guideURL = SessionAgentGuide.fileURL(for: bundle.session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: guideURL.path))

        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        XCTAssertTrue(guide.contains(repoURL.path))
        XCTAssertTrue(guide.contains("direct source checkout"))
        XCTAssertTrue(guide.contains("opens app terminals directly in that source checkout by default"))
        XCTAssertFalse(guide.contains("promote-project"))
    }

    func testSchemaV5MigratesToV7AndNormalizesLegacySessionCheckoutPaths() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let sessionRootURL = harness.rootURL.appendingPathComponent("session-root", isDirectory: true)
        let projectURL = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true)
        let legacyCheckoutURL = sessionRootURL.appendingPathComponent("alpha-link", isDirectory: false)
        try FileManager.default.createDirectory(at: sessionRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: legacyCheckoutURL.path, withDestinationPath: projectURL.path)

        func sqlLiteral(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        let now = sqlLiteral("2026-04-01T00:00:00Z")
        let bootstrap = try runProcess(
            "/usr/bin/env",
            arguments: [
                "sqlite3",
                harness.paths.databaseURL.path,
                """
                CREATE TABLE projects (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid TEXT NOT NULL UNIQUE,
                  name TEXT NOT NULL,
                  path TEXT NOT NULL UNIQUE,
                  kind TEXT NOT NULL,
                  vcs_kind TEXT NOT NULL,
                  default_branch TEXT,
                  default_workspace_id INTEGER,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE workspaces (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid TEXT NOT NULL UNIQUE,
                  name TEXT NOT NULL,
                  slug TEXT NOT NULL,
                  created_from TEXT NOT NULL,
                  is_default INTEGER NOT NULL,
                  source_project_id INTEGER,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE workspace_projects (
                  workspace_id INTEGER NOT NULL,
                  project_id INTEGER NOT NULL,
                  position_index INTEGER NOT NULL,
                  PRIMARY KEY (workspace_id, project_id)
                );
                CREATE TABLE sessions (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid TEXT NOT NULL UNIQUE,
                  workspace_id INTEGER NOT NULL,
                  session_number INTEGER NOT NULL,
                  name TEXT NOT NULL,
                  slug TEXT NOT NULL,
                  status TEXT NOT NULL,
                  session_root_path TEXT NOT NULL,
                  layout_name TEXT,
                  created_at TEXT NOT NULL,
                  last_active_at TEXT NOT NULL,
                  closed_at TEXT
                );
                CREATE TABLE session_projects (
                  session_id INTEGER NOT NULL,
                  project_id INTEGER NOT NULL,
                  checkout_type TEXT NOT NULL,
                  checkout_path TEXT NOT NULL,
                  base_branch TEXT,
                  created_branch_name TEXT,
                  merge_status TEXT NOT NULL,
                  dirty INTEGER NOT NULL,
                  metadata_json TEXT,
                  PRIMARY KEY (session_id, project_id)
                );
                CREATE TABLE panes (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id INTEGER NOT NULL,
                  pane_number INTEGER NOT NULL,
                  parent_pane_id INTEGER,
                  split_direction TEXT,
                  ratio REAL,
                  position_index INTEGER NOT NULL
                );
                CREATE TABLE tabs (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id INTEGER NOT NULL,
                  pane_id INTEGER NOT NULL,
                  tab_number INTEGER NOT NULL,
                  title TEXT NOT NULL,
                  cwd TEXT NOT NULL,
                  project_id INTEGER,
                  command TEXT,
                  env_json TEXT,
                  runtime_status TEXT NOT NULL,
                  position_index INTEGER NOT NULL
                );
                INSERT INTO projects (id, uuid, name, path, kind, vcs_kind, default_branch, default_workspace_id, created_at, updated_at)
                VALUES (1, '11111111-1111-1111-1111-111111111111', 'alpha', \(sqlLiteral(projectURL.path)), 'normal', 'git', 'main', 1, \(now), \(now));
                INSERT INTO workspaces (id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at)
                VALUES (1, '22222222-2222-2222-2222-222222222222', 'alpha', 'alpha', 'auto', 1, 1, \(now), \(now));
                INSERT INTO workspace_projects (workspace_id, project_id, position_index)
                VALUES (1, 1, 0);
                INSERT INTO sessions (id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at)
                VALUES (1, '33333333-3333-3333-3333-333333333333', 1, 1, 'dev', 'dev', 'active', \(sqlLiteral(sessionRootURL.path)), NULL, \(now), \(now), NULL);
                INSERT INTO session_projects (session_id, project_id, checkout_type, checkout_path, base_branch, created_branch_name, merge_status, dirty, metadata_json)
                VALUES (1, 1, 'direct', \(sqlLiteral(legacyCheckoutURL.path)), 'main', NULL, 'unknown', 0, NULL);
                PRAGMA user_version = 5;
                """
            ]
        )
        XCTAssertTrue(bootstrap.succeeded, bootstrap.stderr)

        _ = try PersistenceStore(paths: harness.paths)

        let inspection = try runProcess(
            "/usr/bin/env",
            arguments: [
                "sqlite3",
                "-noheader",
                harness.paths.databaseURL.path,
                """
                SELECT group_concat(name, ',') FROM pragma_table_info('projects');
                SELECT group_concat(name, ',') FROM pragma_table_info('session_projects');
                SELECT checkout_path FROM session_projects;
                PRAGMA user_version;
                """
            ]
        )
        XCTAssertTrue(inspection.succeeded, inspection.stderr)

        let lines = inspection.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "id,uuid,name,path,kind,default_workspace_id,created_at,updated_at")
        XCTAssertEqual(lines[1], "session_id,project_id,checkout_type,checkout_path,metadata_json")
        XCTAssertEqual(lines[2], projectURL.path)
        XCTAssertEqual(lines[3], "7")
    }

    func testSchemaV6MigratesToV7WithTabAttentionColumns() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        func sqlLiteral(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        let now = sqlLiteral("2026-04-01T00:00:00Z")
        let sessionRoot = harness.rootURL.appendingPathComponent("session-root", isDirectory: true).path
        let projectPath = harness.projectsRootURL.appendingPathComponent("alpha", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        let bootstrap = try runProcess(
            "/usr/bin/env",
            arguments: [
                "sqlite3",
                harness.paths.databaseURL.path,
                """
                CREATE TABLE projects (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid TEXT NOT NULL UNIQUE,
                  name TEXT NOT NULL,
                  path TEXT NOT NULL UNIQUE,
                  kind TEXT NOT NULL,
                  default_workspace_id INTEGER,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE workspaces (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid TEXT NOT NULL UNIQUE,
                  name TEXT NOT NULL,
                  slug TEXT NOT NULL,
                  created_from TEXT NOT NULL,
                  is_default INTEGER NOT NULL,
                  source_project_id INTEGER,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE workspace_projects (
                  workspace_id INTEGER NOT NULL,
                  project_id INTEGER NOT NULL,
                  position_index INTEGER NOT NULL,
                  PRIMARY KEY (workspace_id, project_id)
                );
                CREATE TABLE sessions (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid TEXT NOT NULL UNIQUE,
                  workspace_id INTEGER NOT NULL,
                  session_number INTEGER NOT NULL,
                  name TEXT NOT NULL,
                  slug TEXT NOT NULL,
                  status TEXT NOT NULL,
                  session_root_path TEXT NOT NULL,
                  layout_name TEXT,
                  created_at TEXT NOT NULL,
                  last_active_at TEXT NOT NULL,
                  closed_at TEXT
                );
                CREATE TABLE session_projects (
                  session_id INTEGER NOT NULL,
                  project_id INTEGER NOT NULL,
                  checkout_type TEXT NOT NULL,
                  checkout_path TEXT NOT NULL,
                  metadata_json TEXT,
                  PRIMARY KEY (session_id, project_id)
                );
                CREATE TABLE panes (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id INTEGER NOT NULL,
                  pane_number INTEGER NOT NULL,
                  parent_pane_id INTEGER,
                  split_direction TEXT,
                  ratio REAL,
                  position_index INTEGER NOT NULL
                );
                CREATE TABLE tabs (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id INTEGER NOT NULL,
                  pane_id INTEGER NOT NULL,
                  tab_number INTEGER NOT NULL,
                  title TEXT NOT NULL,
                  cwd TEXT NOT NULL,
                  project_id INTEGER,
                  command TEXT,
                  env_json TEXT,
                  runtime_status TEXT NOT NULL,
                  position_index INTEGER NOT NULL
                );
                INSERT INTO projects (id, uuid, name, path, kind, default_workspace_id, created_at, updated_at)
                VALUES (1, '11111111-1111-1111-1111-111111111111', 'alpha', \(sqlLiteral(projectPath)), 'normal', 1, \(now), \(now));
                INSERT INTO workspaces (id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at)
                VALUES (1, '22222222-2222-2222-2222-222222222222', 'alpha', 'alpha', 'auto', 1, 1, \(now), \(now));
                INSERT INTO workspace_projects (workspace_id, project_id, position_index)
                VALUES (1, 1, 0);
                INSERT INTO sessions (id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at)
                VALUES (1, '33333333-3333-3333-3333-333333333333', 1, 1, 'dev', 'dev', 'active', \(sqlLiteral(sessionRoot)), NULL, \(now), \(now), NULL);
                INSERT INTO session_projects (session_id, project_id, checkout_type, checkout_path, metadata_json)
                VALUES (1, 1, 'direct', \(sqlLiteral(projectPath)), NULL);
                INSERT INTO panes (id, session_id, pane_number, parent_pane_id, split_direction, ratio, position_index)
                VALUES (1, 1, 1, NULL, NULL, NULL, 0);
                INSERT INTO tabs (id, session_id, pane_id, tab_number, title, cwd, project_id, command, env_json, runtime_status, position_index)
                VALUES (1, 1, 1, 1, 'shell', \(sqlLiteral(projectPath)), 1, NULL, NULL, 'idle', 0);
                PRAGMA user_version = 6;
                """
            ]
        )
        XCTAssertTrue(bootstrap.succeeded, bootstrap.stderr)

        let persistence = try PersistenceStore(paths: harness.paths)

        // Verify the migration added the new columns
        let inspection = try runProcess(
            "/usr/bin/env",
            arguments: [
                "sqlite3",
                "-noheader",
                harness.paths.databaseURL.path,
                """
                SELECT group_concat(name, ',') FROM pragma_table_info('tabs');
                PRAGMA user_version;
                """
            ]
        )
        XCTAssertTrue(inspection.succeeded, inspection.stderr)

        let lines = inspection.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("needs_attention"), "Expected needs_attention column in tabs: \(lines[0])")
        XCTAssertTrue(lines[0].contains("attention_message"), "Expected attention_message column in tabs: \(lines[0])")
        XCTAssertEqual(lines[1], "7")

        // Verify existing tabs decode correctly with the default attention state
        let tabs = try persistence.listTabs(sessionID: 1)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertFalse(tabs[0].needsAttention)
        XCTAssertNil(tabs[0].attentionMessage)

        // Verify mark/clear attention round-trips
        try persistence.markTabAttention(tabID: 1, message: "Build complete")
        let marked = try persistence.listTabs(sessionID: 1)
        XCTAssertTrue(marked[0].needsAttention)
        XCTAssertEqual(marked[0].attentionMessage, "Build complete")

        try persistence.clearTabAttention(tabID: 1)
        let cleared = try persistence.listTabs(sessionID: 1)
        XCTAssertFalse(cleared[0].needsAttention)
        XCTAssertNil(cleared[0].attentionMessage)
    }

    func testRunProcessDrainsLargeOutputWithoutHanging() throws {
        let result = try runProcess(
            "/bin/sh",
            arguments: [
                "-c",
                "{ /usr/bin/yes stdout | /usr/bin/head -c 131072; } && { /usr/bin/yes stderr | /usr/bin/head -c 131072; } 1>&2"
            ]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThanOrEqual(result.stdout.utf8.count, 131072)
        XCTAssertGreaterThanOrEqual(result.stderr.utf8.count, 131072)
        XCTAssertTrue(result.stdout.hasPrefix("stdout"))
        XCTAssertTrue(result.stderr.hasPrefix("stderr"))
    }

    func testReplayEnvironmentCreatesTempReplayFile() throws {
        let environment = ShuttleScrollbackReplayStore.replayEnvironment(for: "prompt> ls\nREADME.md\n")
        let replayPath = try XCTUnwrap(environment[ShuttleScrollbackReplayStore.environmentKey])
        let contents = try String(contentsOfFile: replayPath, encoding: .utf8)
        XCTAssertEqual(contents, "prompt> ls\nREADME.md\n")
    }

    func testShuttlePathsUseProfileSpecificDefaults() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeURL.appending(path: "Library/Application Support", directoryHint: .isDirectory)

        let prodPaths = ShuttlePaths(fileManager: fileManager, profile: .prod)
        XCTAssertEqual(prodPaths.profile, .prod)
        XCTAssertEqual(prodPaths.configDirectoryURL.path, homeURL.appending(path: ".config/shuttle", directoryHint: .isDirectory).path)
        XCTAssertEqual(prodPaths.appSupportURL.path, appSupportBase.appending(path: "Shuttle", directoryHint: .isDirectory).path)

        let devPaths = ShuttlePaths(fileManager: fileManager, profile: .dev)
        XCTAssertEqual(devPaths.profile, .dev)
        XCTAssertEqual(devPaths.configDirectoryURL.path, homeURL.appending(path: ".config/shuttle-dev", directoryHint: .isDirectory).path)
        XCTAssertEqual(devPaths.appSupportURL.path, appSupportBase.appending(path: "Shuttle Dev", directoryHint: .isDirectory).path)
    }

    func testDevDefaultConfigUsesSeparateSessionRootButSharedTriesRoot() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectoryURL = rootURL.appendingPathComponent("config", isDirectory: true)
        let appSupportURL = rootURL.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let paths = ShuttlePaths(profile: .dev, configDirectoryURL: configDirectoryURL, appSupportURL: appSupportURL)
        let manager = ConfigManager(paths: paths)
        let sample = manager.sampleConfigText()
        let config = try JSONDecoder().decode(ShuttleConfig.self, from: Data(sample.utf8))

        XCTAssertEqual(config.sessionRoot, "~/Workspaces-Dev")
        XCTAssertEqual(config.triesRoot, "~/src/tries")
        XCTAssertEqual(config.projectRoots, ["~/src/tries"])
    }

    func testBestMatchingPathRootPrefersMostSpecificRoot() {
        let roots = [
            "/Users/test/src",
            "/Users/test/src/github.com",
            "/Users/test/src/github.com/shopify"
        ]

        XCTAssertEqual(
            bestMatchingPathRoot(for: "/Users/test/src/github.com/shopify/shuttle", roots: roots),
            "/Users/test/src/github.com/shopify"
        )
    }

    func testBestMatchingPathRootReturnsNilWhenPathDoesNotMatchAnyRoot() {
        XCTAssertNil(
            bestMatchingPathRoot(
                for: "/Users/test/elsewhere/project",
                roots: ["/Users/test/src", "/Users/test/tries"]
            )
        )
    }
}


private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private struct TestHarness {
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

    func writeConfig(
        sessionRoot: String,
        triesRoot: String,
        projectRoots: [String]
    ) throws {
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

    func git(_ arguments: [String], in directory: String) throws {
        let result = try runProcess("/usr/bin/env", arguments: ["git"] + arguments, currentDirectoryPath: directory)
        if !result.succeeded {
            throw ShuttleError.io(result.stderr.isEmpty ? "git command failed" : result.stderr)
        }
    }
}
