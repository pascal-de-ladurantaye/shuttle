import SwiftUI

private struct ShuttleHoverHintModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.help(text)
    }
}

extension View {
    /// Semantic wrapper around native macOS hover help for Shuttle controls.
    func shuttleHint(_ text: String) -> some View {
        modifier(ShuttleHoverHintModifier(text: text))
    }
}
