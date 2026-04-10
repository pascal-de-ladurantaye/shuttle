import SwiftUI
import AppKit
import ShuttleKit

enum PaneTabBarMetrics {
    static let barHeight: CGFloat = 34
    static let tabHeight: CGFloat = 26
    static let minTabWidth: CGFloat = 160
    static let addButtonWidth: CGFloat = 26
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 4
    static let interItemSpacing: CGFloat = 4
}

struct GhosttyPaneTabCell: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let isActive: Bool
    let isFocusedPane: Bool
    let needsAttention: Bool
    let attentionMessage: String?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    private var showsAttentionTreatment: Bool {
        needsAttention && !(isActive && isFocusedPane)
    }

    private var fillColor: Color {
        if showsAttentionTreatment {
            return colorScheme == .dark
                ? Color.orange.opacity(0.18)
                : Color.orange.opacity(0.12)
        }

        if isActive {
            return isFocusedPane ? chromePalette.emphasizedSelectionFill : chromePalette.inactivePaneActiveTabFill
        }

        if isHovering {
            return isFocusedPane ? chromePalette.hoveredTabFill : chromePalette.unfocusedHoveredTabFill
        }

        return isFocusedPane ? chromePalette.restingTabFill : chromePalette.unfocusedRestingTabFill
    }

    private var borderColor: Color {
        if showsAttentionTreatment {
            return Color.orange.opacity(0.5)
        }

        if isActive {
            return chromePalette.selectedBorderColor(isActive: true)
        }

        if isHovering {
            return chromePalette.hoveredBorderColor(isFocusedPane: isFocusedPane)
        }

        return chromePalette.selectedBorderColor(isActive: false)
    }

    private var textColor: Color {
        if showsAttentionTreatment {
            return Color.orange
        }

        if isActive {
            return isFocusedPane ? chromePalette.activeTabText : chromePalette.inactivePaneActiveTabText
        }

        return isFocusedPane ? chromePalette.focusedInactiveTabText : chromePalette.unfocusedInactiveTabText
    }

    private var closeIconColor: Color {
        if isActive {
            return isFocusedPane ? chromePalette.activeHoverCloseIcon : chromePalette.inactivePaneActiveTabText
        }

        return chromePalette.inactiveHoverCloseIcon
    }

    private var tabOpacity: Double {
        if showsAttentionTreatment { return 1.0 }
        return isFocusedPane ? 1.0 : (isActive ? 0.72 : 0.5)
    }

    var body: some View {
        ZStack {
            Button(action: onSelect) {
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shuttleHint("Select \(title).")

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shuttleHint("Close \(title).")
                .foregroundStyle(closeIconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
            }
        }
        .background(fillColor, in: RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if isActive && isFocusedPane && !showsAttentionTreatment {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 1)
            }
        }
        .overlay(alignment: .top) {
            if showsAttentionTreatment {
                Capsule()
                    .fill(Color.orange)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsAttentionTreatment {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .padding(4)
                    .help(attentionMessage ?? "Needs attention")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .shadow(color: chromePalette.tabShadow(isActive: isActive, isFocusedPane: isFocusedPane), radius: colorScheme == .dark ? 2 : 1, y: 1)
        .opacity(tabOpacity)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Selected" : "")
        .accessibilityHint(needsAttention ? "Needs attention. \(attentionMessage ?? "")" : "")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

