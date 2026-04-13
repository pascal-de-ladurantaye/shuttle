import Foundation
import SQLite3

private final class SQLiteDatabase {
    let handle: OpaquePointer

    init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &connection, flags, nil) != SQLITE_OK || connection == nil {
            let message = connection.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let connection {
                sqlite3_close(connection)
            }
            throw ShuttleError.database("Failed to open SQLite database at \(path): \(message)")
        }
        self.handle = connection!
        sqlite3_busy_timeout(self.handle, 5_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw ShuttleError.database(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK || statement == nil {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(handle)))
        }
        return statement!
    }

    func lastInsertedRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
    if let value {
        if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw ShuttleError.database("Failed to bind text at index \(index)")
        }
    } else {
        if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw ShuttleError.database("Failed to bind null at index \(index)")
        }
    }
}

private func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer) throws {
    if let value {
        if sqlite3_bind_int64(statement, index, value) != SQLITE_OK {
            throw ShuttleError.database("Failed to bind int at index \(index)")
        }
    } else {
        if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw ShuttleError.database("Failed to bind null at index \(index)")
        }
    }
}

private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) throws {
    if let value {
        if sqlite3_bind_double(statement, index, value) != SQLITE_OK {
            throw ShuttleError.database("Failed to bind double at index \(index)")
        }
    } else {
        if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw ShuttleError.database("Failed to bind null at index \(index)")
        }
    }
}

private func bind(_ value: Bool, at index: Int32, in statement: OpaquePointer) throws {
    if sqlite3_bind_int(statement, index, value ? 1 : 0) != SQLITE_OK {
        throw ShuttleError.database("Failed to bind bool at index \(index)")
    }
}

private func text(at index: Int32, from statement: OpaquePointer) -> String? {
    guard let value = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(cString: value)
}

private func int64(at index: Int32, from statement: OpaquePointer) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
        return nil
    }
    return sqlite3_column_int64(statement, index)
}

private func double(at index: Int32, from statement: OpaquePointer) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
        return nil
    }
    return sqlite3_column_double(statement, index)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct WorkspaceDetails: Hashable, Sendable, Codable {
    public var workspace: Workspace
    public var projects: [Project]
    public var sessions: [Session]

    public init(workspace: Workspace, projects: [Project], sessions: [Session]) {
        self.workspace = workspace
        self.projects = projects
        self.sessions = sessions
    }
}

public struct ProjectDetails: Hashable, Sendable, Codable {
    public var project: Project
    public var defaultWorkspace: Workspace?

    public init(project: Project, defaultWorkspace: Workspace?) {
        self.project = project
        self.defaultWorkspace = defaultWorkspace
    }
}

public final class PersistenceStore {
    private let paths: ShuttlePaths
    private let database: SQLiteDatabase

    public init(paths: ShuttlePaths = ShuttlePaths()) throws {
        self.paths = paths
        try paths.ensureDirectories()
        self.database = try SQLiteDatabase(path: paths.databaseURL.path)
        try migrate()
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try database.transaction(body)
    }

    private static let schemaVersion = 7
    private static let globalWorkspaceName = "Global"
    private static let globalWorkspaceSlug = "global"
    private static let globalWorkspaceAliases: Set<String> = ["global", "scratchpad"]

    public func migrate() throws {
        try database.execute("PRAGMA foreign_keys = ON;")

        let version = try currentSchemaVersion()
        if version == Self.schemaVersion {
            try ensureSupplementalSchema()
            try normalizeLegacyDirectCheckoutPaths()
            return
        }

        try database.execute("PRAGMA journal_mode = WAL;")
        try database.transaction {
            switch try currentSchemaVersion() {
            case Self.schemaVersion:
                return
            case 0:
                try createSchemaIfNeeded()
            case 5:
                try migrateSchemaV5ToV6()
                try migrateSchemaV6ToV7()
            case 6:
                try migrateSchemaV6ToV7()
            default:
                try resetSchema()
                try createSchemaIfNeeded()
            }
            try setSchemaVersion(Self.schemaVersion)
        }
        try ensureSupplementalSchema()
        try normalizeLegacyDirectCheckoutPaths()
    }

    private func ensureSupplementalSchema() throws {
        try database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_global_workspace ON workspaces(created_from) WHERE created_from = '\(WorkspaceSource.global.rawValue)'"
        )
    }

    private func migrateSchemaV5ToV6() throws {
        try database.execute(
            """
            ALTER TABLE projects DROP COLUMN vcs_kind;
            ALTER TABLE projects DROP COLUMN default_branch;
            ALTER TABLE session_projects DROP COLUMN base_branch;
            ALTER TABLE session_projects DROP COLUMN created_branch_name;
            ALTER TABLE session_projects DROP COLUMN merge_status;
            ALTER TABLE session_projects DROP COLUMN dirty;
            """
        )
    }

    private func migrateSchemaV6ToV7() throws {
        try database.execute(
            """
            ALTER TABLE tabs ADD COLUMN needs_attention INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE tabs ADD COLUMN attention_message TEXT;
            """
        )
    }

    private func normalizeLegacyDirectCheckoutPaths() throws {
        try database.execute(
            """
            UPDATE session_projects
            SET checkout_path = (
              SELECT projects.path
              FROM projects
              WHERE projects.id = session_projects.project_id
            )
            WHERE checkout_type = '\(CheckoutType.direct.rawValue)'
              AND EXISTS (
                SELECT 1
                FROM sessions
                WHERE sessions.id = session_projects.session_id
                  AND (
                    session_projects.checkout_path = sessions.session_root_path
                    OR session_projects.checkout_path LIKE sessions.session_root_path || '/%'
                  )
              );
            """
        )
    }

    private func currentSchemaVersion() throws -> Int {
        let statement = try database.prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func setSchemaVersion(_ version: Int) throws {
        try database.execute("PRAGMA user_version = \(version)")
    }

    private func resetSchema() throws {
        try database.execute(
            """
            DROP TABLE IF EXISTS tabs;
            DROP TABLE IF EXISTS panes;
            DROP TABLE IF EXISTS session_projects;
            DROP TABLE IF EXISTS sessions;
            DROP TABLE IF EXISTS workspace_projects;
            DROP TABLE IF EXISTS workspaces;
            DROP TABLE IF EXISTS projects;
            """
        )
    }

    private func createSchemaIfNeeded() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uuid TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              path TEXT NOT NULL UNIQUE,
              kind TEXT NOT NULL,
              default_workspace_id INTEGER,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspaces (
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

            CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_default_source_project
            ON workspaces(source_project_id)
            WHERE is_default = 1 AND source_project_id IS NOT NULL;

            CREATE TABLE IF NOT EXISTS workspace_projects (
              workspace_id INTEGER NOT NULL,
              project_id INTEGER NOT NULL,
              position_index INTEGER NOT NULL,
              PRIMARY KEY (workspace_id, project_id),
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS sessions (
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
              closed_at TEXT,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS session_projects (
              session_id INTEGER NOT NULL,
              project_id INTEGER NOT NULL,
              checkout_type TEXT NOT NULL,
              checkout_path TEXT NOT NULL,
              metadata_json TEXT,
              PRIMARY KEY (session_id, project_id),
              FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
              FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS panes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL,
              pane_number INTEGER NOT NULL,
              parent_pane_id INTEGER,
              split_direction TEXT,
              ratio REAL,
              position_index INTEGER NOT NULL,
              FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
              FOREIGN KEY (parent_pane_id) REFERENCES panes(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS tabs (
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
              position_index INTEGER NOT NULL,
              needs_attention INTEGER NOT NULL DEFAULT 0,
              attention_message TEXT,
              FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
              FOREIGN KEY (pane_id) REFERENCES panes(id) ON DELETE CASCADE,
              FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE SET NULL
            );

            CREATE INDEX IF NOT EXISTS idx_projects_name ON projects(name);
            CREATE INDEX IF NOT EXISTS idx_workspaces_name ON workspaces(name);
            CREATE INDEX IF NOT EXISTS idx_sessions_workspace_id ON sessions(workspace_id);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_workspace_session_number ON sessions(workspace_id, session_number);
            CREATE INDEX IF NOT EXISTS idx_panes_session_id ON panes(session_id);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_panes_session_pane_number ON panes(session_id, pane_number);
            CREATE INDEX IF NOT EXISTS idx_tabs_session_id ON tabs(session_id);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_tabs_session_tab_number ON tabs(session_id, tab_number);
            """
        )
    }

    public func upsertProject(
        name: String,
        path: String,
        kind: ProjectKind
    ) throws -> Project {
        if let existing = try projectByPath(path) {
            let statement = try database.prepare(
                """
                UPDATE projects
                SET name = ?, kind = ?, updated_at = ?
                WHERE id = ?
                """
            )
            defer { sqlite3_finalize(statement) }

            let now = Date()
            try bind(name, at: 1, in: statement)
            try bind(kind.rawValue, at: 2, in: statement)
            try bind(iso8601String(from: now), at: 3, in: statement)
            try bind(existing.rawID, at: 4, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
            }

            return try project(id: existing.rawID)!
        }

        let statement = try database.prepare(
            """
            INSERT INTO projects (uuid, name, path, kind, default_workspace_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, NULL, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = Date()
        try bind(UUID().uuidString, at: 1, in: statement)
        try bind(name, at: 2, in: statement)
        try bind(path, at: 3, in: statement)
        try bind(kind.rawValue, at: 4, in: statement)
        try bind(iso8601String(from: now), at: 5, in: statement)
        try bind(iso8601String(from: now), at: 6, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        let id = database.lastInsertedRowID()
        return try project(id: id)!
    }

    public func listProjects() throws -> [Project] {
        let statement = try database.prepare(
            """
            SELECT id, uuid, name, path, kind, default_workspace_id, created_at, updated_at
            FROM projects
            ORDER BY name COLLATE NOCASE, path COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [Project] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeProject(from: statement))
        }
        return result
    }

    public func project(matching token: String) throws -> Project? {
        if let refID = parseRef(token, prefix: "project") {
            return try project(id: refID)
        }

        if let uuid = UUID(uuidString: token) {
            let statement = try database.prepare(
                "SELECT id, uuid, name, path, kind, default_workspace_id, created_at, updated_at FROM projects WHERE uuid = ? LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try bind(uuid.uuidString, at: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return try decodeProject(from: statement)
            }
            return nil
        }

        let byName = try database.prepare(
            "SELECT id, uuid, name, path, kind, default_workspace_id, created_at, updated_at FROM projects WHERE name = ? COLLATE NOCASE LIMIT 1"
        )
        defer { sqlite3_finalize(byName) }
        try bind(token, at: 1, in: byName)
        if sqlite3_step(byName) == SQLITE_ROW {
            return try decodeProject(from: byName)
        }

        return try projectByPath(token)
    }

    public func ensureDefaultWorkspace(for project: Project) throws -> Workspace {
        if let workspaceID = project.defaultWorkspaceID, let workspace = try workspace(id: workspaceID) {
            try ensureWorkspaceProjectLink(workspaceID: workspace.rawID, projectID: project.rawID)
            return workspace
        }

        if let statementWorkspace = try defaultWorkspaceForSourceProject(project.rawID) {
            try setProjectDefaultWorkspace(projectID: project.rawID, workspaceID: statementWorkspace.rawID)
            try ensureWorkspaceProjectLink(workspaceID: statementWorkspace.rawID, projectID: project.rawID)
            return statementWorkspace
        }

        let now = Date()
        let slug = slugify(project.name)
        let statement = try database.prepare(
            """
            INSERT INTO workspaces (uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(UUID().uuidString, at: 1, in: statement)
        try bind(project.name, at: 2, in: statement)
        try bind(slug, at: 3, in: statement)
        try bind(WorkspaceSource.auto.rawValue, at: 4, in: statement)
        try bind(true, at: 5, in: statement)
        try bind(project.rawID, at: 6, in: statement)
        try bind(iso8601String(from: now), at: 7, in: statement)
        try bind(iso8601String(from: now), at: 8, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        let workspaceID = database.lastInsertedRowID()
        try ensureWorkspaceProjectLink(workspaceID: workspaceID, projectID: project.rawID)
        try setProjectDefaultWorkspace(projectID: project.rawID, workspaceID: workspaceID)
        return try workspace(id: workspaceID)!
    }

    public func ensureGlobalWorkspace() throws -> Workspace {
        if let existing = try globalWorkspace() {
            return existing
        }

        let now = Date()
        let statement = try database.prepare(
            """
            INSERT OR IGNORE INTO workspaces (uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(UUID().uuidString, at: 1, in: statement)
        try bind(Self.globalWorkspaceName, at: 2, in: statement)
        try bind(Self.globalWorkspaceSlug, at: 3, in: statement)
        try bind(WorkspaceSource.global.rawValue, at: 4, in: statement)
        try bind(false, at: 5, in: statement)
        try bind(nil as Int64?, at: 6, in: statement)
        try bind(iso8601String(from: now), at: 7, in: statement)
        try bind(iso8601String(from: now), at: 8, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        if let existing = try globalWorkspace() {
            return existing
        }
        throw ShuttleError.io("Failed to create the global workspace")
    }

    public func createWorkspace(name: String, projectIDs: [Int64], createdFrom: WorkspaceSource, isDefault: Bool = false, sourceProjectID: Int64? = nil) throws -> Workspace {
        let existingNames = Set(try listWorkspaces().map(\.slug))
        let slugBase = slugify(name)
        let slug = uniqueName(base: slugBase.isEmpty ? "workspace" : slugBase, existing: existingNames)
        let now = Date()
        let statement = try database.prepare(
            """
            INSERT INTO workspaces (uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(UUID().uuidString, at: 1, in: statement)
        try bind(name, at: 2, in: statement)
        try bind(slug, at: 3, in: statement)
        try bind(createdFrom.rawValue, at: 4, in: statement)
        try bind(isDefault, at: 5, in: statement)
        try bind(sourceProjectID, at: 6, in: statement)
        try bind(iso8601String(from: now), at: 7, in: statement)
        try bind(iso8601String(from: now), at: 8, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        let workspaceID = database.lastInsertedRowID()
        for (index, projectID) in projectIDs.enumerated() {
            try ensureWorkspaceProjectLink(workspaceID: workspaceID, projectID: projectID, index: index)
        }
        return try workspace(id: workspaceID)!
    }

    public func deleteWorkspace(id: Int64) throws {
        let statement = try database.prepare("DELETE FROM workspaces WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func deleteProject(id: Int64) throws {
        let statement = try database.prepare("DELETE FROM projects WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func listWorkspaces() throws -> [Workspace] {
        let statement = try database.prepare(
            """
            SELECT id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at
            FROM workspaces
            ORDER BY name COLLATE NOCASE, id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [Workspace] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeWorkspace(from: statement))
        }
        return try hydrateWorkspaces(result)
    }

    public func listWorkspaceDetails() throws -> [WorkspaceDetails] {
        let workspaces = try listWorkspaces()
        guard !workspaces.isEmpty else {
            return []
        }

        let projectsByID = Dictionary(uniqueKeysWithValues: try listProjects().map { ($0.rawID, $0) })
        let sessionsByWorkspaceID = Dictionary(grouping: try listSessions(), by: \.workspaceID)

        return workspaces.map { workspace in
            let projects = workspace.projectIDs.compactMap { projectsByID[$0] }
            let sessions = sessionsByWorkspaceID[workspace.rawID] ?? []
            return WorkspaceDetails(workspace: workspace, projects: projects, sessions: sessions)
        }
    }

    public func workspace(matching token: String) throws -> Workspace? {
        if let refID = parseRef(token, prefix: "workspace") {
            return try workspace(id: refID)
        }

        if isGlobalWorkspaceAlias(token) {
            return try globalWorkspace()
        }

        if let uuid = UUID(uuidString: token) {
            let statement = try database.prepare(
                "SELECT id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at FROM workspaces WHERE uuid = ? LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try bind(uuid.uuidString, at: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return try hydrateWorkspace(try decodeWorkspace(from: statement))
            }
            return nil
        }

        let statement = try database.prepare(
            "SELECT id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at FROM workspaces WHERE name = ? COLLATE NOCASE OR slug = ? COLLATE NOCASE LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(token, at: 1, in: statement)
        try bind(token, at: 2, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try hydrateWorkspace(try decodeWorkspace(from: statement))
        }
        return nil
    }

    public func workspaceDetails(matching token: String) throws -> WorkspaceDetails? {
        guard let workspace = try workspace(matching: token) else {
            return nil
        }
        return try workspaceDetails(workspace)
    }

    public func workspaceDetails(id: Int64) throws -> WorkspaceDetails? {
        guard let workspace = try workspace(id: id) else {
            return nil
        }
        return try workspaceDetails(workspace)
    }

    public func createSession(workspaceID: Int64, name: String, slug: String, sessionRootPath: String, layoutName: String?) throws -> Session {
        let now = Date()
        let sessionNumber = try nextSessionNumber(workspaceID: workspaceID)
        let statement = try database.prepare(
            """
            INSERT INTO sessions (uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(UUID().uuidString, at: 1, in: statement)
        try bind(workspaceID, at: 2, in: statement)
        try bind(Int64(sessionNumber), at: 3, in: statement)
        try bind(name, at: 4, in: statement)
        try bind(slug, at: 5, in: statement)
        try bind(SessionStatus.active.rawValue, at: 6, in: statement)
        try bind(sessionRootPath, at: 7, in: statement)
        try bind(layoutName, at: 8, in: statement)
        try bind(iso8601String(from: now), at: 9, in: statement)
        try bind(iso8601String(from: now), at: 10, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        return try session(id: database.lastInsertedRowID())!
    }

    public func renameSession(id: Int64, name: String, slug: String) throws -> Session {
        let statement = try database.prepare(
            """
            UPDATE sessions
            SET name = ?,
                slug = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(name, at: 1, in: statement)
        try bind(slug, at: 2, in: statement)
        try bind(id, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
        return try session(id: id)!
    }

    public func updateSessionLayoutName(id: Int64, layoutName: String?) throws -> Session {
        let statement = try database.prepare(
            """
            UPDATE sessions
            SET layout_name = ?,
                status = ?,
                last_active_at = ?,
                closed_at = NULL
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(layoutName, at: 1, in: statement)
        try bind(SessionStatus.active.rawValue, at: 2, in: statement)
        try bind(iso8601String(from: Date()), at: 3, in: statement)
        try bind(id, at: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
        return try session(id: id)!
    }

    public func deleteSessionLayout(sessionID: Int64) throws {
        let statement = try database.prepare("DELETE FROM panes WHERE session_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func markAllActiveSessionsRestorable() throws {
        let statement = try database.prepare(
            "UPDATE sessions SET status = ? WHERE status = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(SessionStatus.restorable.rawValue, at: 1, in: statement)
        try bind(SessionStatus.active.rawValue, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func updateSessionLifecycle(sessionID: Int64, status: SessionStatus, lastActiveAt: Date? = nil, closedAt: Date? = nil) throws {
        let statement = try database.prepare(
            """
            UPDATE sessions
            SET status = ?,
                last_active_at = COALESCE(?, last_active_at),
                closed_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(status.rawValue, at: 1, in: statement)
        try bind(lastActiveAt.map(iso8601String(from:)), at: 2, in: statement)
        try bind(closedAt.map(iso8601String(from:)), at: 3, in: statement)
        try bind(sessionID, at: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func deleteSession(id: Int64) throws {
        let statement = try database.prepare("DELETE FROM sessions WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func updateTabRestorationState(tabID: Int64, title: String? = nil, cwd: String? = nil, runtimeStatus: RuntimeStatus? = nil, preserveExited: Bool = false) throws {
        let runtimeStatusSQL: String
        if preserveExited {
            // Don't overwrite 'exited' — a late-arriving checkpoint must not resurrect a dead tab.
            runtimeStatusSQL = "runtime_status = CASE WHEN runtime_status = 'exited' THEN 'exited' ELSE COALESCE(?, runtime_status) END"
        } else {
            runtimeStatusSQL = "runtime_status = COALESCE(?, runtime_status)"
        }
        let statement = try database.prepare(
            """
            UPDATE tabs
            SET title = COALESCE(?, title),
                cwd = COALESCE(?, cwd),
                \(runtimeStatusSQL)
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(title, at: 1, in: statement)
        try bind(cwd, at: 2, in: statement)
        try bind(runtimeStatus?.rawValue, at: 3, in: statement)
        try bind(tabID, at: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func markTabAttention(tabID: Int64, message: String?) throws {
        let statement = try database.prepare(
            "UPDATE tabs SET needs_attention = 1, attention_message = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(message, at: 1, in: statement)
        try bind(tabID, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func clearTabAttention(tabID: Int64) throws {
        let statement = try database.prepare(
            "UPDATE tabs SET needs_attention = 0, attention_message = NULL WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(tabID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    /// Returns a dictionary of session raw IDs to the count of tabs that need attention in that session.
    public func attentionCountsBySession() throws -> [Int64: Int] {
        let statement = try database.prepare(
            "SELECT session_id, COUNT(*) FROM tabs WHERE needs_attention = 1 GROUP BY session_id"
        )
        defer { sqlite3_finalize(statement) }
        var result: [Int64: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = sqlite3_column_int64(statement, 0)
            let count = Int(sqlite3_column_int64(statement, 1))
            result[sessionID] = count
        }
        return result
    }

    public func splitPane(paneID: Int64, direction: SplitDirection, sourceTabID: Int64? = nil) throws -> SessionBundle {
        let sessionID = try database.transaction { () -> Int64 in
            guard let targetPane = try pane(id: paneID) else {
                throw ShuttleError.notFound(entity: "Pane", token: Pane.makeRef(paneID))
            }

            guard try childPanes(parentPaneID: targetPane.rawID).isEmpty else {
                throw ShuttleError.invalidArguments("Can only split a leaf pane")
            }

            guard let sourceTab = try splitSourceTab(for: targetPane, sourceTabID: sourceTabID) else {
                throw ShuttleError.invalidArguments("Cannot split pane \(Pane.makeRef(paneID)) because it has no tabs")
            }

            let newParent = try createPane(
                sessionID: targetPane.sessionID,
                parentPaneID: targetPane.parentPaneID,
                splitDirection: direction,
                ratio: 0.5,
                positionIndex: targetPane.positionIndex
            )

            let newPanePosition = splitPlacesNewPaneFirst(direction) ? 0 : 1
            let existingPanePosition = newPanePosition == 0 ? 1 : 0

            try updatePaneStructure(
                paneID: targetPane.rawID,
                parentPaneID: newParent.rawID,
                splitDirection: nil,
                ratio: nil,
                positionIndex: existingPanePosition
            )

            let newPane = try createPane(
                sessionID: targetPane.sessionID,
                parentPaneID: newParent.rawID,
                splitDirection: nil,
                ratio: nil,
                positionIndex: newPanePosition
            )

            _ = try createTab(
                paneID: newPane.rawID,
                title: sourceTab.title,
                cwd: sourceTab.cwd,
                projectID: sourceTab.projectID,
                command: nil,
                envJSON: nil,
                runtimeStatus: .placeholder,
                positionIndex: 0
            )

            try updateSessionLifecycle(sessionID: targetPane.sessionID, status: .active, lastActiveAt: Date(), closedAt: nil)
            return targetPane.sessionID
        }

        guard let bundle = try sessionBundle(id: sessionID) else {
            throw ShuttleError.notFound(entity: "Session", token: Session.makeRef(sessionID))
        }
        return bundle
    }

    public func updatePaneRatio(paneID: Int64, ratio: Double) throws {
        guard let targetPane = try pane(id: paneID) else {
            throw ShuttleError.notFound(entity: "Pane", token: Pane.makeRef(paneID))
        }
        let normalizedRatio = normalizedPaneRatio(ratio)
        let children = try childPanes(parentPaneID: targetPane.rawID)
        guard children.count >= 2 else {
            throw ShuttleError.invalidArguments("Pane \(Pane.makeRef(paneID)) is not a split container")
        }

        let statement = try database.prepare(
            "UPDATE panes SET ratio = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(normalizedRatio, at: 1, in: statement)
        try bind(paneID, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        try updateSessionLifecycle(sessionID: targetPane.sessionID, status: .active, lastActiveAt: Date(), closedAt: nil)
    }

    public func openTab(paneID: Int64, sourceTabID: Int64? = nil) throws -> SessionBundle {
        let sessionID = try database.transaction { () -> Int64 in
            guard let targetPane = try pane(id: paneID) else {
                throw ShuttleError.notFound(entity: "Pane", token: Pane.makeRef(paneID))
            }
            let sourceTab = try splitSourceTab(for: targetPane, sourceTabID: sourceTabID)
            let template = try sourceTab.map {
                (title: $0.title, cwd: $0.cwd, projectID: $0.projectID)
            } ?? defaultTabTemplate(sessionID: targetPane.sessionID)

            _ = try createTab(
                paneID: targetPane.rawID,
                title: template.title,
                cwd: template.cwd,
                projectID: template.projectID,
                command: nil,
                envJSON: nil,
                runtimeStatus: .placeholder,
                positionIndex: try nextTabPositionIndex(paneID: targetPane.rawID)
            )

            try updateSessionLifecycle(sessionID: targetPane.sessionID, status: .active, lastActiveAt: Date(), closedAt: nil)
            return targetPane.sessionID
        }

        guard let bundle = try sessionBundle(id: sessionID) else {
            throw ShuttleError.notFound(entity: "Session", token: Session.makeRef(sessionID))
        }
        return bundle
    }

    public func closeTab(tabID: Int64) throws -> SessionBundle {
        let sessionID = try database.transaction { () -> Int64 in
            guard let targetTab = try tab(id: tabID) else {
                throw ShuttleError.notFound(entity: "Tab", token: Tab.makeRef(tabID))
            }
            guard let targetPane = try pane(id: targetTab.paneID) else {
                throw ShuttleError.notFound(entity: "Pane", token: Pane.makeRef(targetTab.paneID))
            }

            let statement = try database.prepare("DELETE FROM tabs WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(tabID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
            }

            let remainingTabsInPane = try tabsForPaneID(targetPane.rawID)
            if remainingTabsInPane.isEmpty {
                let remainingSessionTabs = try listTabs(sessionID: targetPane.sessionID)
                if !remainingSessionTabs.isEmpty {
                    try removeLeafPaneAndCollapse(paneID: targetPane.rawID)
                }
            } else {
                try reindexTabs(paneID: targetPane.rawID)
            }

            try updateSessionLifecycle(sessionID: targetPane.sessionID, status: .active, lastActiveAt: Date(), closedAt: nil)
            return targetPane.sessionID
        }

        guard let bundle = try sessionBundle(id: sessionID) else {
            throw ShuttleError.notFound(entity: "Session", token: Session.makeRef(sessionID))
        }
        return bundle
    }

    public func listSessions(workspaceID: Int64? = nil) throws -> [Session] {
        let sql: String
        if workspaceID != nil {
            sql = "SELECT id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at FROM sessions WHERE workspace_id = ? ORDER BY created_at DESC, id DESC"
        } else {
            sql = "SELECT id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at FROM sessions ORDER BY created_at DESC, id DESC"
        }

        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let workspaceID {
            try bind(workspaceID, at: 1, in: statement)
        }

        var result: [Session] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeSession(from: statement))
        }
        return result
    }

    public func session(matching token: String) throws -> Session? {
        if let refID = parseRef(token, prefix: "session") {
            return try session(id: refID)
        }

        if let scopedRef = parseScopedSessionRef(token) {
            let statement = try database.prepare(
                "SELECT id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at FROM sessions WHERE workspace_id = ? AND session_number = ? LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try bind(scopedRef.workspaceID, at: 1, in: statement)
            try bind(Int64(scopedRef.sessionNumber), at: 2, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return try decodeSession(from: statement)
            }
            return nil
        }

        if let uuid = UUID(uuidString: token) {
            let statement = try database.prepare(
                "SELECT id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at FROM sessions WHERE uuid = ? LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try bind(uuid.uuidString, at: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return try decodeSession(from: statement)
            }
            return nil
        }

        let statement = try database.prepare(
            "SELECT id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at FROM sessions WHERE name = ? COLLATE NOCASE OR slug = ? COLLATE NOCASE ORDER BY id DESC LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(token, at: 1, in: statement)
        try bind(token, at: 2, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try decodeSession(from: statement)
        }
        return nil
    }

    public func sessionBundle(matching token: String) throws -> SessionBundle? {
        guard let session = try session(matching: token) else {
            return nil
        }
        return try sessionBundle(id: session.rawID)
    }

    public func sessionBundle(id: Int64) throws -> SessionBundle? {
        guard let session = try session(id: id), let workspace = try workspace(id: session.workspaceID) else {
            return nil
        }
        let sessionProjects = try listSessionProjects(sessionID: id)
        let projects = try sessionProjects.compactMap { try project(id: $0.projectID) }
        let panes = try listPanes(sessionID: id)
        let tabs = try listTabs(sessionID: id)
        return SessionBundle(session: session, workspace: workspace, projects: projects, sessionProjects: sessionProjects, panes: panes, tabs: tabs)
    }

    public func insertSessionProject(_ sessionProject: SessionProject) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO session_projects
              (session_id, project_id, checkout_type, checkout_path, metadata_json)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(sessionProject.sessionID, at: 1, in: statement)
        try bind(sessionProject.projectID, at: 2, in: statement)
        try bind(sessionProject.checkoutType.rawValue, at: 3, in: statement)
        try bind(sessionProject.checkoutPath, at: 4, in: statement)
        try bind(sessionProject.metadataJSON, at: 5, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    public func createPane(sessionID: Int64, parentPaneID: Int64? = nil, splitDirection: SplitDirection? = nil, ratio: Double? = nil, positionIndex: Int = 0) throws -> Pane {
        let paneNumber = try nextPaneNumber(sessionID: sessionID)
        let statement = try database.prepare(
            "INSERT INTO panes (session_id, pane_number, parent_pane_id, split_direction, ratio, position_index) VALUES (?, ?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        try bind(sessionID, at: 1, in: statement)
        try bind(Int64(paneNumber), at: 2, in: statement)
        try bind(parentPaneID, at: 3, in: statement)
        try bind(splitDirection?.rawValue, at: 4, in: statement)
        try bind(ratio, at: 5, in: statement)
        try bind(Int64(positionIndex), at: 6, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        return try pane(id: database.lastInsertedRowID())!
    }

    public func createTab(paneID: Int64, title: String, cwd: String, projectID: Int64?, command: String?, envJSON: String?, runtimeStatus: RuntimeStatus, positionIndex: Int) throws -> Tab {
        guard let targetPane = try pane(id: paneID) else {
            throw ShuttleError.notFound(entity: "Pane", token: Pane.makeRef(paneID))
        }
        let tabNumber = try nextTabNumber(sessionID: targetPane.sessionID)
        let statement = try database.prepare(
            "INSERT INTO tabs (session_id, pane_id, tab_number, title, cwd, project_id, command, env_json, runtime_status, position_index, needs_attention, attention_message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL)"
        )
        defer { sqlite3_finalize(statement) }

        try bind(targetPane.sessionID, at: 1, in: statement)
        try bind(paneID, at: 2, in: statement)
        try bind(Int64(tabNumber), at: 3, in: statement)
        try bind(title, at: 4, in: statement)
        try bind(cwd, at: 5, in: statement)
        try bind(projectID, at: 6, in: statement)
        try bind(command, at: 7, in: statement)
        try bind(envJSON, at: 8, in: statement)
        try bind(runtimeStatus.rawValue, at: 9, in: statement)
        try bind(Int64(positionIndex), at: 10, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }

        return try tab(id: database.lastInsertedRowID())!
    }

    public func appendTab(
        sessionID: Int64,
        preferredPaneID: Int64? = nil,
        title: String,
        cwd: String,
        projectID: Int64?,
        command: String? = nil,
        envJSON: String? = nil,
        runtimeStatus: RuntimeStatus = .placeholder
    ) throws -> Tab {
        let targetPane = try preferredLeafPane(sessionID: sessionID, preferredPaneID: preferredPaneID)
        let tab = try createTab(
            paneID: targetPane.rawID,
            title: title,
            cwd: cwd,
            projectID: projectID,
            command: command,
            envJSON: envJSON,
            runtimeStatus: runtimeStatus,
            positionIndex: try nextTabPositionIndex(paneID: targetPane.rawID)
        )
        try updateSessionLifecycle(sessionID: sessionID, status: .active, lastActiveAt: Date(), closedAt: nil)
        return tab
    }

    public func listSessionProjects(sessionID: Int64) throws -> [SessionProject] {
        let statement = try database.prepare(
            "SELECT session_id, project_id, checkout_type, checkout_path, metadata_json FROM session_projects WHERE session_id = ? ORDER BY project_id ASC"
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)

        var result: [SessionProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                SessionProject(
                    sessionID: sqlite3_column_int64(statement, 0),
                    projectID: sqlite3_column_int64(statement, 1),
                    checkoutType: CheckoutType(rawValue: text(at: 2, from: statement) ?? CheckoutType.direct.rawValue) ?? .direct,
                    checkoutPath: text(at: 3, from: statement) ?? "",
                    metadataJSON: text(at: 4, from: statement)
                )
            )
        }
        return result
    }

    public func listPanes(sessionID: Int64) throws -> [Pane] {
        let statement = try database.prepare(
            "SELECT panes.id, panes.session_id, sessions.workspace_id, sessions.session_number, panes.pane_number, panes.parent_pane_id, panes.split_direction, panes.ratio, panes.position_index FROM panes INNER JOIN sessions ON sessions.id = panes.session_id WHERE panes.session_id = ? ORDER BY panes.position_index ASC, panes.id ASC"
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)

        var result: [Pane] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodePane(from: statement))
        }
        return result
    }

    public func listTabs(sessionID: Int64) throws -> [Tab] {
        let statement = try database.prepare(
            """
            SELECT tabs.id, tabs.session_id, sessions.workspace_id, sessions.session_number, tabs.pane_id, tabs.tab_number, tabs.title, tabs.cwd, tabs.project_id, tabs.command, tabs.env_json, tabs.runtime_status, tabs.position_index, tabs.needs_attention, tabs.attention_message
            FROM tabs
            INNER JOIN sessions ON sessions.id = tabs.session_id
            WHERE tabs.session_id = ?
            ORDER BY tabs.pane_id ASC, tabs.position_index ASC, tabs.id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)

        var result: [Tab] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeTab(from: statement))
        }
        return result
    }

    public func projectsForWorkspaceID(_ workspaceID: Int64) throws -> [Project] {
        let statement = try database.prepare(
            """
            SELECT p.id, p.uuid, p.name, p.path, p.kind, p.default_workspace_id, p.created_at, p.updated_at
            FROM workspace_projects wp
            INNER JOIN projects p ON p.id = wp.project_id
            WHERE wp.workspace_id = ?
            ORDER BY wp.position_index ASC, p.name COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(workspaceID, at: 1, in: statement)

        var result: [Project] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeProject(from: statement))
        }
        return result
    }

    private func ensureWorkspaceProjectLink(workspaceID: Int64, projectID: Int64, index: Int? = nil) throws {
        let position: Int
        if let index {
            position = index
        } else {
            position = try nextWorkspaceProjectIndex(workspaceID: workspaceID)
        }
        let statement = try database.prepare(
            "INSERT OR IGNORE INTO workspace_projects (workspace_id, project_id, position_index) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(workspaceID, at: 1, in: statement)
        try bind(projectID, at: 2, in: statement)
        try bind(Int64(position), at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    private func nextWorkspaceProjectIndex(workspaceID: Int64) throws -> Int {
        let statement = try database.prepare("SELECT COALESCE(MAX(position_index), -1) + 1 FROM workspace_projects WHERE workspace_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(workspaceID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func nextSessionNumber(workspaceID: Int64) throws -> Int {
        let statement = try database.prepare("SELECT COALESCE(MAX(session_number), 0) + 1 FROM sessions WHERE workspace_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(workspaceID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func nextPaneNumber(sessionID: Int64) throws -> Int {
        let statement = try database.prepare("SELECT COALESCE(MAX(pane_number), 0) + 1 FROM panes WHERE session_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func reindexWorkspaceProjects(workspaceID: Int64) throws {
        let statement = try database.prepare(
            "SELECT project_id FROM workspace_projects WHERE workspace_id = ? ORDER BY position_index ASC, project_id ASC"
        )
        defer { sqlite3_finalize(statement) }
        try bind(workspaceID, at: 1, in: statement)

        var projectIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            projectIDs.append(sqlite3_column_int64(statement, 0))
        }

        for (index, projectID) in projectIDs.enumerated() {
            let update = try database.prepare(
                "UPDATE workspace_projects SET position_index = ? WHERE workspace_id = ? AND project_id = ?"
            )
            defer { sqlite3_finalize(update) }
            try bind(Int64(index), at: 1, in: update)
            try bind(workspaceID, at: 2, in: update)
            try bind(projectID, at: 3, in: update)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
            }
        }
    }

    private func touchWorkspace(id: Int64) throws {
        let statement = try database.prepare(
            "UPDATE workspaces SET updated_at = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(iso8601String(from: Date()), at: 1, in: statement)
        try bind(id, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    private func setProjectDefaultWorkspace(projectID: Int64, workspaceID: Int64) throws {
        let statement = try database.prepare("UPDATE projects SET default_workspace_id = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(workspaceID, at: 1, in: statement)
        try bind(iso8601String(from: Date()), at: 2, in: statement)
        try bind(projectID, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    private func defaultWorkspaceForSourceProject(_ projectID: Int64) throws -> Workspace? {
        let statement = try database.prepare(
            "SELECT id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at FROM workspaces WHERE is_default = 1 AND source_project_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(projectID, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try hydrateWorkspace(try decodeWorkspace(from: statement))
        }
        return nil
    }

    private func globalWorkspace() throws -> Workspace? {
        let statement = try database.prepare(
            "SELECT id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at FROM workspaces WHERE created_from = ? ORDER BY id ASC LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(WorkspaceSource.global.rawValue, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try hydrateWorkspace(try decodeWorkspace(from: statement))
        }
        return nil
    }

    private func isGlobalWorkspaceAlias(_ token: String) -> Bool {
        Self.globalWorkspaceAliases.contains(token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func projectByPath(_ path: String) throws -> Project? {
        let normalizedPath = URL(fileURLWithPath: expandedPath(path)).standardizedFileURL.path
        let statement = try database.prepare(
            "SELECT id, uuid, name, path, kind, default_workspace_id, created_at, updated_at FROM projects WHERE path = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(normalizedPath, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try decodeProject(from: statement)
        }
        return nil
    }

    private func project(id: Int64) throws -> Project? {
        let statement = try database.prepare(
            "SELECT id, uuid, name, path, kind, default_workspace_id, created_at, updated_at FROM projects WHERE id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try decodeProject(from: statement)
        }
        return nil
    }

    public func workspace(id: Int64) throws -> Workspace? {
        let statement = try database.prepare(
            "SELECT id, uuid, name, slug, created_from, is_default, source_project_id, created_at, updated_at FROM workspaces WHERE id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try hydrateWorkspace(try decodeWorkspace(from: statement))
        }
        return nil
    }

    private func session(id: Int64) throws -> Session? {
        let statement = try database.prepare(
            "SELECT id, uuid, workspace_id, session_number, name, slug, status, session_root_path, layout_name, created_at, last_active_at, closed_at FROM sessions WHERE id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try decodeSession(from: statement)
        }
        return nil
    }

    private func pane(id: Int64) throws -> Pane? {
        let statement = try database.prepare(
            "SELECT panes.id, panes.session_id, sessions.workspace_id, sessions.session_number, panes.pane_number, panes.parent_pane_id, panes.split_direction, panes.ratio, panes.position_index FROM panes INNER JOIN sessions ON sessions.id = panes.session_id WHERE panes.id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try decodePane(from: statement)
        }
        return nil
    }

    private func tab(id: Int64) throws -> Tab? {
        let statement = try database.prepare(
            "SELECT tabs.id, tabs.session_id, sessions.workspace_id, sessions.session_number, tabs.pane_id, tabs.tab_number, tabs.title, tabs.cwd, tabs.project_id, tabs.command, tabs.env_json, tabs.runtime_status, tabs.position_index, tabs.needs_attention, tabs.attention_message FROM tabs INNER JOIN sessions ON sessions.id = tabs.session_id WHERE tabs.id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return try decodeTab(from: statement)
        }
        return nil
    }

    private func childPanes(parentPaneID: Int64?) throws -> [Pane] {
        let sql: String
        if parentPaneID == nil {
            sql = "SELECT panes.id, panes.session_id, sessions.workspace_id, sessions.session_number, panes.pane_number, panes.parent_pane_id, panes.split_direction, panes.ratio, panes.position_index FROM panes INNER JOIN sessions ON sessions.id = panes.session_id WHERE panes.parent_pane_id IS NULL ORDER BY panes.position_index ASC, panes.id ASC"
        } else {
            sql = "SELECT panes.id, panes.session_id, sessions.workspace_id, sessions.session_number, panes.pane_number, panes.parent_pane_id, panes.split_direction, panes.ratio, panes.position_index FROM panes INNER JOIN sessions ON sessions.id = panes.session_id WHERE panes.parent_pane_id = ? ORDER BY panes.position_index ASC, panes.id ASC"
        }

        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let parentPaneID {
            try bind(parentPaneID, at: 1, in: statement)
        }

        var result: [Pane] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodePane(from: statement))
        }
        return result
    }

    private func tabsForPaneID(_ paneID: Int64) throws -> [Tab] {
        let statement = try database.prepare(
            "SELECT tabs.id, tabs.session_id, sessions.workspace_id, sessions.session_number, tabs.pane_id, tabs.tab_number, tabs.title, tabs.cwd, tabs.project_id, tabs.command, tabs.env_json, tabs.runtime_status, tabs.position_index, tabs.needs_attention, tabs.attention_message FROM tabs INNER JOIN sessions ON sessions.id = tabs.session_id WHERE tabs.pane_id = ? ORDER BY tabs.position_index ASC, tabs.id ASC"
        )
        defer { sqlite3_finalize(statement) }
        try bind(paneID, at: 1, in: statement)

        var result: [Tab] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeTab(from: statement))
        }
        return result
    }

    private func nextTabPositionIndex(paneID: Int64) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(position_index), -1) + 1 FROM tabs WHERE pane_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(paneID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func nextTabNumber(sessionID: Int64) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(tab_number), 0) + 1 FROM tabs WHERE session_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func preferredLeafPane(sessionID: Int64, preferredPaneID: Int64?) throws -> Pane {
        let leafPanes = try leafPanes(sessionID: sessionID)
        if let preferredPaneID,
           let preferredPane = leafPanes.first(where: { $0.rawID == preferredPaneID }) {
            return preferredPane
        }
        if let firstLeafPane = leafPanes.first {
            return firstLeafPane
        }
        throw ShuttleError.invalidArguments("Session \(Session.makeRef(sessionID)) has no leaf panes")
    }

    private func leafPanes(sessionID: Int64) throws -> [Pane] {
        let panes = try listPanes(sessionID: sessionID)
        let parentIDs = Set(panes.compactMap(\.parentPaneID))
        return panes.filter { !parentIDs.contains($0.rawID) }.sorted { lhs, rhs in
            if lhs.positionIndex == rhs.positionIndex {
                return lhs.rawID < rhs.rawID
            }
            return lhs.positionIndex < rhs.positionIndex
        }
    }

    private func reindexTabs(paneID: Int64) throws {
        let tabs = try tabsForPaneID(paneID)
        for (index, tab) in tabs.enumerated() where tab.positionIndex != index {
            let statement = try database.prepare("UPDATE tabs SET position_index = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(Int64(index), at: 1, in: statement)
            try bind(tab.rawID, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
            }
        }
    }

    func defaultTabTemplate(sessionID: Int64) throws -> (title: String, cwd: String, projectID: Int64?) {
        guard let session = try session(id: sessionID) else {
            throw ShuttleError.notFound(entity: "Session", token: Session.makeRef(sessionID))
        }

        if let globalTemplate = try globalDefaultTabTemplate(for: session) {
            return globalTemplate
        }

        if let singleProjectTemplate = try singleProjectDefaultTabTemplate(for: session) {
            return singleProjectTemplate
        }

        let fallbackTitle = URL(fileURLWithPath: session.sessionRootPath).lastPathComponent
        return (title: fallbackTitle.isEmpty ? "shell" : fallbackTitle, cwd: session.sessionRootPath, projectID: nil)
    }

    private func globalDefaultTabTemplate(for session: Session) throws -> (title: String, cwd: String, projectID: Int64?)? {
        guard let workspace = try workspace(id: session.workspaceID), workspace.createdFrom == .global else {
            return nil
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return (title: "~", cwd: homePath, projectID: nil)
    }

    private func singleProjectDefaultTabTemplate(for session: Session) throws -> (title: String, cwd: String, projectID: Int64?)? {
        let sessionProjects = try listSessionProjects(sessionID: session.rawID)
        guard sessionProjects.count == 1, let sessionProject = sessionProjects.first else {
            return nil
        }

        let trimmedCheckoutPath = sessionProject.checkoutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = trimmedCheckoutPath.isEmpty ? session.sessionRootPath : trimmedCheckoutPath

        let trimmedProjectName = try project(id: sessionProject.projectID)?
            .name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle: String
        if let trimmedProjectName, !trimmedProjectName.isEmpty {
            fallbackTitle = trimmedProjectName
        } else {
            fallbackTitle = URL(fileURLWithPath: cwd).lastPathComponent
        }

        return (
            title: fallbackTitle.isEmpty ? "shell" : fallbackTitle,
            cwd: cwd,
            projectID: sessionProject.projectID
        )
    }

    private func splitSourceTab(for pane: Pane, sourceTabID: Int64?) throws -> Tab? {
        if let sourceTabID,
           let tab = try tab(id: sourceTabID),
           tab.paneID == pane.rawID {
            return tab
        }
        return try tabsForPaneID(pane.rawID).first
    }

    private func updatePaneStructure(
        paneID: Int64,
        parentPaneID: Int64?,
        splitDirection: SplitDirection?,
        ratio: Double?,
        positionIndex: Int
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE panes
            SET parent_pane_id = ?,
                split_direction = ?,
                ratio = ?,
                position_index = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(parentPaneID, at: 1, in: statement)
        try bind(splitDirection?.rawValue, at: 2, in: statement)
        try bind(ratio, at: 3, in: statement)
        try bind(Int64(positionIndex), at: 4, in: statement)
        try bind(paneID, at: 5, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    private func updatePaneParentAndPosition(
        paneID: Int64,
        parentPaneID: Int64?,
        positionIndex: Int
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE panes
            SET parent_pane_id = ?,
                position_index = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(parentPaneID, at: 1, in: statement)
        try bind(Int64(positionIndex), at: 2, in: statement)
        try bind(paneID, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    private func deletePaneRow(paneID: Int64) throws {
        let statement = try database.prepare("DELETE FROM panes WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(paneID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ShuttleError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
    }

    private func reindexChildPanes(parentPaneID: Int64?) throws {
        let panes = try childPanes(parentPaneID: parentPaneID)
        for (index, pane) in panes.enumerated() where pane.positionIndex != index {
            try updatePaneParentAndPosition(paneID: pane.rawID, parentPaneID: parentPaneID, positionIndex: index)
        }
    }

    private func removeLeafPaneAndCollapse(paneID: Int64) throws {
        guard let doomedPane = try pane(id: paneID) else { return }
        guard try childPanes(parentPaneID: doomedPane.rawID).isEmpty else {
            throw ShuttleError.invalidArguments("Cannot remove a non-leaf pane")
        }

        let parentPaneID = doomedPane.parentPaneID
        try deletePaneRow(paneID: doomedPane.rawID)
        try reindexChildPanes(parentPaneID: parentPaneID)
        if let parentPaneID {
            try collapseSplitContainerIfNeeded(paneID: parentPaneID)
        }
    }

    private func collapseSplitContainerIfNeeded(paneID: Int64) throws {
        guard let container = try pane(id: paneID) else { return }
        let children = try childPanes(parentPaneID: container.rawID)

        if children.isEmpty {
            let grandparentPaneID = container.parentPaneID
            try deletePaneRow(paneID: container.rawID)
            try reindexChildPanes(parentPaneID: grandparentPaneID)
            if let grandparentPaneID {
                try collapseSplitContainerIfNeeded(paneID: grandparentPaneID)
            }
            return
        }

        guard children.count == 1 else { return }
        let survivingChild = children[0]
        let grandparentPaneID = container.parentPaneID
        try updatePaneParentAndPosition(
            paneID: survivingChild.rawID,
            parentPaneID: grandparentPaneID,
            positionIndex: container.positionIndex
        )
        try deletePaneRow(paneID: container.rawID)
        try reindexChildPanes(parentPaneID: grandparentPaneID)
        if let grandparentPaneID {
            try collapseSplitContainerIfNeeded(paneID: grandparentPaneID)
        }
    }

    private func splitPlacesNewPaneFirst(_ direction: SplitDirection) -> Bool {
        switch direction {
        case .left, .up:
            return true
        case .right, .down:
            return false
        }
    }

    private func normalizedPaneRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0.1), 0.9)
    }

    private func decodeProject(from statement: OpaquePointer) throws -> Project {
        Project(
            rawID: sqlite3_column_int64(statement, 0),
            uuid: UUID(uuidString: text(at: 1, from: statement) ?? "") ?? UUID(),
            name: text(at: 2, from: statement) ?? "",
            path: text(at: 3, from: statement) ?? "",
            kind: ProjectKind(rawValue: text(at: 4, from: statement) ?? ProjectKind.normal.rawValue) ?? .normal,
            defaultWorkspaceID: int64(at: 5, from: statement),
            createdAt: parseDate(text(at: 6, from: statement) ?? ""),
            updatedAt: parseDate(text(at: 7, from: statement) ?? "")
        )
    }

    private func decodeWorkspace(from statement: OpaquePointer) throws -> Workspace {
        Workspace(
            rawID: sqlite3_column_int64(statement, 0),
            uuid: UUID(uuidString: text(at: 1, from: statement) ?? "") ?? UUID(),
            name: text(at: 2, from: statement) ?? "",
            slug: text(at: 3, from: statement) ?? "",
            createdFrom: WorkspaceSource(rawValue: text(at: 4, from: statement) ?? WorkspaceSource.auto.rawValue) ?? .auto,
            isDefault: sqlite3_column_int(statement, 5) != 0,
            sourceProjectID: int64(at: 6, from: statement),
            projectIDs: [],
            createdAt: parseDate(text(at: 7, from: statement) ?? ""),
            updatedAt: parseDate(text(at: 8, from: statement) ?? "")
        )
    }

    private func workspaceProjectIDsByWorkspaceID(_ workspaceIDs: [Int64]) throws -> [Int64: [Int64]] {
        guard !workspaceIDs.isEmpty else {
            return [:]
        }

        let placeholders = Array(repeating: "?", count: workspaceIDs.count).joined(separator: ", ")
        let statement = try database.prepare(
            """
            SELECT wp.workspace_id, wp.project_id
            FROM workspace_projects wp
            INNER JOIN projects p ON p.id = wp.project_id
            WHERE wp.workspace_id IN (
            \(placeholders)
            )
            ORDER BY wp.workspace_id ASC, wp.position_index ASC, p.name COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }

        for (index, workspaceID) in workspaceIDs.enumerated() {
            try bind(workspaceID, at: Int32(index + 1), in: statement)
        }

        var result: [Int64: [Int64]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let workspaceID = sqlite3_column_int64(statement, 0)
            let projectID = sqlite3_column_int64(statement, 1)
            result[workspaceID, default: []].append(projectID)
        }
        return result
    }

    private func hydrateWorkspace(_ workspace: Workspace) throws -> Workspace {
        try hydrateWorkspaces([workspace]).first ?? workspace
    }

    private func hydrateWorkspaces(_ workspaces: [Workspace]) throws -> [Workspace] {
        guard !workspaces.isEmpty else {
            return []
        }

        let projectIDsByWorkspaceID = try workspaceProjectIDsByWorkspaceID(workspaces.map(\.rawID))
        return workspaces.map { workspace in
            var workspace = workspace
            workspace.projectIDs = projectIDsByWorkspaceID[workspace.rawID] ?? []
            return workspace
        }
    }

    private func workspaceDetails(_ workspace: Workspace) throws -> WorkspaceDetails {
        let projects = try projectsForWorkspaceID(workspace.rawID)
        var hydratedWorkspace = workspace
        hydratedWorkspace.projectIDs = projects.map(\.rawID)
        let sessions = try listSessions(workspaceID: workspace.rawID)
        return WorkspaceDetails(workspace: hydratedWorkspace, projects: projects, sessions: sessions)
    }

    private func decodeSession(from statement: OpaquePointer) throws -> Session {
        Session(
            rawID: sqlite3_column_int64(statement, 0),
            uuid: UUID(uuidString: text(at: 1, from: statement) ?? "") ?? UUID(),
            workspaceID: sqlite3_column_int64(statement, 2),
            sessionNumber: Int(sqlite3_column_int64(statement, 3)),
            name: text(at: 4, from: statement) ?? "",
            slug: text(at: 5, from: statement) ?? "",
            status: SessionStatus(rawValue: text(at: 6, from: statement) ?? SessionStatus.active.rawValue) ?? .active,
            sessionRootPath: text(at: 7, from: statement) ?? "",
            layoutName: text(at: 8, from: statement),
            createdAt: parseDate(text(at: 9, from: statement) ?? ""),
            lastActiveAt: parseDate(text(at: 10, from: statement) ?? ""),
            closedAt: text(at: 11, from: statement).map(parseDate)
        )
    }

    private func decodePane(from statement: OpaquePointer) throws -> Pane {
        Pane(
            rawID: sqlite3_column_int64(statement, 0),
            sessionID: sqlite3_column_int64(statement, 1),
            workspaceID: sqlite3_column_int64(statement, 2),
            sessionNumber: Int(sqlite3_column_int64(statement, 3)),
            paneNumber: Int(sqlite3_column_int64(statement, 4)),
            parentPaneID: int64(at: 5, from: statement),
            splitDirection: text(at: 6, from: statement).flatMap(SplitDirection.init(rawValue:)),
            ratio: double(at: 7, from: statement),
            positionIndex: Int(sqlite3_column_int64(statement, 8))
        )
    }

    private func decodeTab(from statement: OpaquePointer) throws -> Tab {
        Tab(
            rawID: sqlite3_column_int64(statement, 0),
            sessionID: sqlite3_column_int64(statement, 1),
            workspaceID: sqlite3_column_int64(statement, 2),
            sessionNumber: Int(sqlite3_column_int64(statement, 3)),
            paneID: sqlite3_column_int64(statement, 4),
            title: text(at: 6, from: statement) ?? "",
            cwd: text(at: 7, from: statement) ?? "",
            projectID: int64(at: 8, from: statement),
            command: text(at: 9, from: statement),
            envJSON: text(at: 10, from: statement),
            runtimeStatus: RuntimeStatus(rawValue: text(at: 11, from: statement) ?? RuntimeStatus.placeholder.rawValue) ?? .placeholder,
            positionIndex: Int(sqlite3_column_int64(statement, 12)),
            tabNumber: Int(sqlite3_column_int64(statement, 5)),
            needsAttention: sqlite3_column_int64(statement, 13) != 0,
            attentionMessage: text(at: 14, from: statement)
        )
    }

    private struct ScopedSessionRef {
        let workspaceID: Int64
        let sessionNumber: Int
    }

    private func parseScopedSessionRef(_ token: String) -> ScopedSessionRef? {
        let components = token.split(separator: "/")
        guard components.count == 2,
              let workspaceID = parseRef(String(components[0]), prefix: "workspace"),
              let sessionNumberValue = parseRef(String(components[1]), prefix: "session") else {
            return nil
        }
        return ScopedSessionRef(workspaceID: workspaceID, sessionNumber: Int(sessionNumberValue))
    }

    private func parseRef(_ token: String, prefix: String) -> Int64? {
        let prefixValue = "\(prefix):"
        guard token.hasPrefix(prefixValue) else {
            return nil
        }
        return Int64(token.dropFirst(prefixValue.count))
    }
}
