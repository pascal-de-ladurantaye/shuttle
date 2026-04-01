import Foundation
import AppKit
import UserNotifications
import GhosttyKit

// MARK: - Ghostty App Singleton
// Initializes the libghostty library, loads user config, and creates the
// ghostty_app_t that all terminal surfaces are spawned from.

@MainActor
final class GhosttyRuntime: ObservableObject {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    @Published private(set) var isReady = false
    private var appObservers: [NSObjectProtocol] = []

    /// Default terminal background color extracted from the Ghostty config.
    @Published private(set) var defaultBackgroundColor: NSColor = .black
    @Published private(set) var defaultBackgroundOpacity: Double = 1.0

    private init() {
        initializeGhostty()
    }

    // MARK: - Initialization

    private func initializeGhostty() {
        // Ensure terminal apps can use colors even if NO_COLOR is set
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Set GHOSTTY_RESOURCES_DIR if not already set and Ghostty.app is installed
        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            let candidates = [
                "/Applications/Ghostty.app/Contents/Resources/ghostty",
                Bundle.main.resourcePath.map { $0 + "/ghostty" },
            ].compactMap { $0 }
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate) {
                    setenv("GHOSTTY_RESOURCES_DIR", candidate, 1)
                    print("[Shuttle] Set GHOSTTY_RESOURCES_DIR to \(candidate)")
                    break
                }
            }
        }

        // Set TERMINFO so shells inside the terminal find xterm-ghostty
        if getenv("TERMINFO") == nil {
            let terminfoCandidates = [
                "/Applications/Ghostty.app/Contents/Resources/terminfo",
                Bundle.main.resourcePath.map { $0 + "/terminfo" },
            ].compactMap { $0 }
            for candidate in terminfoCandidates {
                if FileManager.default.fileExists(atPath: candidate) {
                    setenv("TERMINFO", candidate, 1)
                    print("[Shuttle] Set TERMINFO to \(candidate)")
                    break
                }
            }
        }

        // 1. One-time library initialization
        // Pass minimal argc/argv (just the program name) to avoid ghostty
        // interpreting our app's command line arguments.
        let programName = ("ShuttleApp" as NSString).utf8String!
        var argv: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: programName)
        let initResult = withUnsafeMutablePointer(to: &argv) { argvPtr in
            ghostty_init(1, argvPtr)
        }
        guard initResult == GHOSTTY_SUCCESS else {
            print("[Shuttle] Failed to initialize ghostty library: \(initResult)")
            return
        }

        // 2. Create and load config using Ghostty’s standard default-file search order
        guard let primaryConfig = ghostty_config_new() else {
            print("[Shuttle] Failed to create ghostty config")
            return
        }

        ghostty_config_load_default_files(primaryConfig)
        ghostty_config_load_recursive_files(primaryConfig)

        // Override the IPC class so Shuttle doesn't conflict with a running Ghostty.app.
        // Ghostty uses the "class" config option to namespace IPC (mach ports, etc.).
        // Without this, our embedded libghostty would try to communicate with the
        // standalone Ghostty process and cause focus/input routing issues.
        loadShuttleOverrideConfig(primaryConfig)

        ghostty_config_finalize(primaryConfig)
        extractDefaultBackground(from: primaryConfig)

        // 3. Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true

        runtimeConfig.wakeup_cb = { _ in
            DispatchQueue.main.async {
                GhosttyRuntime.shared.tick()
            }
        }

        runtimeConfig.action_cb = { app, target, action in
            return GhosttyRuntime.shared.handleAction(target: target, action: action)
        }

        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            DispatchQueue.main.async {
                GhosttyRuntime.shared.handleReadClipboard(
                    userdata: userdata, location: location, state: state
                )
            }
        }

        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let userdata,
                  let surface = Unmanaged<GhosttySurfaceHandle>.fromOpaque(userdata)
                      .takeUnretainedValue().surface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            guard let content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyRuntime.writeClipboard(value, to: location)
                        return
                    }
                }
                if fallback == nil { fallback = value }
            }
            if let fallback { GhosttyRuntime.writeClipboard(fallback, to: location) }
        }

        runtimeConfig.close_surface_cb = { userdata, needsConfirm in
            guard let userdata else { return }
            let handle = Unmanaged<GhosttySurfaceHandle>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .ghosttySurfaceDidClose,
                    object: nil,
                    userInfo: [
                        "surfaceId": handle.surfaceId,
                        "needsConfirm": needsConfirm,
                    ]
                )
            }
        }

        // 4. Create the app
        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
            self.isReady = true
            print("[Shuttle] Ghostty runtime initialized successfully")
        } else {
            print("[Shuttle] ghostty_app_new failed, trying fallback config...")
            ghostty_config_free(primaryConfig)

            // Fallback: minimal config
            guard let fallbackConfig = ghostty_config_new() else {
                print("[Shuttle] Failed to create fallback ghostty config")
                return
            }
            ghostty_config_finalize(fallbackConfig)

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                print("[Shuttle] ghostty_app_new(fallback) also failed")
                ghostty_config_free(fallbackConfig)
                return
            }

            self.app = created
            self.config = fallbackConfig
            self.isReady = true
            print("[Shuttle] Ghostty runtime initialized with fallback config")
        }

        // Keep Ghostty's app-level focus state in sync with AppKit.
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }
        registerAppFocusObservers()
    }

    private func registerAppFocusObservers() {
        guard appObservers.isEmpty else { return }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let app = self?.app else { return }
                ghostty_app_set_focus(app, true)
            }
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let app = self?.app else { return }
                ghostty_app_set_focus(app, false)
            }
        })
    }

    // MARK: - Tick

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Action handling

    nonisolated private func handleAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        let surfaceId = Self.surfaceId(from: target)
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let titleAction = action.action.set_title
            if let cTitle = titleAction.title {
                let title = String(cString: cTitle)
                DispatchQueue.main.async {
                    var userInfo: [String: Any] = ["title": title]
                    if let surfaceId {
                        userInfo["surfaceId"] = surfaceId
                    }
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceTitleChanged,
                        object: nil,
                        userInfo: userInfo
                    )
                }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let pwdAction = action.action.pwd
            if let cDir = pwdAction.pwd {
                let dir = String(cString: cDir)
                DispatchQueue.main.async {
                    var userInfo: [String: Any] = ["pwd": dir]
                    if let surfaceId {
                        userInfo["surfaceId"] = surfaceId
                    }
                    NotificationCenter.default.post(
                        name: .ghosttySurfacePwdChanged,
                        object: nil,
                        userInfo: userInfo
                    )
                }
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let notif = action.action.desktop_notification
            var title = "Terminal"
            var body = ""
            if let cTitle = notif.title {
                title = String(cString: cTitle)
            }
            if let cBody = notif.body {
                body = String(cString: cBody)
            }
            DispatchQueue.main.async {
                Self.deliverDesktopNotification(title: title, body: body)
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                NSSound.beep()
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let urlAction = action.action.open_url
            if let cURL = urlAction.url {
                let urlString = String(cString: cURL)
                if let url = URL(string: urlString) {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return true // Handled by NSView cursor tracking

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return true

        default:
            return false
        }
    }

    private nonisolated static func surfaceId(from target: ghostty_target_s) -> UUID? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return nil }
        let handle = Unmanaged<GhosttySurfaceHandle>.fromOpaque(userdata).takeUnretainedValue()
        return handle.surfaceId
    }

    private static func deliverDesktopNotification(title: String, body: String) {
        guard supportsUserNotificationCenter else {
            _ = NSApplication.shared.requestUserAttention(.informationalRequest)
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                print("[Shuttle] Skipping desktop notification outside an app bundle: \(title)")
            } else {
                print("[Shuttle] Skipping desktop notification outside an app bundle: \(title) — \(trimmedBody)")
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static var supportsUserNotificationCenter: Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            return false
        }
        return Bundle.main.infoDictionary != nil
    }

    // MARK: - Clipboard

    nonisolated private func handleReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        guard let userdata else { return }
        let handle = Unmanaged<GhosttySurfaceHandle>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = handle.surface else { return }

        let pasteboard = Self.pasteboard(for: location)
        let text = pasteboard.flatMap { GhosttyPasteboardHelper.terminalReadyText(from: $0) } ?? ""
        text.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
    }

    private nonisolated static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return NSPasteboard(name: NSPasteboard.Name("com.shuttle.selection"))
        default:
            return nil
        }
    }

    nonisolated static func writeClipboard(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - Config helpers

    /// Writes a temporary config file that overrides the ghostty `class` to
    /// prevent IPC collisions with a running Ghostty.app instance.
    private func loadShuttleOverrideConfig(_ config: ghostty_config_t) {
        let overrides = """
        class = com.shuttle.terminal
        gtk-single-instance = false
        """

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shuttle-ghostty-override-\(UUID().uuidString).conf")
        do {
            try overrides.write(to: tmpURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            tmpURL.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            print("[Shuttle] Loaded IPC isolation config (class = com.shuttle.terminal)")
        } catch {
            print("[Shuttle] Warning: failed to write override config: \(error)")
        }
    }

    private func extractDefaultBackground(from config: ghostty_config_t) {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)
        if ghostty_config_get(config, &color, "background", 10) {
            defaultBackgroundColor = NSColor(
                red: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: 1.0
            )
        }

        var opacity: Double = 1.0
        if ghostty_config_get(config, &opacity, "background-opacity", 18) {
            defaultBackgroundOpacity = opacity
        }
    }
}

// MARK: - Surface Handle

/// Opaque handle passed as userdata to ghostty surface callbacks.
/// Prevents the surface view from being retained by the C callback layer.
final class GhosttySurfaceHandle: @unchecked Sendable {
    let surfaceId: UUID
    weak var surfaceView: GhosttyNSView?
    var surface: ghostty_surface_t?

    init(surfaceId: UUID, surfaceView: GhosttyNSView) {
        self.surfaceId = surfaceId
        self.surfaceView = surfaceView
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let ghosttySurfaceDidClose = Notification.Name("ghosttySurfaceDidClose")
    static let ghosttySurfaceTitleChanged = Notification.Name("ghosttySurfaceTitleChanged")
    static let ghosttySurfacePwdChanged = Notification.Name("ghosttySurfacePwdChanged")
}
