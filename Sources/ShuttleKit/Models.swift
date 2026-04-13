import Foundation

public enum ProjectKind: String, CaseIterable, Codable, Sendable {
    case normal
    case `try`
}

public enum WorkspaceSource: String, CaseIterable, Codable, Sendable {
    case auto
    case manual
    case global
}

public enum SessionStatus: String, CaseIterable, Codable, Sendable {
    case active
    case closed
    case restorable
}

public enum CheckoutType: String, CaseIterable, Codable, Sendable {
    case direct
}

public enum SplitDirection: String, CaseIterable, Codable, Sendable {
    case left
    case right
    case up
    case down
}

public enum RuntimeStatus: String, CaseIterable, Codable, Sendable {
    case idle
    case placeholder
    case exited
}

public enum ShuttleTabReadMode: String, CaseIterable, Codable, Sendable {
    case screen
    case scrollback
}

public struct ShuttleTabOutputCursor: Hashable, Sendable, Codable {
    public var token: String
    public var tabID: String
    public var mode: ShuttleTabReadMode
    public var capturedAt: Date

    public init(token: String, tabID: String, mode: ShuttleTabReadMode, capturedAt: Date) {
        self.token = token
        self.tabID = tabID
        self.mode = mode
        self.capturedAt = capturedAt
    }
}

public struct ShuttleTabSendResult: Hashable, Sendable, Codable {
    public var session: Session
    public var workspace: Workspace
    public var tab: Tab
    public var text: String
    public var submitted: Bool
    public var sentAt: Date
    public var cursor: ShuttleTabOutputCursor?

    public init(
        session: Session,
        workspace: Workspace,
        tab: Tab,
        text: String,
        submitted: Bool,
        sentAt: Date,
        cursor: ShuttleTabOutputCursor? = nil
    ) {
        self.session = session
        self.workspace = workspace
        self.tab = tab
        self.text = text
        self.submitted = submitted
        self.sentAt = sentAt
        self.cursor = cursor
    }
}

public struct ShuttleTabReadResult: Hashable, Sendable, Codable {
    public var session: Session
    public var workspace: Workspace
    public var tab: Tab
    public var mode: ShuttleTabReadMode
    public var text: String
    public var lineCount: Int
    public var capturedAt: Date
    public var matchedText: String?
    public var afterCursor: ShuttleTabOutputCursor?
    public var cursor: ShuttleTabOutputCursor
    public var isIncremental: Bool

    public init(
        session: Session,
        workspace: Workspace,
        tab: Tab,
        mode: ShuttleTabReadMode,
        text: String,
        lineCount: Int,
        capturedAt: Date,
        matchedText: String? = nil,
        afterCursor: ShuttleTabOutputCursor? = nil,
        cursor: ShuttleTabOutputCursor,
        isIncremental: Bool = false
    ) {
        self.session = session
        self.workspace = workspace
        self.tab = tab
        self.mode = mode
        self.text = text
        self.lineCount = lineCount
        self.capturedAt = capturedAt
        self.matchedText = matchedText
        self.afterCursor = afterCursor
        self.cursor = cursor
        self.isIncremental = isIncremental
    }
}

public struct ShuttleMutationStatus: Hashable, Sendable, Codable {
    public var changed: Bool
    public var action: String
    public var noopReason: String?

    public init(changed: Bool, action: String, noopReason: String? = nil) {
        self.changed = changed
        self.action = action
        self.noopReason = noopReason
    }
}

public struct ShuttleSessionMutationResult: Hashable, Sendable, Codable {
    public var status: ShuttleMutationStatus
    public var bundle: SessionBundle

    public init(status: ShuttleMutationStatus, bundle: SessionBundle) {
        self.status = status
        self.bundle = bundle
    }
}

public struct ShuttleLayoutMutationResult: Hashable, Sendable, Codable {
    public var status: ShuttleMutationStatus
    public var bundle: SessionBundle
    public var layout: LayoutPreset

    public init(status: ShuttleMutationStatus, bundle: SessionBundle, layout: LayoutPreset) {
        self.status = status
        self.bundle = bundle
        self.layout = layout
    }
}

public struct ShuttleConfig: Codable, Hashable, Sendable {
    public var sessionRoot: String
    public var triesRoot: String?
    public var projectRoots: [String]
    public var ignoredPaths: [String]

    enum CodingKeys: String, CodingKey {
        case sessionRoot = "session_root"
        case triesRoot = "tries_root"
        case projectRoots = "project_roots"
        case ignoredPaths = "ignored_paths"
    }

    public init(
        sessionRoot: String,
        triesRoot: String?,
        projectRoots: [String],
        ignoredPaths: [String]
    ) {
        self.sessionRoot = sessionRoot
        self.triesRoot = triesRoot
        self.projectRoots = projectRoots
        self.ignoredPaths = ignoredPaths
    }
}

public struct Project: Identifiable, Hashable, Sendable, Codable {
    public let rawID: Int64
    public let id: String
    public let uuid: UUID
    public var name: String
    public var path: String
    public var kind: ProjectKind
    public var defaultWorkspaceID: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        rawID: Int64,
        uuid: UUID,
        name: String,
        path: String,
        kind: ProjectKind,
        defaultWorkspaceID: Int64?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.rawID = rawID
        self.id = Self.makeRef(rawID)
        self.uuid = uuid
        self.name = name
        self.path = path
        self.kind = kind
        self.defaultWorkspaceID = defaultWorkspaceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeRef(_ rawID: Int64) -> String { "project:\(rawID)" }
}

public struct Workspace: Identifiable, Hashable, Sendable, Codable {
    public let rawID: Int64
    public let id: String
    public let uuid: UUID
    public var name: String
    public var slug: String
    public var createdFrom: WorkspaceSource
    public var isDefault: Bool
    public var sourceProjectID: Int64?
    public var projectIDs: [Int64]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        rawID: Int64,
        uuid: UUID,
        name: String,
        slug: String,
        createdFrom: WorkspaceSource,
        isDefault: Bool,
        sourceProjectID: Int64?,
        projectIDs: [Int64],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.rawID = rawID
        self.id = Self.makeRef(rawID)
        self.uuid = uuid
        self.name = name
        self.slug = slug
        self.createdFrom = createdFrom
        self.isDefault = isDefault
        self.sourceProjectID = sourceProjectID
        self.projectIDs = projectIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeRef(_ rawID: Int64) -> String { "workspace:\(rawID)" }
}

public struct Session: Identifiable, Hashable, Sendable, Codable {
    public let rawID: Int64
    public let id: String
    public let uuid: UUID
    public var workspaceID: Int64
    public var sessionNumber: Int
    public var name: String
    public var slug: String
    public var status: SessionStatus
    public var sessionRootPath: String
    public var layoutName: String?
    public var createdAt: Date
    public var lastActiveAt: Date
    public var closedAt: Date?

    public init(
        rawID: Int64,
        uuid: UUID,
        workspaceID: Int64,
        sessionNumber: Int,
        name: String,
        slug: String,
        status: SessionStatus,
        sessionRootPath: String,
        layoutName: String?,
        createdAt: Date,
        lastActiveAt: Date,
        closedAt: Date?
    ) {
        self.rawID = rawID
        self.id = Self.makeScopedRef(workspaceID: workspaceID, sessionNumber: sessionNumber)
        self.uuid = uuid
        self.workspaceID = workspaceID
        self.sessionNumber = sessionNumber
        self.name = name
        self.slug = slug
        self.status = status
        self.sessionRootPath = sessionRootPath
        self.layoutName = layoutName
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.closedAt = closedAt
    }

    public static func makeRef(_ rawID: Int64) -> String { "session:\(rawID)" }

    public static func makeScopedRef(workspaceID: Int64, sessionNumber: Int) -> String {
        "workspace:\(workspaceID)/session:\(sessionNumber)"
    }
}

public struct SessionProject: Hashable, Sendable, Codable {
    public var sessionID: Int64
    public var projectID: Int64
    public var checkoutType: CheckoutType
    public var checkoutPath: String
    public var metadataJSON: String?

    public init(
        sessionID: Int64,
        projectID: Int64,
        checkoutType: CheckoutType,
        checkoutPath: String,
        metadataJSON: String?
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.checkoutType = checkoutType
        self.checkoutPath = checkoutPath
        self.metadataJSON = metadataJSON
    }
}

public struct Pane: Identifiable, Hashable, Sendable, Codable {
    public let rawID: Int64
    public let id: String
    public var sessionID: Int64
    public var workspaceID: Int64
    public var sessionNumber: Int
    public var paneNumber: Int
    public var parentPaneID: Int64?
    public var splitDirection: SplitDirection?
    public var ratio: Double?
    public var positionIndex: Int

    public init(
        rawID: Int64,
        sessionID: Int64,
        workspaceID: Int64,
        sessionNumber: Int,
        paneNumber: Int,
        parentPaneID: Int64?,
        splitDirection: SplitDirection?,
        ratio: Double?,
        positionIndex: Int
    ) {
        self.rawID = rawID
        self.id = Self.makeScopedRef(workspaceID: workspaceID, sessionNumber: sessionNumber, paneNumber: paneNumber)
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.sessionNumber = sessionNumber
        self.paneNumber = paneNumber
        self.parentPaneID = parentPaneID
        self.splitDirection = splitDirection
        self.ratio = ratio
        self.positionIndex = positionIndex
    }

    public static func makeRef(_ rawID: Int64) -> String { "pane:\(rawID)" }

    public static func makeScopedRef(workspaceID: Int64, sessionNumber: Int, paneNumber: Int) -> String {
        "workspace:\(workspaceID)/session:\(sessionNumber)/pane:\(paneNumber)"
    }
}

public struct Tab: Identifiable, Hashable, Sendable, Codable {
    public let rawID: Int64
    public let id: String
    public var sessionID: Int64
    public var workspaceID: Int64
    public var sessionNumber: Int
    public var paneID: Int64
    public var title: String
    public var cwd: String
    public var projectID: Int64?
    public var command: String?
    public var envJSON: String?
    public var runtimeStatus: RuntimeStatus
    public var positionIndex: Int
    public var tabNumber: Int
    public var needsAttention: Bool
    public var attentionMessage: String?

    public init(
        rawID: Int64,
        sessionID: Int64,
        workspaceID: Int64,
        sessionNumber: Int,
        paneID: Int64,
        title: String,
        cwd: String,
        projectID: Int64?,
        command: String?,
        envJSON: String?,
        runtimeStatus: RuntimeStatus,
        positionIndex: Int,
        tabNumber: Int,
        needsAttention: Bool = false,
        attentionMessage: String? = nil
    ) {
        self.rawID = rawID
        self.id = Self.makeScopedRef(workspaceID: workspaceID, sessionNumber: sessionNumber, tabNumber: tabNumber)
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.sessionNumber = sessionNumber
        self.paneID = paneID
        self.title = title
        self.cwd = cwd
        self.projectID = projectID
        self.command = command
        self.envJSON = envJSON
        self.runtimeStatus = runtimeStatus
        self.positionIndex = positionIndex
        self.tabNumber = tabNumber
        self.needsAttention = needsAttention
        self.attentionMessage = attentionMessage
    }

    public var runtimeKey: String { Self.makeRef(rawID) }

    public static func makeRef(_ rawID: Int64) -> String { "tab:\(rawID)" }

    public static func makeScopedRef(workspaceID: Int64, sessionNumber: Int, tabNumber: Int) -> String {
        "workspace:\(workspaceID)/session:\(sessionNumber)/tab:\(tabNumber)"
    }
}

public struct SessionBundle: Hashable, Sendable, Codable {
    public var session: Session
    public var workspace: Workspace
    public var projects: [Project]
    public var sessionProjects: [SessionProject]
    public var panes: [Pane]
    public var tabs: [Tab]

    public init(
        session: Session,
        workspace: Workspace,
        projects: [Project],
        sessionProjects: [SessionProject],
        panes: [Pane],
        tabs: [Tab]
    ) {
        self.session = session
        self.workspace = workspace
        self.projects = projects
        self.sessionProjects = sessionProjects
        self.panes = panes
        self.tabs = tabs
    }
}
