import SwiftUI
import AppKit

// MARK: - Corner Radii

/// Consistent corner radius hierarchy across the entire Shuttle UI.
///
/// Smaller elements (tabs, sidebar rows, search fields) use smaller radii.
/// Larger containers (cards, toasts, sheet groups) use larger radii.
enum ShuttleCornerRadius {
    /// Tabs, sidebar rows, pane chrome. 7pt.
    static let small: CGFloat = 7

    /// Search fields, outline rows. 8pt.
    static let medium: CGFloat = 8

    /// Section headers in the outline. 10pt.
    static let sectionGroup: CGFloat = 10

    /// Layout preview leaf panes. 12pt.
    static let card: CGFloat = 12

    /// Cards, toasts, sheet groups, overlay containers. 14pt.
    static let large: CGFloat = 14
}

// MARK: - Spacing

/// Consistent spacing tokens used across the Shuttle UI.
enum ShuttleSpacing {
    /// Tight inline spacing (icon↔text in sidebar rows). 6pt.
    static let inlineSmall: CGFloat = 6

    /// Default inline spacing. 8pt.
    static let inline: CGFloat = 8

    /// Default section/card spacing. 10pt.
    static let section: CGFloat = 10

    /// Padding inside cards and grouped containers. 14pt.
    static let cardPadding: CGFloat = 14

    /// Sheet content padding. 24pt.
    static let sheetPadding: CGFloat = 24
}

// MARK: - Typography Weights

/// Canonical font weight assignments.
///
/// Use these when adding new text so the weight hierarchy stays consistent.
///
/// - `title`: `.semibold` — sheet titles, large headings
/// - `headline`: `.semibold` — card titles, section names (via `.font(.headline)`)
/// - `label`: `.medium` — form field labels, sidebar row titles when emphasized
/// - `body`: `.regular` — default prose, field values
/// - `caption`: `.semibold` for group headers, `.medium` for badge labels
enum ShuttleTypography {
    // Intentionally empty — the guidelines live in the doc comments above.
    // Concrete modifiers like `.font(.headline)` are applied at the call site.
}

// MARK: - Chrome Palette

/// Semantic color tokens for the Shuttle chrome (sidebar, tab bars, selections).
///
/// Every color adapts to the current `colorScheme`. Views obtain a palette
/// by calling `ShuttleChromePalette(colorScheme:)` and then reference
/// named properties instead of ad-hoc `Color(nsColor:)` or hard-coded opacities.
struct ShuttleChromePalette {
    let colorScheme: ColorScheme

    private var isDark: Bool {
        colorScheme == .dark
    }

    // MARK: Sidebar

    /// Sidebar base color using dynamic NSColor that adapts to appearance changes.
    /// Avoids `NSColor.blended()` which eagerly resolves catalog colors and breaks
    /// live light/dark switching.
    var sidebarBackgroundBase: Color {
        Color(nsColor: isDark ? .underPageBackgroundColor : .controlBackgroundColor)
    }

    var emphasizedSelectionFill: Color {
        if isDark {
            return Color.accentColor.opacity(0.24)
        }
        return Color(nsColor: NSColor.selectedContentBackgroundColor)
    }

    var emphasizedSelectionText: Color {
        .white
    }

    var emphasizedSelectionSecondaryText: Color {
        Color.white.opacity(isDark ? 0.76 : 0.86)
    }

    var sidebarSearchFieldFill: Color {
        // Avoid NSColor.blended() — use pure SwiftUI colors that stay dynamic.
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.02)
    }

    var sidebarSearchFieldBorder: Color {
        Color(nsColor: NSColor.separatorColor).opacity(isDark ? 0.16 : 0.12)
    }

    // MARK: Tab bar

    var focusedTabBarTint: Color {
        isDark ? Color.accentColor.opacity(0.05) : .clear
    }

    var tabBaseFill: Color {
        Color(nsColor: NSColor.controlBackgroundColor)
    }

    var inactivePaneActiveTabFill: Color {
        isDark ? Color.secondary.opacity(0.12) : Color(nsColor: NSColor.controlBackgroundColor).opacity(0.92)
    }

    var hoveredTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.6 : 0.94)
    }

    var restingTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.34 : 0.82)
    }

    var unfocusedHoveredTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.46 : 0.84)
    }

    var unfocusedRestingTabFill: Color {
        tabBaseFill.opacity(isDark ? 0.24 : 0.68)
    }

    // MARK: Tab text

    var activeTabText: Color {
        emphasizedSelectionText
    }

    var inactivePaneActiveTabText: Color {
        Color.primary.opacity(isDark ? 0.82 : 0.72)
    }

    var focusedInactiveTabText: Color {
        Color.primary.opacity(isDark ? 0.82 : 0.78)
    }

    var unfocusedInactiveTabText: Color {
        Color.primary.opacity(isDark ? 0.62 : 0.56)
    }

    // MARK: Tab close icon

    var activeHoverCloseIcon: Color {
        isDark ? Color.white.opacity(0.82) : Color.primary.opacity(0.78)
    }

    var inactiveHoverCloseIcon: Color {
        Color.primary.opacity(isDark ? 0.52 : 0.62)
    }

    // MARK: Tab borders & shadows

    func selectedBorderColor(isActive: Bool) -> Color {
        if isActive {
            return isDark
                ? Color(nsColor: NSColor.separatorColor).opacity(0.28)
                : Color.white.opacity(0.22)
        }
        return Color(nsColor: NSColor.separatorColor).opacity(isDark ? 0.12 : 0.2)
    }

    func hoveredBorderColor(isFocusedPane: Bool) -> Color {
        Color(nsColor: NSColor.separatorColor).opacity(isDark ? 0.22 : (isFocusedPane ? 0.22 : 0.18))
    }

    func tabShadow(isActive: Bool, isFocusedPane: Bool) -> Color {
        guard isActive else { return .clear }
        if isDark {
            return Color.black.opacity(isFocusedPane ? 0.16 : 0.08)
        }
        return Color.black.opacity(isFocusedPane ? 0.08 : 0.04)
    }

    // MARK: Cards & containers

    var cardBackground: Color {
        Color(nsColor: NSColor.controlBackgroundColor)
    }

    var cardBorder: Color {
        Color(nsColor: NSColor.separatorColor).opacity(0.28)
    }

    var subtleFill: Color {
        Color.secondary.opacity(isDark ? 0.08 : 0.06)
    }
}
