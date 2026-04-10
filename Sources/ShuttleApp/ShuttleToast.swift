import SwiftUI

// MARK: - Toast Model

struct ShuttleToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case info
        case error

        var iconName: String {
            switch self {
            case .success:
                return "checkmark.circle.fill"
            case .info:
                return "info.circle.fill"
            case .error:
                return "exclamationmark.triangle.fill"
            }
        }

        var tintColor: Color {
            switch self {
            case .success:
                return .green
            case .info:
                return .blue
            case .error:
                return .red
            }
        }

        var showsDismissButton: Bool {
            self != .success
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

enum ShuttleToastLayout {
    static let width: CGFloat = 360
    static let maxVisibleRows = 4
    static let stackSpacing: CGFloat = 10
}

// MARK: - Toast Views

struct ShuttleToastView: View {
    let toast: ShuttleToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.kind.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.kind.tintColor)
                .padding(.top, 1)

            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if toast.kind.showsDismissButton {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: ShuttleToastLayout.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ShuttleCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.large, style: .continuous)
                .strokeBorder(toast.kind.tintColor.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toast.kind == .error ? "Error" : toast.kind == .info ? "Info" : "Success"): \(toast.message)")
        .accessibilityAddTraits(.isStaticText)
    }
}

struct ShuttleToastOverflowSummaryView: View {
    let hiddenCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("+\(hiddenCount) more notification\(hiddenCount == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: ShuttleToastLayout.width, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: ShuttleCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.large, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        .accessibilityLabel("\(hiddenCount) more notifications hidden")
    }
}
