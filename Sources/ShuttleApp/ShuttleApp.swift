import SwiftUI
import AppKit
import ShuttleKit

final class ShuttleApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let appMenuItem = app.mainMenu?.item(at: 0) {
            appMenuItem.title = ShuttleProfile.current.appDisplayName
        }
        TerminalFocusCoordinator.shared.installIfNeeded()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        DispatchQueue.main.async {
            app.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        Task {
            await terminationHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private enum ShuttleMainWindow {
    static let id = "main-window"

    static var frameAutosaveName: String {
        "\(ShuttleProfile.current.bundleIdentifier).main-window"
    }
}

@main
struct ShuttleDesktopApp: App {
    @NSApplicationDelegateAdaptor(ShuttleApplicationDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: ShuttleAppModel
    @StateObject private var layoutLibrary: LayoutLibraryModel
    @State private var isSidebarVisible = true
    @State private var isCommandPalettePresented = false

    init() {
        // Force NSApplication initialization early without relying on the `NSApp`
        // implicit IUO, which is still nil in SwiftUI App.init() for CLI-launched builds.
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        ShuttlePreferences.registerDefaults()
        _model = StateObject(wrappedValue: ShuttleAppModel())
        _layoutLibrary = StateObject(wrappedValue: LayoutLibraryModel())
    }

    var body: some Scene {
        WindowGroup(LocalizedStringKey(ShuttleProfile.current.appDisplayName), id: ShuttleMainWindow.id) {
            ContentView(isSidebarVisible: $isSidebarVisible, isCommandPalettePresented: $isCommandPalettePresented)
                .defaultAppStorage(ShuttlePreferences.userDefaults)
                .environmentObject(model)
                .environmentObject(layoutLibrary)
                .background(WindowChromeConfigurator(frameAutosaveName: ShuttleMainWindow.frameAutosaveName))
                .task {
                    appDelegate.terminationHandler = {
                        await model.prepareForTermination()
                    }
                    await model.refresh(initialScanIfNeeded: true)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        NSRunningApplication.current.activate(options: [.activateAllWindows])
                        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase != .active {
                        Task {
                            model.persistActiveSnapshot(includeScrollback: true)
                            await GhosttyCheckpointWriter.shared.flushAll()
                        }
                    }
                }
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            ShuttlePaneCommands(model: model)
            ShuttleTabCommands(model: model)
            ShuttleFileCommands(model: model)
            ShuttleViewCommands(isSidebarVisible: $isSidebarVisible, isCommandPalettePresented: $isCommandPalettePresented)
            ShuttleLayoutCommands()
        }

        Settings {
            ShuttleSettingsView()
                .defaultAppStorage(ShuttlePreferences.userDefaults)
                .environmentObject(layoutLibrary)
        }

        Window(LocalizedStringKey("\(ShuttleProfile.current.appDisplayName) Layout Builder"), id: ShuttleLayoutBuilderWindow.id) {
            ShuttleLayoutBuilderView()
                .defaultAppStorage(ShuttlePreferences.userDefaults)
                .environmentObject(layoutLibrary)
        }
        .defaultSize(width: 1100, height: 720)
    }
}

private final class WindowChromeConfigurationView: NSView {
    var configuredWindowNumber: Int?
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    let frameAutosaveName: String

    func makeNSView(context: Context) -> WindowChromeConfigurationView {
        let view = WindowChromeConfigurationView(frame: .zero)
        DispatchQueue.main.async {
            configure(view)
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeConfigurationView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView)
        }
    }

    private func configure(_ view: WindowChromeConfigurationView) {
        guard let window = view.window else { return }
        window.tabbingMode = .disallowed
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        guard view.configuredWindowNumber != window.windowNumber else { return }
        view.configuredWindowNumber = window.windowNumber

        let autosaveName = NSWindow.FrameAutosaveName(frameAutosaveName)
        _ = window.setFrameAutosaveName(autosaveName)
        _ = window.setFrameUsingName(autosaveName)
    }
}

struct ShuttlePaneCommands: Commands {
    @ObservedObject var model: ShuttleAppModel

    private static let splitH = ShuttleActionDescriptor[.paneSplitHorizontal]
    private static let splitV = ShuttleActionDescriptor[.paneSplitVertical]
    private static let focusNext = ShuttleActionDescriptor[.paneFocusNext]
    private static let focusPrev = ShuttleActionDescriptor[.paneFocusPrevious]

    var body: some Commands {
        CommandMenu("Pane") {
            Button(Self.splitH.label) {
                Task { await model.splitFocusedPane(direction: .down) }
            }
            .keyboardShortcut(Self.splitH.keyboardShortcut!)
            .disabled(!model.canSplitFocusedPane)

            Button(Self.splitV.label) {
                Task { await model.splitFocusedPane(direction: .right) }
            }
            .keyboardShortcut(Self.splitV.keyboardShortcut!)
            .disabled(!model.canSplitFocusedPane)

            Divider()

            Button(Self.focusNext.label) {
                model.focusNextPane()
            }
            .keyboardShortcut(Self.focusNext.keyboardShortcut!)
            .disabled(!model.hasMultiplePanes)

            Button(Self.focusPrev.label) {
                model.focusPreviousPane()
            }
            .keyboardShortcut(Self.focusPrev.keyboardShortcut!)
            .disabled(!model.hasMultiplePanes)
        }
    }
}

struct ShuttleTabCommands: Commands {
    @ObservedObject var model: ShuttleAppModel

    private static let newTab = ShuttleActionDescriptor[.tabNew]
    private static let closeTab = ShuttleActionDescriptor[.tabClose]
    private static let nextTab = ShuttleActionDescriptor[.tabNext]
    private static let prevTab = ShuttleActionDescriptor[.tabPrevious]

    var body: some Commands {
        CommandMenu("Tab") {
            Button(Self.newTab.label) {
                Task { await model.createTabInFocusedPane() }
            }
            .keyboardShortcut(Self.newTab.keyboardShortcut!)
            .disabled(!model.canCreateTabInFocusedPane)

            Button(Self.closeTab.label) {
                Task { await model.closeFocusedTab() }
            }
            .disabled(!model.canCloseFocusedTab)

            Divider()

            Button(Self.nextTab.label) {
                model.selectNextTab()
            }
            .keyboardShortcut(Self.nextTab.keyboardShortcut!)
            .disabled(!model.hasMultipleTabsInFocusedPane)

            Button(Self.prevTab.label) {
                model.selectPreviousTab()
            }
            .keyboardShortcut(Self.prevTab.keyboardShortcut!)
            .disabled(!model.hasMultipleTabsInFocusedPane)

            Divider()

            ForEach(1...9, id: \.self) { index in
                let desc = ShuttleActionDescriptor[ShuttleTabCommands.tabSelectID(index)]
                Button(desc.label) {
                    model.selectTabByIndex(index - 1)
                }
                .keyboardShortcut(desc.keyboardShortcut!)
                .disabled(!model.canSelectTabByIndex(index - 1))
            }
        }
    }

    static func tabSelectID(_ index: Int) -> ShuttleActionID {
        [.tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5,
         .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9][index - 1]
    }
}

struct ShuttleFileCommands: Commands {
    @ObservedObject var model: ShuttleAppModel

    private static let closeTab = ShuttleActionDescriptor[.tabClose]
    private static let closeWindow = ShuttleActionDescriptor[.viewCloseWindow]

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(Self.closeTab.label) {
                Task { await model.closeFocusedTab() }
            }
            .keyboardShortcut(Self.closeTab.keyboardShortcut!)
            .disabled(!model.canCloseFocusedTab)

            Divider()

            Button(Self.closeWindow.label) {
                _ = NSApplication.shared.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(Self.closeWindow.keyboardShortcut!)
        }
    }
}

struct ShuttleViewCommands: Commands {
    @Binding var isSidebarVisible: Bool
    @Binding var isCommandPalettePresented: Bool

    private static let sidebar = ShuttleActionDescriptor[.viewToggleSidebar]
    private static let palette = ShuttleActionDescriptor[.viewCommandPalette]

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarVisible.toggle()
                }
            }
            .keyboardShortcut(Self.sidebar.keyboardShortcut!)

            Button(Self.palette.label) {
                isCommandPalettePresented.toggle()
            }
            .keyboardShortcut(Self.palette.keyboardShortcut!)
        }
    }
}

struct ShuttleLayoutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    private static let layoutBuilder = ShuttleActionDescriptor[.toolsLayoutBuilder]

    var body: some Commands {
        CommandMenu("Layout") {
            Button(Self.layoutBuilder.label) {
                openWindow(id: ShuttleLayoutBuilderWindow.id)
            }
        }
    }
}

