import SwiftUI
import AppKit
import ShuttleKit

struct SessionInfoPopoverView: View {
    let bundle: SessionBundle
    let restoreMessage: String?
    let onRename: () -> Void
    let onClose: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Info")
                .font(.headline)

            LabeledContent("Workspace") {
                Text(bundle.workspace.name)
                    .font(.caption)
            }

            LabeledContent("Session") {
                Text(bundle.session.name)
                    .font(.caption)
            }

            LabeledContent("Layout") {
                Text(bundle.session.layoutName ?? LayoutPresetStore.defaultPresetID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Root") {
                Text(bundle.session.sessionRootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let restoreMessage {
                Divider()
                Label("Restored", systemImage: "arrow.clockwise.circle")
                    .font(.subheadline.weight(.medium))
                Text(restoreMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !bundle.sessionProjects.isEmpty {
                Divider()
                Text("Projects")
                    .font(.subheadline.weight(.medium))
            }

            ForEach(bundle.sessionProjects, id: \.projectID) { sp in
                let project = bundle.projects.first(where: { $0.rawID == sp.projectID })
                let checkoutPresentation = shuttleCheckoutPresentation(
                    for: sp,
                    sessionRootPath: bundle.session.sessionRootPath
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: project?.kind == .try ? "sparkles" : "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(project?.name ?? "Unknown")
                            .fontWeight(.medium)
                    }
                    LabeledContent("Checkout") {
                        Text(checkoutPresentation.shortLabel)
                    }
                    .font(.caption)
                    if let detail = checkoutPresentation.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Path") {
                        Text(sp.checkoutPath)
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Rename…", action: onRename)
                        .shuttleHint("Rename this session.")
                    Button("Close", action: onClose)
                        .disabled(bundle.session.status == .closed)
                        .shuttleHint("Archive this session without deleting its on-disk metadata.")
                    Spacer()
                }

                HStack {
                    Spacer()
                    Button("Delete Session…", role: .destructive, action: onDelete)
                        .shuttleHint("Delete this session.")
                }
            }
        }
    }
}

