import SwiftUI
import ShuttleKit

enum ShuttleSheet: Identifiable, Equatable {
    case newSession
    case newTry
    case renameSession(Int64)
    case deleteSession(Int64)

    var id: String {
        switch self {
        case .newSession:
            return "new-session"
        case .newTry:
            return "new-try"
        case .renameSession(let sessionRawID):
            return "rename-session-\(sessionRawID)"
        case .deleteSession(let sessionRawID):
            return "delete-session-\(sessionRawID)"
        }
    }
}

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: ShuttleAppModel
    @EnvironmentObject private var layouts: LayoutLibraryModel
    @FocusState private var focusedField: Field?
    @AppStorage(ShuttlePreferenceKey.seedMultiProjectAgentGuide) private var seedMultiProjectAgentGuide = true

    let workspace: WorkspaceDetails

    @State private var sessionName = ""
    @State private var selectedLayoutID = ShuttlePreferences.defaultSessionLayoutID
    @State private var localError: String?
    @State private var isCreating = false

    private enum Field {
        case sessionName
    }

    private var selectedPreset: LayoutPreset? {
        layouts.preset(id: selectedLayoutID)
    }

    private var canSubmit: Bool {
        !isCreating && selectedPreset != nil
    }

    private var isGlobalWorkspace: Bool {
        workspace.workspace.createdFrom == .global
    }

    private var sheetSubtitle: String {
        if isGlobalWorkspace {
            return "Create a session in \(workspace.workspace.name). New tabs in global sessions open in your home directory (~)."
        }
        return "Create a session in \(workspace.workspace.name) and choose its starting layout."
    }

    private var projectsFooterText: String {
        if isGlobalWorkspace {
            return "Global sessions are not linked to a project. Shuttle still creates a session root for metadata and restore state."
        }

        var parts = [
            "Sessions are always single-project and open directly in their source checkout.",
            "Shuttle still creates a session root for metadata and restore state."
        ]

        if seedMultiProjectAgentGuide {
            parts.append("Shuttle can also seed an `AGENTS.md` guide at the session root so agents can see the active checkout and project guidance.")
        }

        return parts.joined(separator: " ")
    }

    private var workspaceSummaryText: String {
        if isGlobalWorkspace {
            return "Global workspace • new tabs start in ~"
        }
        if let project = workspace.projects.first {
            return project.kind == .try ? "Try workspace" : "Project workspace"
        }
        return "Project workspace"
    }

    var body: some View {
        SessionCreationSheetScaffold(
            title: "New Session",
            subtitle: sheetSubtitle,
            isWorking: isCreating,
            errorText: localError,
            confirmTitle: "Create Session",
            canConfirm: canSubmit,
            onCancel: { dismiss() },
            onConfirm: submit
        ) {
            SessionCreationColumns {
                VStack(spacing: 16) {
                    SessionCreationCard(title: "Session") {
                        SessionCreationField(title: "Workspace") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.workspace.name)
                                    .font(.headline)
                                Text(workspaceSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        SessionCreationField(
                            title: "Session name",
                            helperText: "Leave blank to let Shuttle generate one automatically."
                        ) {
                            TextField("", text: $sessionName, prompt: Text("Optional"))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .sessionName)
                                .disabled(isCreating)
                        }

                        SessionCreationField(title: "Layout") {
                            HStack(alignment: .center, spacing: 12) {
                                Picker("Layout", selection: $selectedLayoutID) {
                                    ForEach(layouts.presets, id: \.id) { preset in
                                        Text(preset.name).tag(preset.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .disabled(isCreating)

                                Button("Edit Layouts…") {
                                    openWindow(id: ShuttleLayoutBuilderWindow.id)
                                }
                                .shuttleHint("Open Layout Builder to edit layout presets.")
                                .disabled(isCreating)
                            }
                        }
                    }
                }
            } trailing: {
                VStack(spacing: 16) {
                    SessionCreationCard(title: "Layout Preview") {
                        PresetSummaryCard(preset: selectedPreset)
                    }

                    SessionCreationCard(
                        title: isGlobalWorkspace ? "How It Starts" : "Projects",
                        footerText: projectsFooterText
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            if isGlobalWorkspace {
                                SessionCreationValueBlock(title: "Starting directory", value: "~")

                                VStack(alignment: .leading, spacing: 10) {
                                    SessionCreationBulletRow(
                                        systemImage: "house",
                                        text: "New tabs open in your home directory instead of a project checkout"
                                    )
                                    SessionCreationBulletRow(
                                        systemImage: "folder.badge.gearshape",
                                        text: "Use this for scratch work, one-off commands, or bootstrapping a new project"
                                    )
                                }
                            } else {
                                ForEach(workspace.projects, id: \.rawID) { project in
                                    SessionCreationProjectPlanRow(project: project)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 760, height: 580)
        .onAppear {
            selectedLayoutID = layouts.resolvedPresetID(preferred: selectedLayoutID)
            DispatchQueue.main.async {
                focusedField = .sessionName
            }
        }
    }

    private func submit() {
        guard !isCreating else { return }

        Task {
            isCreating = true
            localError = nil
            do {
                try await model.createSession(
                    workspaceToken: workspace.workspace.id,
                    name: normalized(sessionName),
                    layoutName: selectedLayoutID
                )
                dismiss()
            } catch {
                localError = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct NewTrySessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: ShuttleAppModel
    @EnvironmentObject private var layouts: LayoutLibraryModel
    @FocusState private var focusedField: Field?

    @State private var tryName = ""
    @State private var sessionName = "initial"
    @State private var selectedLayoutID = ShuttlePreferences.defaultTryLayoutID
    @State private var localError: String?
    @State private var isCreating = false

    private enum Field {
        case tryName
        case sessionName
    }

    private var selectedPreset: LayoutPreset? {
        layouts.preset(id: selectedLayoutID)
    }

    private var configuredTriesRoot: String? {
        try? ConfigManager(paths: ShuttleExternalPaths.shuttlePaths).load().expandedTriesRoot
    }

    private var normalizedTryName: String? {
        let trimmed = tryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canSubmit: Bool {
        !isCreating && normalizedTryName != nil && selectedPreset != nil
    }

    var body: some View {
        SessionCreationSheetScaffold(
            title: "New Try Session",
            subtitle: "Create a new try directory, register its workspace, and start the first session with your chosen layout.",
            isWorking: isCreating,
            errorText: localError,
            confirmTitle: "Create Try Session",
            canConfirm: canSubmit,
            onCancel: { dismiss() },
            onConfirm: submit
        ) {
            SessionCreationColumns {
                VStack(spacing: 16) {
                    SessionCreationCard(title: "Try") {
                        SessionCreationField(title: "Try name") {
                            TextField("", text: $tryName, prompt: Text("Required"))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .tryName)
                                .disabled(isCreating)
                        }

                        SessionCreationField(
                            title: "Initial session name",
                            helperText: "This names the first session opened inside the new try workspace."
                        ) {
                            TextField("", text: $sessionName, prompt: Text("initial"))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .sessionName)
                                .disabled(isCreating)
                        }

                        SessionCreationField(title: "Layout") {
                            HStack(alignment: .center, spacing: 12) {
                                Picker("Layout", selection: $selectedLayoutID) {
                                    ForEach(layouts.presets, id: \.id) { preset in
                                        Text(preset.name).tag(preset.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .disabled(isCreating)

                                Button("Edit Layouts…") {
                                    openWindow(id: ShuttleLayoutBuilderWindow.id)
                                }
                                .shuttleHint("Open Layout Builder to edit layout presets.")
                                .disabled(isCreating)
                            }
                        }
                    }
                }
            } trailing: {
                VStack(spacing: 16) {
                    SessionCreationCard(title: "Layout Preview") {
                        PresetSummaryCard(preset: selectedPreset)
                    }

                    SessionCreationCard(title: "What Happens") {
                        VStack(alignment: .leading, spacing: 12) {
                            SessionCreationValueBlock(
                                title: "Tries root",
                                value: configuredTriesRoot ?? "Not configured"
                            )

                            VStack(alignment: .leading, spacing: 10) {
                                SessionCreationBulletRow(
                                    systemImage: "folder.badge.plus",
                                    text: "Creates a new try directory"
                                )
                                SessionCreationBulletRow(
                                    systemImage: "square.stack.3d.up",
                                    text: "Registers a default workspace for the try"
                                )
                                SessionCreationBulletRow(
                                    systemImage: "rectangle.split.3x1",
                                    text: "Opens the initial session with the selected layout"
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 760, height: 580)
        .onAppear {
            selectedLayoutID = layouts.resolvedPresetID(preferred: selectedLayoutID)
            DispatchQueue.main.async {
                focusedField = .tryName
            }
        }
    }

    private func submit() {
        guard !isCreating, let tryName = normalizedTryName else { return }

        Task {
            isCreating = true
            localError = nil
            do {
                try await model.createTrySession(
                    name: tryName,
                    sessionName: normalized(sessionName) ?? "initial",
                    layoutName: selectedLayoutID
                )
                dismiss()
            } catch {
                localError = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: ShuttleAppModel
    @FocusState private var focusedField: Bool

    let sessionRawID: Int64

    @State private var sessionName = ""
    @State private var localError: String?
    @State private var isSaving = false

    private var session: Session? {
        model.workspaces
            .flatMap(\.sessions)
            .first(where: { $0.rawID == sessionRawID })
    }

    private var workspaceName: String? {
        model.workspaces.first(where: { details in
            details.sessions.contains(where: { $0.rawID == sessionRawID })
        })?.workspace.name
    }

    private var canSubmit: Bool {
        session != nil && !isSaving && normalized(sessionName) != nil
    }

    var body: some View {
        SessionCreationSheetScaffold(
            title: "Rename Session",
            subtitle: "Update the display name for this session. Its session root and checkpointed restore state stay in place.",
            isWorking: isSaving,
            errorText: localError,
            confirmTitle: "Save",
            canConfirm: canSubmit,
            onCancel: { dismiss() },
            onConfirm: submit
        ) {
            SessionCreationColumns {
                VStack(spacing: 16) {
                    SessionCreationCard(title: "Session") {
                        SessionCreationField(title: "Name") {
                            TextField("", text: $sessionName, prompt: Text("Required"))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField)
                                .disabled(isSaving)
                        }
                    }
                }
            } trailing: {
                VStack(spacing: 16) {
                    if let session {
                        SessionCreationCard(title: "Current Context") {
                            if let workspaceName {
                                SessionCreationValueBlock(title: "Workspace", value: workspaceName)
                            }
                            SessionCreationValueBlock(title: "Status", value: session.status.rawValue)
                            SessionCreationValueBlock(title: "Layout", value: session.layoutName ?? LayoutPresetStore.defaultPresetID)
                        }
                    }
                }
            }
        }
        .frame(width: 640, height: 360)
        .onAppear {
            if sessionName.isEmpty {
                sessionName = session?.name ?? ""
            }
            DispatchQueue.main.async {
                focusedField = true
            }
        }
    }

    private func submit() {
        guard let sessionName = normalized(sessionName), !isSaving else { return }

        Task {
            isSaving = true
            localError = nil
            do {
                try await model.renameSession(sessionRawID: sessionRawID, name: sessionName)
                dismiss()
            } catch {
                localError = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SessionCreationSheetScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    let isWorking: Bool
    let errorText: String?
    let confirmTitle: String
    let canConfirm: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let content: Content

    private var confirmHint: String {
        "Confirm and \(confirmTitle.lowercased())."
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack(spacing: 12) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Button("Cancel", action: onCancel)
                    .shuttleHint("Dismiss this sheet without saving changes.")
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)

                Button(confirmTitle, action: onConfirm)
                    .shuttleHint(confirmHint)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }
}

private struct SessionCreationColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                leading
                    .frame(width: 330, alignment: .topLeading)
                trailing
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 16) {
                leading
                trailing
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct SessionCreationCard<Content: View>: View {
    let title: String
    let footerText: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        footerText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footerText = footerText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            content

            if let footerText {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
        }
    }
}

private struct SessionCreationField<Content: View>: View {
    let title: String
    let helperText: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        helperText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.helperText = helperText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content
            if let helperText {
                Text(helperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SessionCreationValueBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SessionCreationBulletRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SessionCreationProjectPlanRow: View {
    let project: Project

    private var iconName: String {
        project.kind == .try ? "sparkles" : "folder"
    }

    private var subtitle: String {
        project.kind == .try
            ? "Try project — Shuttle opens the session directly in the source directory"
            : "Workspace project — Shuttle opens the session directly in the source directory"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(project.kind == .try ? Color.accentColor : Color.secondary)
                    .frame(width: 14)
                Text(project.name)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(project.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
