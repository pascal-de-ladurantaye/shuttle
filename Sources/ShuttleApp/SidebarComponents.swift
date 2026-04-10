import SwiftUI
import AppKit
import ShuttleKit

struct ShuttleProfileBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let profile: ShuttleProfile

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var fillColor: Color {
        isDark ? Color.orange.opacity(0.2) : Color.orange.opacity(0.12)
    }

    private var borderColor: Color {
        isDark ? Color.orange.opacity(0.55) : Color.orange.opacity(0.34)
    }

    private var textColor: Color {
        isDark ? Color.orange.opacity(0.96) : Color(red: 0.72, green: 0.36, blue: 0.02)
    }

    var body: some View {
        if profile == .dev {
            Label("DEV", systemImage: "hammer.fill")
                .font(.caption2.weight(.bold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(textColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(fillColor)
                )
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: 1)
                )
                .shuttleHint("Shuttle Dev profile — isolated config, Application Support, preferences, and session root.")
                .accessibilityLabel("DEV profile")
        }
    }
}

struct SidebarSearchField: View {
    @Environment(\.colorScheme) private var colorScheme

    let placeholder: String
    @Binding var text: String

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .shuttleHint("Clear the current search.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.medium, style: .continuous)
                .fill(chromePalette.sidebarSearchFieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.medium, style: .continuous)
                .stroke(chromePalette.sidebarSearchFieldBorder, lineWidth: 1)
        )
    }
}

struct SidebarDisclosureRow: View {
    let title: String
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
    }
}

struct SidebarGroupHeaderRow: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SidebarStatusRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
    }
}

struct SidebarListRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let trailingAccessorySystemImage: String?
    let attentionCount: Int

    init(
        systemImage: String,
        iconColor: Color,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        trailingAccessorySystemImage: String? = nil,
        attentionCount: Int = 0
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.trailingAccessorySystemImage = trailingAccessorySystemImage
        self.attentionCount = attentionCount
    }

    private var chromePalette: ShuttleChromePalette {
        ShuttleChromePalette(colorScheme: colorScheme)
    }

    private var titleColor: Color {
        isSelected ? chromePalette.emphasizedSelectionText : .primary
    }

    private var subtitleColor: Color {
        isSelected ? chromePalette.emphasizedSelectionSecondaryText : .secondary
    }

    private var rowBackground: Color {
        isSelected ? chromePalette.emphasizedSelectionFill : .clear
    }

    private var trailingAccessoryColor: Color {
        isSelected ? chromePalette.emphasizedSelectionSecondaryText : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? .white : iconColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            if let trailingAccessorySystemImage {
                Image(systemName: trailingAccessorySystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trailingAccessoryColor)
                    .frame(width: 12)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: trailingAccessorySystemImage != nil)
        .animation(.easeOut(duration: 0.14), value: attentionCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([
            subtitle,
            attentionCount > 0 ? "\(attentionCount) attention" : nil
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct HoverPinnableWorkspaceRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isPinned: Bool
    let canTogglePin: Bool
    var attentionCount: Int = 0
    let onSelect: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovering = false

    private let pinButtonSize: CGFloat = 18

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var hoverButtonSystemImage: String {
        isPinned ? "pin.slash.fill" : "pin.fill"
    }

    private var hoverButtonFill: Color {
        if isPinned {
            return isDark ? Color.white.opacity(0.2) : Color(nsColor: NSColor.controlColor).opacity(0.94)
        }
        return isDark ? Color.accentColor.opacity(0.92) : Color.accentColor
    }

    private var hoverButtonBorder: Color {
        if isPinned {
            return isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
        }
        return isDark ? Color.white.opacity(0.14) : Color.accentColor.opacity(0.24)
    }

    private var hoverButtonShadow: Color {
        Color.black.opacity(isDark ? 0.22 : 0.12)
    }

    private var hoverButtonForeground: Color {
        if isPinned {
            return isDark ? Color.white.opacity(0.92) : Color.primary.opacity(0.82)
        }
        return .white
    }

    private var hoverButtonHint: String {
        isPinned ? "Unpin workspace \(title)." : "Pin workspace \(title)."
    }

    private var hoverAnimation: Animation {
        .spring(response: 0.22, dampingFraction: 0.84, blendDuration: 0.08)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                SidebarListRow(
                    systemImage: systemImage,
                    iconColor: iconColor,
                    title: title,
                    subtitle: subtitle,
                    isSelected: isSelected,
                    trailingAccessorySystemImage: isPinned && !isHovering ? "pin.fill" : nil,
                    attentionCount: attentionCount
                )
            }
            .buttonStyle(.plain)

            if canTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: hoverButtonSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hoverButtonForeground)
                        .frame(width: pinButtonSize, height: pinButtonSize)
                        .background(
                            Circle()
                                .fill(hoverButtonFill)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(hoverButtonBorder, lineWidth: 0.75)
                        )
                        .shadow(color: hoverButtonShadow, radius: 5, y: 1)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .shuttleHint(hoverButtonHint)
                .padding(.trailing, 8)
                .scaleEffect(isHovering ? 1 : 0.84)
                .offset(x: isHovering ? 0 : 2)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityLabel(isPinned ? "Unpin Workspace" : "Pin Workspace")
                .animation(hoverAnimation, value: isHovering)
                .animation(.easeOut(duration: 0.16), value: isPinned)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
        .onHover { hovering in
            withAnimation(hoverAnimation) {
                isHovering = hovering
            }
        }
    }
}

struct HoverDeletableSessionRow: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    var attentionCount: Int = 0
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private let deleteButtonSize: CGFloat = 18

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                SidebarListRow(
                    systemImage: systemImage,
                    iconColor: iconColor,
                    title: title,
                    subtitle: subtitle,
                    isSelected: isSelected,
                    attentionCount: attentionCount
                )
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: deleteButtonSize, height: deleteButtonSize)
                    .background(
                        Circle()
                            .fill(Color.red.opacity(0.92))
                    )
            }
            .buttonStyle(.plain)
            .shuttleHint("Delete session \(title)…")
            .padding(.trailing, 8)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityLabel("Delete Session")
        }
        .contentShape(RoundedRectangle(cornerRadius: ShuttleCornerRadius.small, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session: \(title)")
        .accessibilityValue([
            subtitle,
            isSelected ? "Selected" : nil,
            attentionCount > 0 ? "\(attentionCount) attention" : nil
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

