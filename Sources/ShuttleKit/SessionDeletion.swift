import Foundation

public struct SessionDeletionProjectPreview: Hashable, Sendable, Codable {
    public var project: Project
    public var sessionProject: SessionProject
    public var warnings: [String]

    public init(
        project: Project,
        sessionProject: SessionProject,
        warnings: [String]
    ) {
        self.project = project
        self.sessionProject = sessionProject
        self.warnings = warnings
    }

    public var isSourceCheckout: Bool {
        sessionProject.checkoutType == .direct
    }
}

public struct SessionDeletionPreview: Hashable, Sendable, Codable {
    public var session: Session
    public var workspace: Workspace
    public var projects: [SessionDeletionProjectPreview]

    public init(session: Session, workspace: Workspace, projects: [SessionDeletionProjectPreview]) {
        self.session = session
        self.workspace = workspace
        self.projects = projects
    }

    public var sourceCheckoutProjectCount: Int {
        projects.filter(\.isSourceCheckout).count
    }
}

public struct SessionDeletionResult: Hashable, Sendable, Codable {
    public var sessionID: Int64
    public var sessionName: String
    public var warnings: [String]

    public init(
        sessionID: Int64,
        sessionName: String,
        warnings: [String]
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.warnings = warnings
    }

    public var warningCount: Int {
        warnings.count
    }
}
