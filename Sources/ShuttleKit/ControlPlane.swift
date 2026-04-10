import Foundation
import Darwin

public struct ShuttlePaneDetails: Hashable, Sendable, Codable {
    public var session: Session
    public var workspace: Workspace
    public var pane: Pane
    public var tabs: [Tab]

    public init(session: Session, workspace: Workspace, pane: Pane, tabs: [Tab]) {
        self.session = session
        self.workspace = workspace
        self.pane = pane
        self.tabs = tabs
    }
}

public struct ShuttleControlPong: Hashable, Sendable, Codable {
    public var message: String
    public var profile: ShuttleProfile
    public var socketPath: String
    public var processID: Int32

    public init(message: String = "pong", profile: ShuttleProfile, socketPath: String, processID: Int32) {
        self.message = message
        self.profile = profile
        self.socketPath = socketPath
        self.processID = processID
    }
}

public struct ShuttleControlCapabilities: Hashable, Sendable, Codable {
    public var protocolVersion: Int
    public var profile: ShuttleProfile
    public var socketPath: String
    public var supportedCommands: [String]

    public init(protocolVersion: Int, profile: ShuttleProfile, socketPath: String, supportedCommands: [String]) {
        self.protocolVersion = protocolVersion
        self.profile = profile
        self.socketPath = socketPath
        self.supportedCommands = supportedCommands
    }
}

public enum ShuttleControlCommand: Hashable, Sendable, Codable {
    case ping
    case capabilities
    case workspaceOpen(workspaceToken: String)
    case sessionBundle(sessionToken: String)
    case sessionOpen(sessionToken: String)
    case sessionNew(workspaceToken: String, name: String?, layoutName: String?)
    case sessionEnsure(workspaceToken: String, name: String, layoutName: String?)
    case sessionRename(sessionToken: String, name: String)
    case sessionClose(sessionToken: String)
    case sessionEnsureClosed(sessionToken: String)
    case layoutApply(sessionToken: String, layoutName: String)
    case layoutEnsureApplied(sessionToken: String, layoutName: String)
    case layoutSaveCurrent(sessionToken: String, name: String, description: String?)
    case paneSplit(sessionToken: String, paneToken: String, direction: SplitDirection, sourceTabToken: String?)
    case paneResize(sessionToken: String, paneToken: String, ratio: Double)
    case tabNew(sessionToken: String, paneToken: String, sourceTabToken: String?)
    case tabClose(sessionToken: String, tabToken: String)
    case tabSend(sessionToken: String, tabToken: String, text: String, submit: Bool)
    case tabRead(sessionToken: String, tabToken: String, mode: ShuttleTabReadMode, maxLines: Int, afterCursorToken: String?)
    case tabWait(sessionToken: String, tabToken: String, text: String, mode: ShuttleTabReadMode, maxLines: Int, timeoutMilliseconds: Int, afterCursorToken: String?)
    case tabMarkAttention(sessionToken: String, tabToken: String, message: String?)
    case tabClearAttention(sessionToken: String, tabToken: String)

    public var name: String {
        switch self {
        case .ping:
            return "ping"
        case .capabilities:
            return "capabilities"
        case .workspaceOpen:
            return "workspace.open"
        case .sessionBundle:
            return "session.bundle"
        case .sessionOpen:
            return "session.open"
        case .sessionNew:
            return "session.new"
        case .sessionEnsure:
            return "session.ensure"
        case .sessionRename:
            return "session.rename"
        case .sessionClose:
            return "session.close"
        case .sessionEnsureClosed:
            return "session.ensure-closed"
        case .layoutApply:
            return "layout.apply"
        case .layoutEnsureApplied:
            return "layout.ensure-applied"
        case .layoutSaveCurrent:
            return "layout.save-current"
        case .paneSplit:
            return "pane.split"
        case .paneResize:
            return "pane.resize"
        case .tabNew:
            return "tab.new"
        case .tabClose:
            return "tab.close"
        case .tabSend:
            return "tab.send"
        case .tabRead:
            return "tab.read"
        case .tabWait:
            return "tab.wait"
        case .tabMarkAttention:
            return "tab.mark_attention"
        case .tabClearAttention:
            return "tab.clear_attention"
        }
    }

    public var isMutation: Bool {
        switch self {
        case .ping, .capabilities, .sessionBundle, .tabRead, .tabWait:
            return false
        case .workspaceOpen,
             .sessionOpen,
             .sessionNew,
             .sessionEnsure,
             .sessionRename,
             .sessionClose,
             .sessionEnsureClosed,
             .layoutApply,
             .layoutEnsureApplied,
             .layoutSaveCurrent,
             .paneSplit,
             .paneResize,
             .tabNew,
             .tabClose,
             .tabSend,
             .tabMarkAttention,
             .tabClearAttention:
            return true
        }
    }

    public static var supportedCommandNames: [String] {
        [
            ShuttleControlCommand.ping.name,
            ShuttleControlCommand.capabilities.name,
            ShuttleControlCommand.workspaceOpen(workspaceToken: "").name,
            ShuttleControlCommand.sessionBundle(sessionToken: "").name,
            ShuttleControlCommand.sessionOpen(sessionToken: "").name,
            ShuttleControlCommand.sessionNew(workspaceToken: "", name: nil, layoutName: nil).name,
            ShuttleControlCommand.sessionEnsure(workspaceToken: "", name: "", layoutName: nil).name,
            ShuttleControlCommand.sessionRename(sessionToken: "", name: "").name,
            ShuttleControlCommand.sessionClose(sessionToken: "").name,
            ShuttleControlCommand.sessionEnsureClosed(sessionToken: "").name,
            ShuttleControlCommand.layoutApply(sessionToken: "", layoutName: "").name,
            ShuttleControlCommand.layoutEnsureApplied(sessionToken: "", layoutName: "").name,
            ShuttleControlCommand.layoutSaveCurrent(sessionToken: "", name: "", description: nil).name,
            ShuttleControlCommand.paneSplit(sessionToken: "", paneToken: "", direction: .right, sourceTabToken: nil).name,
            ShuttleControlCommand.paneResize(sessionToken: "", paneToken: "", ratio: 0.5).name,
            ShuttleControlCommand.tabNew(sessionToken: "", paneToken: "", sourceTabToken: nil).name,
            ShuttleControlCommand.tabClose(sessionToken: "", tabToken: "").name,
            ShuttleControlCommand.tabSend(sessionToken: "", tabToken: "", text: "", submit: false).name,
            ShuttleControlCommand.tabRead(sessionToken: "", tabToken: "", mode: .scrollback, maxLines: 200, afterCursorToken: nil).name,
            ShuttleControlCommand.tabWait(sessionToken: "", tabToken: "", text: "", mode: .scrollback, maxLines: 200, timeoutMilliseconds: 30_000, afterCursorToken: nil).name,
            ShuttleControlCommand.tabMarkAttention(sessionToken: "", tabToken: "", message: nil).name,
            ShuttleControlCommand.tabClearAttention(sessionToken: "", tabToken: "").name,
        ]
    }
}

public enum ShuttleControlValue: Hashable, Sendable, Codable {
    case pong(ShuttleControlPong)
    case capabilities(ShuttleControlCapabilities)
    case workspaceDetails(WorkspaceDetails)
    case sessionActivation(SessionActivation)
    case sessionBundle(SessionBundle)
    case sessionMutationResult(ShuttleSessionMutationResult)
    case layoutPreset(LayoutPreset)
    case layoutMutationResult(ShuttleLayoutMutationResult)
    case tabSendResult(ShuttleTabSendResult)
    case tabReadResult(ShuttleTabReadResult)
}

public struct ShuttleControlRemoteError: Hashable, Sendable, Codable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ShuttleControlRequest: Hashable, Sendable, Codable {
    public static let protocolVersion = 1

    public var protocolVersion: Int
    public var requestID: UUID
    public var command: ShuttleControlCommand

    public init(command: ShuttleControlCommand, requestID: UUID = UUID(), protocolVersion: Int = ShuttleControlRequest.protocolVersion) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
    }
}

public struct ShuttleControlResponse: Hashable, Sendable, Codable {
    public var protocolVersion: Int
    public var requestID: UUID
    public var value: ShuttleControlValue?
    public var error: ShuttleControlRemoteError?

    public init(
        protocolVersion: Int = ShuttleControlRequest.protocolVersion,
        requestID: UUID,
        value: ShuttleControlValue? = nil,
        error: ShuttleControlRemoteError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.value = value
        self.error = error
    }
}

public struct ShuttleControlCommandService: Sendable {
    public let store: WorkspaceStore
    public let paths: ShuttlePaths

    public init(store: WorkspaceStore) {
        self.store = store
        self.paths = store.paths
    }

    public func capabilities() -> ShuttleControlCapabilities {
        ShuttleControlCapabilities(
            protocolVersion: ShuttleControlRequest.protocolVersion,
            profile: paths.profile,
            socketPath: paths.controlSocketURL.path,
            supportedCommands: ShuttleControlCommand.supportedCommandNames
        )
    }

    public func execute(_ command: ShuttleControlCommand) async throws -> ShuttleControlValue {
        switch command {
        case .ping:
            return .pong(
                ShuttleControlPong(
                    profile: paths.profile,
                    socketPath: paths.controlSocketURL.path,
                    processID: ProcessInfo.processInfo.processIdentifier
                )
            )
        case .capabilities:
            return .capabilities(capabilities())
        case .workspaceOpen(let workspaceToken):
            return .workspaceDetails(try await store.workspaceDetails(token: workspaceToken))
        case .sessionBundle(let sessionToken):
            return .sessionBundle(try await store.sessionBundle(token: sessionToken))
        case .sessionOpen(let sessionToken):
            return .sessionActivation(try await store.activateSession(token: sessionToken))
        case .sessionNew(let workspaceToken, let name, let layoutName):
            return .sessionBundle(try await store.createSession(workspaceToken: workspaceToken, name: name, layoutName: layoutName))
        case .sessionEnsure(let workspaceToken, let name, let layoutName):
            return .sessionMutationResult(
                try await store.ensureSession(workspaceToken: workspaceToken, name: name, layoutName: layoutName)
            )
        case .sessionRename(let sessionToken, let name):
            return .sessionBundle(try await store.renameSession(token: sessionToken, name: name))
        case .sessionClose(let sessionToken):
            return .sessionBundle(try await store.closeSession(token: sessionToken))
        case .sessionEnsureClosed(let sessionToken):
            return .sessionMutationResult(try await store.ensureSessionClosed(token: sessionToken))
        case .layoutApply(let sessionToken, let layoutName):
            return .sessionBundle(try await store.applyLayout(toSession: sessionToken, layoutName: layoutName))
        case .layoutEnsureApplied(let sessionToken, let layoutName):
            return .layoutMutationResult(
                try await store.ensureLayoutApplied(sessionToken: sessionToken, layoutName: layoutName)
            )
        case .layoutSaveCurrent(let sessionToken, let name, let description):
            return .layoutPreset(try await store.saveCurrentLayout(sessionToken: sessionToken, name: name, description: description))
        case .paneSplit(let sessionToken, let paneToken, let direction, let sourceTabToken):
            let existing = try await store.sessionBundle(token: sessionToken)
            let pane = try Self.resolvePane(in: existing, token: paneToken)
            let sourceTabRawID = try sourceTabToken.map { try Self.resolveTab(in: existing, token: $0).rawID }
            return .sessionBundle(
                try await store.splitPane(
                    sessionToken: sessionToken,
                    paneRawID: pane.rawID,
                    direction: direction,
                    sourceTabRawID: sourceTabRawID
                )
            )
        case .paneResize(let sessionToken, let paneToken, let ratio):
            let existing = try await store.sessionBundle(token: sessionToken)
            let pane = try Self.resolvePane(in: existing, token: paneToken)
            try await store.resizePane(sessionToken: sessionToken, paneRawID: pane.rawID, ratio: ratio)
            return .sessionBundle(try await store.sessionBundle(token: sessionToken))
        case .tabNew(let sessionToken, let paneToken, let sourceTabToken):
            let existing = try await store.sessionBundle(token: sessionToken)
            let pane = try Self.resolvePane(in: existing, token: paneToken)
            let sourceTabRawID = try sourceTabToken.map { try Self.resolveTab(in: existing, token: $0).rawID }
            return .sessionBundle(
                try await store.createTab(
                    sessionToken: sessionToken,
                    paneRawID: pane.rawID,
                    sourceTabRawID: sourceTabRawID
                )
            )
        case .tabClose(let sessionToken, let tabToken):
            let existing = try await store.sessionBundle(token: sessionToken)
            let tab = try Self.resolveTab(in: existing, token: tabToken)
            return .sessionBundle(try await store.closeTab(sessionToken: sessionToken, tabRawID: tab.rawID))
        case .tabSend, .tabRead, .tabWait:
            throw ShuttleError.unsupported("Runtime tab send/read commands require the Shuttle app control plane")
        case .tabMarkAttention(let sessionToken, let tabToken, let message):
            let existing = try await store.sessionBundle(token: sessionToken)
            let tab = try Self.resolveTab(in: existing, token: tabToken)
            try await store.markTabAttention(sessionToken: sessionToken, tabRawID: tab.rawID, message: message)
            return .sessionBundle(try await store.sessionBundle(token: sessionToken))
        case .tabClearAttention(let sessionToken, let tabToken):
            let existing = try await store.sessionBundle(token: sessionToken)
            let tab = try Self.resolveTab(in: existing, token: tabToken)
            try await store.clearTabAttention(sessionToken: sessionToken, tabRawID: tab.rawID)
            return .sessionBundle(try await store.sessionBundle(token: sessionToken))
        }
    }

    public static func resolvePane(in bundle: SessionBundle, token: String) throws -> Pane {
        if let match = bundle.panes.first(where: { $0.id == token }) {
            return match
        }
        if let paneNumber = scopedOrdinal(token, prefix: "pane"),
           let match = bundle.panes.first(where: { $0.paneNumber == paneNumber }) {
            return match
        }
        throw ShuttleError.notFound(entity: "Pane", token: token)
    }

    public static func resolveTab(in bundle: SessionBundle, token: String) throws -> Tab {
        if let match = bundle.tabs.first(where: { $0.id == token }) {
            return match
        }
        if let tabNumber = scopedOrdinal(token, prefix: "tab"),
           let match = bundle.tabs.first(where: { $0.tabNumber == tabNumber }) {
            return match
        }
        throw ShuttleError.notFound(entity: "Tab", token: token)
    }

    public static func scopedOrdinal(_ token: String, prefix: String) -> Int? {
        let prefixValue = "\(prefix):"
        guard token.hasPrefix(prefixValue) else {
            return nil
        }
        return Int(token.dropFirst(prefixValue.count))
    }
}

public final class ShuttleControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ShuttleControlCommand) async throws -> ShuttleControlValue

    public let paths: ShuttlePaths
    private let socketServer: ShuttleUnixDomainSocketServer
    private let handler: Handler

    public init(paths: ShuttlePaths = ShuttlePaths(), handler: @escaping Handler) {
        self.paths = paths
        self.handler = handler
        self.socketServer = ShuttleUnixDomainSocketServer(socketURL: paths.controlSocketURL)
    }

    public func start() throws {
        try paths.ensureDirectories()
        try socketServer.start { [handler] data in
            await Self.handleRequestData(data, handler: handler)
        }
    }

    public func stop() {
        socketServer.stop()
    }

    private static func handleRequestData(_ data: Data, handler: Handler) async -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let response: ShuttleControlResponse
        do {
            let request = try decoder.decode(ShuttleControlRequest.self, from: data)
            guard request.protocolVersion == ShuttleControlRequest.protocolVersion else {
                throw ShuttleError.unsupported(
                    "Unsupported control protocol version \(request.protocolVersion); expected \(ShuttleControlRequest.protocolVersion)"
                )
            }
            let value = try await handler(request.command)
            response = ShuttleControlResponse(requestID: request.requestID, value: value)
        } catch let error as ShuttleError {
            response = ShuttleControlResponse(
                requestID: UUID(),
                error: ShuttleControlRemoteError(code: error.code, message: error.localizedDescription)
            )
        } catch {
            response = ShuttleControlResponse(
                requestID: UUID(),
                error: ShuttleControlRemoteError(code: ShuttleError.io(error.localizedDescription).code, message: error.localizedDescription)
            )
        }

        return (try? encoder.encode(response)) ?? Data()
    }
}

public struct ShuttleControlClient: Sendable {
    public let paths: ShuttlePaths
    private let timeoutSeconds: Double

    public init(paths: ShuttlePaths = ShuttlePaths(), timeoutSeconds: Double = 20) {
        self.paths = paths
        self.timeoutSeconds = timeoutSeconds
    }

    public var socketURL: URL { paths.controlSocketURL }

    public func send(_ command: ShuttleControlCommand) throws -> ShuttleControlValue {
        let request = ShuttleControlRequest(command: command)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let requestData = try encoder.encode(request)
        let responseData = try ShuttleUnixDomainSocketClient(socketURL: socketURL, timeoutSeconds: timeoutSeconds).send(requestData)
        let response = try decoder.decode(ShuttleControlResponse.self, from: responseData)
        if let error = response.error {
            throw ShuttleError(remoteCode: error.code, message: error.message)
        }
        guard let value = response.value else {
            throw ShuttleError.io("Control response for \(command.name) was missing a value")
        }
        return value
    }

    public func send(_ command: ShuttleControlCommand, launchIfNeeded: Bool) throws -> ShuttleControlValue {
        do {
            return try send(command)
        } catch let error as ShuttleError where launchIfNeeded && error.isLikelyControlPlaneUnavailable {
            try ShuttleAppLauncher(paths: paths).launchAndWaitForControlServer(timeoutSeconds: timeoutSeconds)
            return try send(command)
        }
    }

    public func ping() throws -> ShuttleControlPong {
        let value = try send(.ping)
        guard case .pong(let pong) = value else {
            throw ShuttleError.io("Unexpected control response to ping")
        }
        return pong
    }

    public func capabilities() throws -> ShuttleControlCapabilities {
        let value = try send(.capabilities)
        guard case .capabilities(let capabilities) = value else {
            throw ShuttleError.io("Unexpected control response to capabilities")
        }
        return capabilities
    }
}

public struct ShuttleAppLauncher: Sendable {
    public let paths: ShuttlePaths

    public init(paths: ShuttlePaths = ShuttlePaths()) {
        self.paths = paths
    }

    public func launchAndWaitForControlServer(timeoutSeconds: Double = 20) throws {
        try launch()
        let client = ShuttleControlClient(paths: paths, timeoutSeconds: min(timeoutSeconds, 2))
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        while Date() < deadline {
            do {
                _ = try client.ping()
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if let lastError {
            throw ShuttleError.io("Launched \(paths.profile.appDisplayName) but the control server did not become ready: \(lastError.localizedDescription)")
        }
        throw ShuttleError.io("Launched \(paths.profile.appDisplayName) but the control server did not become ready")
    }

    public func launch() throws {
        for candidate in launchCandidates() {
            switch candidate {
            case .appPath(let url):
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let result = try runProcess("/usr/bin/open", arguments: [url.path])
                if result.succeeded {
                    return
                }
            case .bundleIdentifier(let bundleIdentifier):
                let result = try runProcess("/usr/bin/open", arguments: ["-b", bundleIdentifier])
                if result.succeeded {
                    return
                }
            }
        }

        throw ShuttleError.io(
            "Could not launch \(paths.profile.appDisplayName). Set SHUTTLE_APP_PATH to a \(paths.profile.appDisplayName).app bundle or install/register the app."
        )
    }

    private func launchCandidates() -> [LaunchCandidate] {
        var candidates: [LaunchCandidate] = []
        let fileManager = FileManager.default

        if let configuredPath = ProcessInfo.processInfo.environment["SHUTTLE_APP_PATH"], !configuredPath.isEmpty {
            candidates.append(.appPath(URL(fileURLWithPath: expandedPath(configuredPath), isDirectory: true)))
        }

        if let executableURL = Bundle.main.executableURL,
           let enclosingAppURL = enclosingAppURL(for: executableURL) {
            candidates.append(.appPath(enclosingAppURL))
            candidates.append(contentsOf: distBundleCandidates(startingAt: executableURL.deletingLastPathComponent()))
        }

        candidates.append(contentsOf: distBundleCandidates(startingAt: URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)))
        candidates.append(.appPath(URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent("\(paths.profile.appDisplayName).app", isDirectory: true)))
        candidates.append(.bundleIdentifier(paths.profile.bundleIdentifier))

        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = candidate.dedupKey
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func distBundleCandidates(startingAt start: URL) -> [LaunchCandidate] {
        var candidates: [LaunchCandidate] = []
        var current = start.standardizedFileURL
        let appName = "\(paths.profile.appDisplayName).app"

        for _ in 0..<8 {
            candidates.append(
                .appPath(
                    current
                        .appendingPathComponent(paths.profile.distDirectory, isDirectory: true)
                        .appendingPathComponent(appName, isDirectory: true)
                )
            )

            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }

        return candidates
    }

    private func enclosingAppURL(for executableURL: URL) -> URL? {
        var current = executableURL.standardizedFileURL
        for _ in 0..<6 {
            if current.pathExtension.lowercased() == "app" {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private enum LaunchCandidate {
        case appPath(URL)
        case bundleIdentifier(String)

        var dedupKey: String {
            switch self {
            case .appPath(let url):
                return "path:\(url.path)"
            case .bundleIdentifier(let bundleIdentifier):
                return "bundle:\(bundleIdentifier)"
            }
        }
    }
}

private final class ShuttleUnixDomainSocketServer: @unchecked Sendable {
    typealias RawHandler = @Sendable (Data) async -> Data

    private let socketURL: URL
    private var listenerFD: Int32 = -1
    private let stateLock = NSLock()
    private var isRunning = false

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    func start(handler: @escaping RawHandler) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isRunning {
            return
        }

        try? FileManager.default.removeItem(at: socketURL)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ShuttleError.io("Failed to create control socket at \(socketURL.path)")
        }

        do {
            try configureNoSigPipe(fd)
            var address = try makeSocketAddress(path: socketURL.path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
                }
            }
            guard bindResult == 0 else {
                let message = String(cString: strerror(errno))
                close(fd)
                throw ShuttleError.io("Failed to bind control socket at \(socketURL.path): \(message)")
            }

            guard listen(fd, SOMAXCONN) == 0 else {
                let message = String(cString: strerror(errno))
                close(fd)
                throw ShuttleError.io("Failed to listen on control socket at \(socketURL.path): \(message)")
            }

            listenerFD = fd
            isRunning = true
        } catch {
            close(fd)
            throw error
        }

        let acceptFD = listenerFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.acceptLoop(listenerFD: acceptFD, handler: handler)
        }
    }

    func stop() {
        stateLock.lock()
        let fd = listenerFD
        listenerFD = -1
        let wasRunning = isRunning
        isRunning = false
        stateLock.unlock()

        if fd >= 0 {
            close(fd)
        }
        if wasRunning {
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    private func acceptLoop(listenerFD: Int32, handler: @escaping RawHandler) {
        while true {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }

            do {
                try configureNoSigPipe(clientFD)
            } catch {
                close(clientFD)
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async {
                Self.handleClient(clientFD: clientFD, handler: handler)
            }
        }
    }

    private static func handleClient(clientFD: Int32, handler: @escaping RawHandler) {
        let requestData = readAll(from: clientFD)
        Task.detached(priority: .userInitiated) {
            let responseData = await handler(requestData)
            _ = writeAll(responseData, to: clientFD)
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
    }
}

private struct ShuttleUnixDomainSocketClient {
    let socketURL: URL
    let timeoutSeconds: Double

    func send(_ requestData: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ShuttleError.io("Failed to create control socket client for \(socketURL.path)")
        }
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        try configureNoSigPipe(fd)
        try configureTimeout(fd, timeoutSeconds: timeoutSeconds)

        var address = try makeSocketAddress(path: socketURL.path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let message = String(cString: strerror(errno))
            throw ShuttleError.io("Failed to connect to Shuttle control socket at \(socketURL.path): \(message)")
        }

        guard writeAll(requestData, to: fd) else {
            let message = String(cString: strerror(errno))
            throw ShuttleError.io("Failed to write control request to \(socketURL.path): \(message)")
        }
        shutdown(fd, SHUT_WR)

        let responseData = readAll(from: fd)
        guard !responseData.isEmpty else {
            throw ShuttleError.io("Shuttle control server at \(socketURL.path) returned an empty response")
        }
        return responseData
    }
}

private func makeSocketAddress(path: String) throws -> sockaddr_un {
    let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let pathBytes = normalizedPath.utf8CString
    let maxLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    guard pathBytes.count <= maxLength else {
        throw ShuttleError.invalidArguments("Control socket path is too long for Unix domain sockets: \(normalizedPath)")
    }

    var address = sockaddr_un()
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        memset(pointer, 0, MemoryLayout<sockaddr_un>.stride)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
    address.sun_family = sa_family_t(AF_UNIX)

    pathBytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            destination.initialize(from: baseAddress, count: buffer.count)
        }
    }

    return address
}

private func configureNoSigPipe(_ fd: Int32) throws {
    var value: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        let message = String(cString: strerror(errno))
        throw ShuttleError.io("Failed to configure control socket no-sigpipe: \(message)")
    }
}

private func configureTimeout(_ fd: Int32, timeoutSeconds: Double) throws {
    guard timeoutSeconds > 0 else { return }
    let wholeSeconds = floor(timeoutSeconds)
    let fractional = timeoutSeconds - wholeSeconds
    var timeout = timeval(
        tv_sec: Int(wholeSeconds),
        tv_usec: __darwin_suseconds_t(fractional * 1_000_000)
    )
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
        let message = String(cString: strerror(errno))
        throw ShuttleError.io("Failed to configure control socket timeout: \(message)")
    }
}

private func readAll(from fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let capacity = buffer.count
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress, capacity)
        }
        if readCount > 0 {
            data.append(contentsOf: buffer.prefix(readCount))
            continue
        }
        if readCount == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        break
    }

    return data
}

@discardableResult
private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    var totalWritten = 0
    return data.withUnsafeBytes { bytes -> Bool in
        guard let baseAddress = bytes.baseAddress else {
            return true
        }

        while totalWritten < data.count {
            let written = Darwin.write(fd, baseAddress.advanced(by: totalWritten), data.count - totalWritten)
            if written > 0 {
                totalWritten += written
                continue
            }
            if written < 0 && errno == EINTR {
                continue
            }
            return false
        }
        return true
    }
}

public extension ShuttleError {
    init(remoteCode: String, message: String) {
        switch remoteCode {
        case ShuttleError.invalidCommand("").code:
            self = .invalidCommand(message)
        case ShuttleError.invalidArguments("").code:
            self = .invalidArguments(message)
        case ShuttleError.configMissing("").code:
            self = .configMissing(message)
        case ShuttleError.configInvalid("").code:
            self = .configInvalid(message)
        case ShuttleError.notFound(entity: "", token: "").code:
            self = .notFound(entity: "Remote", token: Self.parseRemoteNotFoundToken(from: message))
        case ShuttleError.database("").code:
            self = .database(message)
        case ShuttleError.unsupported("").code:
            self = .unsupported(message)
        default:
            self = .io(message)
        }
    }

    /// Extracts the token from a remote `notFound` message like "Session 'workspace:1/session:1' was not found" → "workspace:1/session:1".
    /// Falls back to the full message if the pattern doesn't match.
    private static func parseRemoteNotFoundToken(from message: String) -> String {
        // Pattern: "<Entity> '<token>' was not found"
        guard let openQuote = message.firstIndex(of: "'"),
              let closeQuote = message[message.index(after: openQuote)...].firstIndex(of: "'") else {
            return message
        }
        return String(message[message.index(after: openQuote)..<closeQuote])
    }

    var isLikelyControlPlaneUnavailable: Bool {
        guard case .io(let message) = self else {
            return false
        }
        return message.contains("control socket") || message.contains("did not become ready")
    }
}
