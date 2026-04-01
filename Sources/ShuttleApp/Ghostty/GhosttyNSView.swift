import Foundation
import AppKit
import Darwin
import Metal
import QuartzCore
import GhosttyKit
import ShuttleKit

// MARK: - GhosttyNSView
// AppKit NSView that hosts a Ghostty terminal surface.
// Creates a CAMetalLayer for GPU rendering and forwards input events to libghostty.

@MainActor
class GhosttyNSView: NSView, @preconcurrency NSTextInputClient {
    let surfaceId = UUID()
    nonisolated(unsafe) var surface: ghostty_surface_t?
    nonisolated(unsafe) var surfaceHandle: Unmanaged<GhosttySurfaceHandle>?
    var onClose: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var prefersKeyboardFocus = false

    private var trackingArea: NSTrackingArea?
    private var userInitiatedFocusRequest = false
    private var markedText = NSMutableAttributedString()
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastScaleX: CGFloat = 0

    /// Text accumulated during interpretKeyEvents for the current keyDown.
    private var keyTextAccumulator: [String]?
    /// Tracks performKeyEquivalent redispatch to avoid duplicate command handling.
    private var lastPerformKeyEvent: TimeInterval?
    /// Window-scoped observers for screen/key changes.
    private var windowObservers: [NSObjectProtocol] = []
    /// Last applied light/dark color scheme sent to Ghostty.
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var pendingStartupText: String?
    private var pendingStartupTextDeliveryScheduled = false
    private var deliveredStartupText = false
    private var lastAccessibilityFocusState = false

    private static let startupTextDeliveryDelay: TimeInterval = 0.25

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        let s = surface
        let h = surfaceHandle
        if let s {
            ghostty_surface_free(s)
        }
        h?.release()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        updateTrackingAreas()
        registerForDraggedTypes(Array(GhosttyPasteboardHelper.dropTypes))
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    // MARK: - Surface creation

    func createSurface(
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:]
    ) {
        guard let ghosttyApp = GhosttyRuntime.shared.app else {
            print("[Shuttle] Cannot create surface: Ghostty runtime not ready")
            return
        }

        // Build surface config
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )

        // Callback userdata
        let handle = GhosttySurfaceHandle(surfaceId: surfaceId, surfaceView: self)
        let unmanagedHandle = Unmanaged.passRetained(handle)
        self.surfaceHandle = unmanagedHandle
        surfaceConfig.userdata = unmanagedHandle.toOpaque()

        // Scale factor
        let scaleFactor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        surfaceConfig.scale_factor = Double(scaleFactor)
        // `TAB` matches cmux's top-level embedded surfaces. Using `WINDOW` here can
        // make libghostty behave like a standalone window surface, which appears to
        // conflict with the launching terminal / current process tty.
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Build env vars array
        var effectiveEnvironment = environmentVariables
        configureShellIntegrationEnvironment(&effectiveEnvironment)

        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []

        for (key, value) in effectiveEnvironment {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            envStorage.append((keyPtr, valuePtr))
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }

        // Create the surface with working directory and env vars.
        let createSurface = { [self] in
            if !envVars.isEmpty {
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = buffer.count
                    self.surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
            }
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            workingDirectory.withCString { cDir in
                surfaceConfig.working_directory = cDir
                createSurface()
            }
        } else {
            createSurface()
        }

        // Free env var storage
        for (key, value) in envStorage {
            free(key)
            free(value)
        }

        guard let createdSurface = surface else {
            print("[Shuttle] Failed to create ghostty surface")
            return
        }

        // Store surface in the handle for callbacks
        handle.surface = createdSurface

        // Configure the surface using the current backing metrics. This may be
        // refined again once the view is actually attached to a window/screen.
        syncSurfaceMetrics(forceRefresh: true)
        deliverPendingStartupTextIfPossible()
    }

    private func resolveShellIntegrationDirectory() -> String? {
        let fileManager = FileManager.default
        let swiftPMResourceBundleName = "Shuttle_ShuttleApp.bundle"
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let resourceDirectory = Bundle.main.resourceURL
        let bundleDirectory = Bundle.main.bundleURL
        let fallbackSourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/shell-integration", isDirectory: true)

        let candidates: [URL?] = [
            resourceDirectory?.appendingPathComponent("\(swiftPMResourceBundleName)/Resources/shell-integration", isDirectory: true),
            resourceDirectory?.appendingPathComponent("Resources/shell-integration", isDirectory: true),
            resourceDirectory?.appendingPathComponent("shell-integration", isDirectory: true),
            bundleDirectory.appendingPathComponent("\(swiftPMResourceBundleName)/Resources/shell-integration", isDirectory: true),
            executableDirectory?.appendingPathComponent("\(swiftPMResourceBundleName)/Resources/shell-integration", isDirectory: true),
            executableDirectory?.appendingPathComponent("Resources/shell-integration", isDirectory: true),
            fallbackSourceDirectory,
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let path = candidate.path(percentEncoded: false)
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func normalizeShellPath(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private func resolvedShellPath(for environment: [String: String]) -> String {
        if let shell = normalizeShellPath(environment["SHELL"]) {
            return shell
        }

        if let passwordEntry = getpwuid(getuid()),
           let shellPointer = passwordEntry.pointee.pw_shell,
           shellPointer.pointee != 0 {
            let shell = String(cString: shellPointer).trimmingCharacters(in: .whitespacesAndNewlines)
            if !shell.isEmpty {
                return shell
            }
        }

        if let shell = normalizeShellPath(getenv("SHELL").map { String(cString: $0) }) {
            return shell
        }

        if let shell = normalizeShellPath(ProcessInfo.processInfo.environment["SHELL"]) {
            return shell
        }

        return "/bin/zsh"
    }

    private func configureShellIntegrationEnvironment(_ environment: inout [String: String]) {
        let shell = resolvedShellPath(for: environment)
        environment["SHELL"] = shell

        guard let integrationDir = resolveShellIntegrationDirectory() else {
            return
        }

        environment["SHUTTLE_SHELL_INTEGRATION"] = "1"
        environment["SHUTTLE_SHELL_INTEGRATION_DIR"] = integrationDir

        environment["SHUTTLE_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        let candidateZdotdir = (environment["ZDOTDIR"]?.isEmpty == false ? environment["ZDOTDIR"] : nil)
            ?? getenv("ZDOTDIR").map { String(cString: $0) }
            ?? ProcessInfo.processInfo.environment["ZDOTDIR"]
        if let candidateZdotdir, !candidateZdotdir.isEmpty {
            environment["SHUTTLE_ZSH_ZDOTDIR"] = candidateZdotdir
        }
        environment["ZDOTDIR"] = integrationDir

        environment["SHUTTLE_LOAD_GHOSTTY_BASH_INTEGRATION"] = "1"
        environment["PROMPT_COMMAND"] = """
        unset PROMPT_COMMAND; \
        if [[ \"${SHUTTLE_LOAD_GHOSTTY_BASH_INTEGRATION:-0}\" == \"1\" && -n \"${GHOSTTY_RESOURCES_DIR:-}\" ]]; then \
        _shuttle_ghostty_bash=\"$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash\"; \
        [[ -r \"$_shuttle_ghostty_bash\" ]] && source \"$_shuttle_ghostty_bash\"; \
        fi; \
        if [[ \"${SHUTTLE_SHELL_INTEGRATION:-1}\" != \"0\" && -n \"${SHUTTLE_SHELL_INTEGRATION_DIR:-}\" ]]; then \
        _shuttle_bash_integration=\"$SHUTTLE_SHELL_INTEGRATION_DIR/shuttle-bash-integration.bash\"; \
        [[ -r \"$_shuttle_bash_integration\" ]] && source \"$_shuttle_bash_integration\"; \
        fi; \
        unset _shuttle_ghostty_bash _shuttle_bash_integration; \
        if declare -F _shuttle_prompt_command >/dev/null 2>&1; then _shuttle_prompt_command; fi
        """
    }

    // MARK: - Size management

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceMetrics(forceRefresh: false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeWindowObservers()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else { return }

        installWindowObservers(for: window)
        syncSurfaceMetrics(forceRefresh: true)
        applySurfaceColorScheme(force: true)
        updateSurfaceVisibilityFromWindow()
        updateSurfaceFocusFromWindow()
        deliverPendingStartupTextIfPossible()

        // Request first responder focus when we get attached to a window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func installWindowObservers(for window: NSWindow) {
        let center = NotificationCenter.default

        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSurfaceMetrics(forceRefresh: true)
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSurfaceMetrics(forceRefresh: true)
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenProfileNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSurfaceMetrics(forceRefresh: true)
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSurfaceFocusFromWindow()
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSurfaceFocusFromWindow()
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSurfaceVisibilityFromWindow()
            }
        })
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func updateSurfaceDisplayID() {
        guard let surface,
              let screen = window?.screen ?? NSScreen.main,
              let displayID = screen.displayID,
              displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    private func updateSurfaceFocusFromWindow() {
        guard let surface else { return }
        let focused = (window?.isKeyWindow ?? false) && (window?.firstResponder === self)
        ghostty_surface_set_focus(surface, focused)
        if focused {
            updateSurfaceDisplayID()
        }
        if focused != lastAccessibilityFocusState {
            lastAccessibilityFocusState = focused
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    private func updateSurfaceVisibilityFromWindow() {
        guard let surface else { return }
        let visible = (window?.occlusionState.contains(.visible) ?? false) || (window?.isKeyWindow ?? false)
        ghostty_surface_set_occlusion(surface, visible)
    }

    private func applySurfaceColorScheme(force: Bool = false) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let scheme: ghostty_color_scheme_e = bestMatch == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        if !force, appliedColorScheme == scheme {
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
    }

    private func currentBackingScaleFactor() -> CGFloat {
        window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
    }

    private func currentDrawableSize() -> CGSize {
        let backing = convertToBacking(bounds)
        return CGSize(
            width: max(backing.width.rounded(.up), 1),
            height: max(backing.height.rounded(.up), 1)
        )
    }

    private func syncSurfaceMetrics(forceRefresh: Bool) {
        let scale = currentBackingScaleFactor()
        layer?.contentsScale = scale

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            let drawableSize = currentDrawableSize()
            if metalLayer.drawableSize != drawableSize {
                metalLayer.drawableSize = drawableSize
            }
        }

        guard let surface, bounds.width > 0, bounds.height > 0 else { return }

        var needsRefresh = forceRefresh

        if scale != lastScaleX {
            lastScaleX = scale
            ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            needsRefresh = true
        }

        let drawableSize = currentDrawableSize()
        let newW = UInt32(drawableSize.width)
        let newH = UInt32(drawableSize.height)
        if newW != lastPixelWidth || newH != lastPixelHeight {
            lastPixelWidth = newW
            lastPixelHeight = newH
            ghostty_surface_set_size(surface, newW, newH)
            needsRefresh = true
        }

        if needsRefresh {
            updateSurfaceDisplayID()
            ghostty_surface_refresh(surface)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurfaceMetrics(forceRefresh: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceColorScheme()
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { prefersKeyboardFocus || userInitiatedFocusRequest }

    // Allow focus on first click even when window isn't key
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Allow this view to become key view for keyboard input
    override var needsPanelToBecomeKey: Bool { false }

    override func becomeFirstResponder() -> Bool {
        guard prefersKeyboardFocus || userInitiatedFocusRequest else {
            return false
        }
        let wasUserInitiated = userInitiatedFocusRequest
        userInitiatedFocusRequest = false
        let result = super.becomeFirstResponder()
        if result {
            TerminalFocusCoordinator.shared.setActiveSurfaceView(self)
            onFocus?(wasUserInitiated)
            updateSurfaceFocusFromWindow()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        userInitiatedFocusRequest = false
        let result = super.resignFirstResponder()
        if result {
            updateSurfaceFocusFromWindow()
        }
        return result
    }

    // MARK: - Tracking area

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
        super.updateTrackingAreas()
    }

    // MARK: - Keyboard events

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard let surface else { return false }

        if hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
            let isPerformable = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0

            if isConsumed && !isAll && !isPerformable,
               let menu = NSApp.mainMenu,
               menu.performKeyEquivalent(with: event) {
                return true
            }

            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"
        default:
            if event.timestamp == 0 {
                return false
            }
            if !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                return false
            }
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            ghostty_surface_set_focus(surface, true)
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false

            let text = (event.charactersIgnoringModifiers ?? event.characters ?? "")
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                handled = ghostty_surface_key(surface, keyEvent)
            } else {
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
            }
            if handled { return }
        }

        let translationEvent = translatedEvent(for: event, surface: surface)
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        interpretKeyEvents([translationEvent])

        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        let accumulatedText = keyTextAccumulator ?? []
        if !accumulatedText.isEmpty {
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else if let text = textForKeyEvent(translationEvent) {
            if shouldSendText(text) {
                keyEvent.composing = false
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else {
            super.keyUp(with: event)
            return
        }
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else {
            super.flagsChanged(with: event)
            return
        }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = translateModifiers(event.modifierFlags)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        // `characters(byApplyingModifiers:)` asserts for `.flagsChanged` events.
        // Voice-input / accessibility tooling can synthesize modifier-only events
        // while injecting text, and Ghostty doesn't need a textual codepoint for
        // pure modifier transitions anyway.
        keyEvent.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, keyEvent)
    }

    private func translatedEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translationModsGhostty = ghostty_surface_key_translation_mods(
            surface,
            translateModifiers(event.modifierFlags)
        )
        guard translationModsGhostty != translateModifiers(event.modifierFlags) else {
            return event
        }

        let newFlags = translateModifiersReverse(translationModsGhostty)
            .union(event.modifierFlags.intersection([.numericPad, .function]))
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: newFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: newFlags) ?? event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        let translationEvent = translatedEvent(for: event, surface: surface)
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = translateModifiers(event.modifierFlags)
        keyEvent.consumed_mods = consumedModsFromFlags(translationEvent.modifierFlags)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        // Explicitly activate Shuttle and make the terminal window key before routing
        // the click. When launched from another terminal app, the GUI window can be
        // frontmost without actually stealing key focus from the launcher.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
        TerminalFocusCoordinator.shared.setActiveSurfaceView(self)
        userInitiatedFocusRequest = true
        window?.makeFirstResponder(nil)
        if window?.makeFirstResponder(self) != true {
            userInitiatedFocusRequest = false
        }

        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, translateModifiers(event.modifierFlags))
        let _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            translateModifiers(event.modifierFlags)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            translateModifiers(event.modifierFlags)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_RIGHT,
            translateModifiers(event.modifierFlags)
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_RIGHT,
            translateModifiers(event.modifierFlags)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, translateModifiers(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, translateModifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            mods |= 1 // precision scrolling flag
        }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            mods
        )
    }

    // MARK: - Paste / drop helpers

    func queueStartupText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty else { return }
        pendingStartupText = normalized + "\n"
        deliverPendingStartupTextIfPossible()
    }

    private func deliverPendingStartupTextIfPossible() {
        guard !deliveredStartupText,
              !pendingStartupTextDeliveryScheduled,
              let pendingStartupText,
              !pendingStartupText.isEmpty,
              surface != nil,
              window != nil else {
            return
        }

        pendingStartupTextDeliveryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTextDeliveryDelay) { [weak self] in
            guard let self else { return }
            self.pendingStartupTextDeliveryScheduled = false
            guard !self.deliveredStartupText,
                  self.surface != nil,
                  self.window != nil,
                  let pendingStartupText = self.pendingStartupText,
                  !pendingStartupText.isEmpty else {
                self.deliverPendingStartupTextIfPossible()
                return
            }

            guard self.sendProgrammaticInput(pendingStartupText) else {
                self.deliverPendingStartupTextIfPossible()
                return
            }
            self.pendingStartupText = nil
            self.deliveredStartupText = true
        }
    }

    @discardableResult
    private func pasteText(_ text: String) -> Bool {
        guard let surface, !text.isEmpty else { return false }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
        return true
    }

    @discardableResult
    private func sendReturnKey() -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 36
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0x0D
        return ghostty_surface_key(surface, keyEvent)
    }

    @discardableResult
    func sendProgrammaticInput(_ text: String) -> Bool {
        let chunks = shuttleProgrammaticTerminalInputChunks(for: text)
        guard !chunks.isEmpty else { return false }

        var deliveredAny = false
        for chunk in chunks {
            switch chunk {
            case .text(let segment):
                guard pasteText(segment) else { return false }
                deliveredAny = true
            case .submit:
                guard sendReturnKey() else { return false }
                deliveredAny = true
            }
        }
        return deliveredAny
    }

    @discardableResult
    func sendText(_ text: String, submit: Bool) -> Bool {
        if !text.isEmpty {
            guard pasteText(text) else { return false }
            if submit {
                return sendReturnKey()
            }
            return true
        }

        if submit {
            return sendReturnKey()
        }
        return false
    }

    func sendText(_ text: String) {
        _ = pasteText(text)
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func captureScrollback(
        maxLines: Int = ShuttleTerminalRestorationPolicy.maxScrollbackLinesPerTab
    ) -> String? {
        // Match cmux's snapshotting approach: prefer Ghostty's VT export so we
        // preserve ANSI/styled output, but snapshot and restore the pasteboard
        // around the clipboard-backed export. Fall back to direct surface reads
        // if the export path is unavailable.
        if let vtExport = captureScrollbackViaVTExport(maxLines: maxLines) {
            return vtExport
        }
        return captureScrollbackViaSurfaceRead(maxLines: maxLines)
    }

    func captureVisibleScreen(
        maxLines: Int = ShuttleTerminalRestorationPolicy.maxScrollbackLinesPerTab
    ) -> String? {
        captureSurfaceText(pointTags: [GHOSTTY_POINT_SCREEN], maxLines: maxLines)
    }

    private func captureScrollbackViaVTExport(maxLines: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = GhosttyPasteboardHelper.snapshotPasteboardItems(pasteboard)
        defer {
            GhosttyPasteboardHelper.restorePasteboardItems(snapshot, to: pasteboard)
        }

        let initialChangeCount = pasteboard.changeCount
        guard performBindingAction("write_screen_file:copy,vt") else {
            return nil
        }
        guard pasteboard.changeCount != initialChangeCount else {
            return nil
        }
        guard let exportedPath = GhosttyPasteboardHelper.normalizedExportedScreenPath(
            GhosttyPasteboardHelper.readGeneralPasteboardString(pasteboard)
        ) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if GhosttyPasteboardHelper.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if GhosttyPasteboardHelper.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              var output = String(data: data, encoding: .utf8) else {
            return nil
        }
        if maxLines > 0 {
            output = tailTerminalLines(output, maxLines: maxLines)
        }
        return output
    }

    private func captureScrollbackViaSurfaceRead(maxLines: Int) -> String? {
        let screen = readSelectionText(pointTag: GHOSTTY_POINT_SCREEN)
        let history = readSelectionText(pointTag: GHOSTTY_POINT_SURFACE)
        let active = readSelectionText(pointTag: GHOSTTY_POINT_ACTIVE)

        var candidates: [String] = []
        if let screen {
            candidates.append(screen)
        }
        if history != nil || active != nil {
            var merged = history ?? ""
            if let active {
                if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                    merged.append("\n")
                }
                merged.append(active)
            }
            candidates.append(merged)
        }

        return normalizeCapturedText(candidates: candidates, maxLines: maxLines)
    }

    private func captureSurfaceText(pointTags: [ghostty_point_tag_e], maxLines: Int) -> String? {
        normalizeCapturedText(candidates: pointTags.compactMap { readSelectionText(pointTag: $0) }, maxLines: maxLines)
    }

    private func normalizeCapturedText(candidates: [String], maxLines: Int) -> String? {
        guard !candidates.isEmpty else {
            return nil
        }

        guard var output = candidates.max(by: { lhs, rhs in
            let left = candidateScore(lhs)
            let right = candidateScore(rhs)
            if left.lines != right.lines {
                return left.lines < right.lines
            }
            return left.bytes < right.bytes
        }) else {
            return nil
        }

        if maxLines > 0 {
            output = tailTerminalLines(output, maxLines: maxLines)
        }
        return output
    }

    private func readSelectionText(pointTag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text else {
            return ""
        }
        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    private func candidateScore(_ text: String) -> (lines: Int, bytes: Int) {
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (lines, text.utf8.count)
    }

    private func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        var tail = lines.suffix(maxLines).joined(separator: "\n")
        if text.hasSuffix("\n") {
            tail.append("\n")
        }
        return tail
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: GhosttyPasteboardHelper.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: GhosttyPasteboardHelper.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = GhosttyPasteboardHelper.terminalReadyText(from: sender.draggingPasteboard) else {
            return false
        }
        sendText(text)
        return true
    }

    // MARK: - Text input (NSTextInputClient)
    //
    // These methods are called by interpretKeyEvents during keyDown processing.
    // They accumulate the resulting text which is then sent to the ghostty surface.

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }

        // Clear any marked (composing) text
        markedText = NSMutableAttributedString()

        // Store text for the keyDown handler to send to ghostty.
        if keyTextAccumulator == nil {
            keyTextAccumulator = []
        }
        keyTextAccumulator?.append(text)
    }

    /// Responder-chain `insertText:` (single-argument form, used by voice input apps).
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func doCommand(by selector: Selector) {
        // Swallow responder-chain commands that only signal key handling.
        // This prevents NSBeep for actions handled through interpretKeyEvents.
    }

    // MARK: - IME support

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface else { return }
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }

        markedText = NSMutableAttributedString(string: text)
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        guard let surface else { return }
        markedText = NSMutableAttributedString()
        ghostty_surface_preedit(surface, nil, 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        let viewPoint = NSPoint(x: x, y: bounds.height - y)
        guard let window else { return NSRect(origin: viewPoint, size: NSSize(width: w, height: h)) }
        let windowPoint = convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        return NSRect(origin: screenPoint, size: NSSize(width: w, height: h))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .font]
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        "Terminal"
    }

    override func accessibilityValue() -> Any? {
        markedText.string
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let string = value as? String, !string.isEmpty else { return }
        TerminalFocusCoordinator.shared.setActiveSurfaceView(self)
        if window?.firstResponder !== self {
            _ = window?.makeFirstResponder(self)
        }
        sendText(string)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func isAccessibilityFocused() -> Bool {
        (window?.isKeyWindow ?? false) && (window?.firstResponder === self)
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused else { return }
        TerminalFocusCoordinator.shared.setActiveSurfaceView(self)
        _ = window?.makeFirstResponder(self)
        updateSurfaceFocusFromWindow()
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        let rectInWindow = convert(bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        0
    }

    override func accessibilityNumberOfCharacters() -> Int {
        markedText.string.utf16.count
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let count = accessibilityNumberOfCharacters()
        return NSRange(location: 0, length: count)
    }

    override func accessibilitySelectedText() -> String? {
        nil
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        let count = accessibilityNumberOfCharacters()
        return NSRange(location: count, length: 0)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        TerminalFocusCoordinator.shared.setActiveSurfaceView(self)
        if window?.firstResponder !== self {
            _ = window?.makeFirstResponder(self)
        }
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        [NSValue(range: accessibilitySelectedTextRange())]
    }

    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        setAccessibilitySelectedTextRange(accessibilitySelectedTextRange())
    }

    // MARK: - Modifier / key translation

    private func translateModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func translateModifiersReverse(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only Shift and Option can be consumed for text translation.
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }

            // Private-use function-key codepoints should not be sent as text.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp else {
            return 0
        }
        if let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            return scalar.value
        }
        if let chars = (event.charactersIgnoringModifiers ?? event.characters),
           let scalar = chars.unicodeScalars.first {
            return scalar.value
        }
        return 0
    }

    private func isControlCharacterScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            return !isControlCharacterScalar(scalar)
        }
        return true
    }
}

// MARK: - NSScreen displayID extension

extension NSScreen {
    var displayID: UInt32? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}
