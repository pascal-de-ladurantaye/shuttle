import AppKit

@MainActor
final class TerminalFocusCoordinator {
    static let shared = TerminalFocusCoordinator()

    private weak var activeSurfaceView: GhosttyNSView?
    private var localEventMonitor: Any?
    private var isDispatchingMonitoredEvent = false

    private init() {}

    func installIfNeeded() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func setActiveSurfaceView(_ view: GhosttyNSView?) {
        activeSurfaceView = view
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !isDispatchingMonitoredEvent else { return event }
        guard NSApplication.shared.isActive else { return event }
        guard let view = activeSurfaceView,
              let window = view.window,
              window.isKeyWindow,
              let firstResponder = window.firstResponder,
              firstResponder !== view else {
            return event
        }
        guard !shouldPreserveFirstResponderInput(firstResponder, activeSurfaceView: view) else {
            return event
        }

        // Don't steal menu shortcuts / app commands.
        let deviceIndependentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if deviceIndependentFlags.contains(.command) {
            return event
        }

        isDispatchingMonitoredEvent = true
        defer { isDispatchingMonitoredEvent = false }

        switch event.type {
        case .keyDown:
            view.keyDown(with: event)
            return nil
        case .keyUp:
            view.keyUp(with: event)
            return nil
        case .flagsChanged:
            view.flagsChanged(with: event)
            return nil
        default:
            return event
        }
    }

    private func shouldPreserveFirstResponderInput(_ responder: NSResponder, activeSurfaceView: GhosttyNSView) -> Bool {
        guard let responderView = responder as? NSView else {
            return false
        }

        if responderView === activeSurfaceView ||
            responderView.isDescendant(of: activeSurfaceView) ||
            activeSurfaceView.isDescendant(of: responderView) {
            return false
        }

        if let textView = responderView as? NSTextView,
           textView.isFieldEditor || textView.isEditable {
            return true
        }

        if responderView is NSTextField || responderView is NSSearchField {
            return true
        }

        return false
    }
}
