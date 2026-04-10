import SwiftUI
import AppKit
import ShuttleKit

struct ResizablePaneSplitView: View {
    let paneRawID: Int64
    let axis: Axis.Set
    let ratio: Double
    let first: AnyView
    let second: AnyView
    let onRatioChanged: (Double) -> Void
    let onRatioCommitted: (Double) -> Void

    @State private var dragStartRatio: Double?
    @State private var liveRatio: Double?
    @State private var isHoveringDivider = false

    private let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let availableExtent = max(primaryExtent(in: proxy.size) - dividerThickness, 1)
            let effectiveRatio = clampedRatio(liveRatio ?? ratio, availableExtent: availableExtent)
            let firstExtent = availableExtent * effectiveRatio
            let secondExtent = availableExtent - firstExtent

            group(
                firstExtent: firstExtent,
                secondExtent: secondExtent,
                fullSize: proxy.size,
                effectiveRatio: effectiveRatio,
                availableExtent: availableExtent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            liveRatio = ratio
        }
        .onChange(of: ratio) { _, newValue in
            guard dragStartRatio == nil else { return }
            liveRatio = newValue
        }
    }

    @ViewBuilder
    private func group(
        firstExtent: CGFloat,
        secondExtent: CGFloat,
        fullSize: CGSize,
        effectiveRatio: Double,
        availableExtent: CGFloat
    ) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                first
                    .frame(width: firstExtent, height: fullSize.height)
                divider(effectiveRatio: effectiveRatio, availableExtent: availableExtent)
                    .frame(width: dividerThickness, height: fullSize.height)
                second
                    .frame(width: secondExtent, height: fullSize.height)
            }
        } else {
            VStack(spacing: 0) {
                first
                    .frame(width: fullSize.width, height: firstExtent)
                divider(effectiveRatio: effectiveRatio, availableExtent: availableExtent)
                    .frame(width: fullSize.width, height: dividerThickness)
                second
                    .frame(width: fullSize.width, height: secondExtent)
            }
        }
    }

    private func divider(effectiveRatio: Double, availableExtent: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Rectangle()
                .fill(isHoveringDivider ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.35))
                .frame(width: axis == .horizontal ? 2 : nil, height: axis == .vertical ? 2 : nil)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringDivider = hovering
            if hovering {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Pane divider")
        .accessibilityHint(axis == .horizontal ? "Drag left or right to resize panes" : "Drag up or down to resize panes")

        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartRatio == nil {
                        dragStartRatio = effectiveRatio
                    }
                    let anchorRatio = dragStartRatio ?? effectiveRatio
                    let anchorExtent = CGFloat(anchorRatio) * availableExtent
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    let nextRatio = clampedRatio((anchorExtent + translation) / availableExtent, availableExtent: availableExtent)
                    liveRatio = nextRatio
                    onRatioChanged(nextRatio)
                }
                .onEnded { value in
                    let anchorRatio = dragStartRatio ?? effectiveRatio
                    let anchorExtent = CGFloat(anchorRatio) * availableExtent
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    let nextRatio = clampedRatio((anchorExtent + translation) / availableExtent, availableExtent: availableExtent)
                    liveRatio = nextRatio
                    dragStartRatio = nil
                    onRatioChanged(nextRatio)
                    onRatioCommitted(nextRatio)
                }
        )
    }

    private func primaryExtent(in size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func clampedRatio(_ rawRatio: Double, availableExtent: CGFloat) -> Double {
        let minimumPaneExtent: CGFloat = axis == .horizontal ? 180 : 120
        let minimumRatio = min(max(minimumPaneExtent / availableExtent, 0.1), 0.45)
        let maximumRatio = 1 - minimumRatio
        guard minimumRatio < maximumRatio else { return 0.5 }
        return min(max(rawRatio, minimumRatio), maximumRatio)
    }
}
