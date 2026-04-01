import SwiftUI
import ShuttleKit

struct DeleteSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: ShuttleAppModel

    let sessionRawID: Int64

    @State private var preview: SessionDeletionPreview?
    @State private var localError: String?
    @State private var isLoading = false
    @State private var isDeleting = false

    private var canConfirm: Bool {
        preview != nil && !isLoading && !isDeleting
    }

    private var deleteButtonHelpText: String {
        if preview?.projects.isEmpty == true {
            return "Delete this global session. Shuttle removes its session root and restore data."
        }
        return "Delete this session. Shuttle removes its session root and restore data, but keeps the source directories on disk."
    }

    private var headerSubtitle: String {
        guard let preview else {
            return "Review the affected checkouts first. Deleting the session removes it from Shuttle entirely."
        }
        if preview.projects.isEmpty {
            return "Deleting this session removes its Shuttle-managed session root and restore artifacts."
        }
        return "Deleting this session removes its Shuttle-managed session root; source directories stay on disk."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                if isLoading && preview == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Inspecting session cleanup state…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let preview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            summaryCard(preview: preview)
                            cleanupCard(preview: preview)

                            if !preview.projects.isEmpty {
                                sectionHeader(
                                    title: "Projects",
                                    subtitle: "Deleting this session removes Shuttle-managed metadata only. The underlying source directories stay on disk."
                                )

                                ForEach(preview.projects, id: \.project.rawID) { projectPreview in
                                    projectCard(projectPreview)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    ContentUnavailableView(
                        "Couldn’t Load Session",
                        systemImage: "exclamationmark.triangle"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .shuttleHint("Dismiss this sheet without deleting the session.")
                .disabled(isDeleting)

                Spacer()

                Button("Delete Session") {
                    submit()
                }
                .shuttleHint(deleteButtonHelpText)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .task(id: sessionRawID) {
            await loadPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delete Session")
                .font(.title2.weight(.semibold))

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryCard(preview: SessionDeletionPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.session.name)
                .font(.headline)

            HStack(spacing: 16) {
                summaryValue(title: "Workspace", value: preview.workspace.name)
                summaryValue(title: "Projects", value: "\(preview.projects.count)")
                summaryValue(title: "Source Directories", value: "\(preview.sourceCheckoutProjectCount)")
            }

            Text(preview.session.sessionRootPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(
                preview.projects.isEmpty
                    ? "This session is not linked to a project. Shuttle removes its session root, but there are no source directories to review."
                    : "All listed projects keep using their source directories directly. Shuttle removes the entire session root it created."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func cleanupCard(preview: SessionDeletionPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                preview.projects.isEmpty ? "Global session" : "Direct-source session",
                systemImage: preview.projects.isEmpty ? "house" : "externaldrive.badge.checkmark"
            )
            .font(.headline)

            Text("Deleting this session performs only Shuttle-managed cleanup:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("Remove the session AGENTS.md guide and restore artifacts", systemImage: "text.document")
                Label("Remove the entire session root directory", systemImage: "folder.badge.minus")
                if preview.projects.isEmpty {
                    Label("Leave your home directory and other local files untouched", systemImage: "house")
                } else {
                    Label("Keep the underlying source directories on disk", systemImage: "externaldrive")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func summaryValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func projectCard(_ projectPreview: SessionDeletionProjectPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(projectPreview.project.name, systemImage: projectPreview.project.kind == .try ? "sparkles" : "folder")
                    .font(.headline)

                Spacer(minLength: 8)

                Text("Source directory stays on disk")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            let checkoutPresentation = shuttleCheckoutPresentation(
                for: projectPreview.sessionProject,
                sessionRootPath: preview?.session.sessionRootPath ?? ""
            )

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                detailRow(title: "Checkout", value: checkoutPresentation.shortLabel)
                detailRow(title: "Path", value: projectPreview.sessionProject.checkoutPath, monospaced: true)
            }

            if let detail = checkoutPresentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Cleanup")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Keeps the source directory on disk and removes the Shuttle-managed session root.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !projectPreview.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(projectPreview.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func detailRow(title: String, value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if monospaced {
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.caption)
            }
        }
    }

    @MainActor
    private func loadPreview() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            preview = try await model.previewDeleteSession(sessionRawID: sessionRawID)
            localError = nil
        } catch {
            preview = nil
            localError = error.localizedDescription
        }
    }

    private func submit() {
        guard canConfirm else { return }

        Task { @MainActor in
            isDeleting = true
            defer { isDeleting = false }

            do {
                try await model.deleteSession(sessionRawID: sessionRawID)
                dismiss()
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}
