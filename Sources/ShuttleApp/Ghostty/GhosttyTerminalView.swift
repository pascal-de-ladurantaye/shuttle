import SwiftUI
import AppKit
import GhosttyKit

// MARK: - GhosttyTerminalView
// SwiftUI wrapper around a persistent per-tab GhosttyNSView runtime.
// Each Shuttle tab gets its own Ghostty surface keyed by `runtimeKey`.

struct GhosttyTerminalView: NSViewRepresentable {
    let runtimeKey: String
    let workingDirectory: String?
    let command: String?
    let environmentVariables: [String: String]
    let prefersKeyboardFocus: Bool
    var onClose: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    init(
        runtimeKey: String,
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        prefersKeyboardFocus: Bool = false,
        onClose: (() -> Void)? = nil,
        onFocus: ((Bool) -> Void)? = nil
    ) {
        self.runtimeKey = runtimeKey
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
        self.prefersKeyboardFocus = prefersKeyboardFocus
        self.onClose = onClose
        self.onFocus = onFocus
    }

    func makeNSView(context: Context) -> GhosttyFocusContainerView {
        GhosttyFocusContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func updateNSView(_ container: GhosttyFocusContainerView, context: Context) {
        let runtime = GhosttyTabRuntimeRegistry.shared.runtime(
            for: runtimeKey,
            workingDirectory: workingDirectory,
            command: command,
            environmentVariables: environmentVariables
        )
        runtime.surfaceView.onClose = onClose
        runtime.surfaceView.onFocus = onFocus
        runtime.surfaceView.prefersKeyboardFocus = prefersKeyboardFocus
        runtime.ensureSurface()
        container.attachSurfaceView(
            runtime.surfaceView,
            runtime: runtime,
            prefersKeyboardFocus: prefersKeyboardFocus
        )
    }
}

// MARK: - Focus Container
// Mount point for a persistent GhosttyNSView owned by the runtime registry.

@MainActor
final class GhosttyFocusContainerView: NSView {
    private static var nextInstanceSerial: UInt64 = 0

    private(set) var surfaceView: GhosttyNSView?
    private var runtime: GhosttyTabRuntime?
    private var prefersKeyboardFocus = false
    let instanceSerial: UInt64

    override init(frame frameRect: NSRect) {
        Self.nextInstanceSerial &+= 1
        instanceSerial = Self.nextInstanceSerial
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        Self.nextInstanceSerial &+= 1
        instanceSerial = Self.nextInstanceSerial
        super.init(coder: coder)
    }

    func attachSurfaceView(_ view: GhosttyNSView, runtime: GhosttyTabRuntime, prefersKeyboardFocus: Bool) {
        let hostId = ObjectIdentifier(self)
        guard runtime.claimHost(hostId: hostId, instanceSerial: instanceSerial) else {
            return
        }
        self.runtime = runtime
        self.prefersKeyboardFocus = prefersKeyboardFocus
        if surfaceView !== view {
            surfaceView?.removeFromSuperview()
            surfaceView = view
            addSubview(view)
        }
        needsLayout = true

        if prefersKeyboardFocus,
           let window,
           window.isKeyWindow,
           window.firstResponder !== view {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.prefersKeyboardFocus,
                      self.surfaceView === view,
                      let window = self.window,
                      window.isKeyWindow else {
                    return
                }
                TerminalFocusCoordinator.shared.setActiveSurfaceView(view)
                window.makeFirstResponder(view)
            }
        }
    }

    override func layout() {
        super.layout()
        surfaceView?.frame = bounds
    }

    override var acceptsFirstResponder: Bool { prefersKeyboardFocus }

    override func becomeFirstResponder() -> Bool {
        guard prefersKeyboardFocus,
              let surfaceView else { return false }
        TerminalFocusCoordinator.shared.setActiveSurfaceView(surfaceView)
        window?.makeFirstResponder(surfaceView)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let surfaceView else { return }
        TerminalFocusCoordinator.shared.setActiveSurfaceView(surfaceView)
        window?.makeFirstResponder(surfaceView)
        surfaceView.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let runtime {
            runtime.releaseHost(hostId: ObjectIdentifier(self))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }
}

// MARK: - Scroll host view

struct TerminalHostView: View {
    let runtimeKey: String
    let workingDirectory: String?
    let command: String?
    let environmentVariables: [String: String]
    let prefersKeyboardFocus: Bool
    var onClose: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    @ObservedObject private var runtime = GhosttyRuntime.shared

    var body: some View {
        Group {
            if runtime.isReady {
                GhosttyTerminalView(
                    runtimeKey: runtimeKey,
                    workingDirectory: workingDirectory,
                    command: command,
                    environmentVariables: environmentVariables,
                    prefersKeyboardFocus: prefersKeyboardFocus,
                    onClose: onClose,
                    onFocus: onFocus
                )
                .background(
                    Color(nsColor: runtime.defaultBackgroundColor.withAlphaComponent(
                        runtime.defaultBackgroundOpacity
                    ))
                )
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Initializing terminal runtime…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            }
        }
    }
}
