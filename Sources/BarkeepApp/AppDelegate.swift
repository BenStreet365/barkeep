import AppKit
import BarkeepCore
import SwiftUI

@main
@MainActor
enum BarkeepApp {
    /// Passed by the LaunchAgent at login: start in the background, in the menu bar only.
    static let agentArgument = "--agent"

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Barkeep.app lives in the menu bar of every user's session (started by the LaunchAgent) and
/// opens a full window on demand. It never installs anything itself: the daemon does, and the app
/// shows what it is doing and passes on the user's requests.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let website = URL(string: "https://barkeep.street365.uk")!
    static let menuBarKey = "ShowInMenuBar"
    static let openAtLoginKey = "OpenAtLogin"

    let model = BarModel()
    var agent: Agent?
    let selection = Selection()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    var launchedAsAgent: Bool { CommandLine.arguments.contains(BarkeepApp.agentArgument) }

    /// A profile's `ShowInMenuBar` wins; otherwise the user's choice, on by default.
    var showsInMenuBar: Bool {
        model.configuration.showInMenuBar ?? (UserDefaults.standard.object(forKey: Self.menuBarKey) as? Bool ?? true)
    }

    /// A profile's `OpenAtLogin` wins; otherwise the user's choice, on by default.
    var opensAtLogin: Bool {
        model.configuration.openAtLogin ?? (UserDefaults.standard.object(forKey: Self.openAtLoginKey) as? Bool ?? true)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started by the LaunchAgent but not wanted at login: a successful exit, so launchd
        // leaves it until the next login.
        if launchedAsAgent && !opensAtLogin { exit(0) }
        let agent = Agent(model: model)
        self.agent = agent
        model.onReload = { [weak self] state in
            self?.agent?.stateChanged(state)
            self?.updateStatusItem()
        }
        if let state = model.state { agent.stateChanged(state) }
        applyMenuBarSetting()
        if !launchedAsAgent { showMainWindow() }
    }

    /// Opening Barkeep from Finder or the Dock while the agent is running shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The agent keeps running in the background for the launch guard and notifications.
        !launchedAsAgent && !showsInMenuBar
    }

    // MARK: Menu bar

    func applyMenuBarSetting() {
        if showsInMenuBar {
            guard statusItem == nil else { return updateStatusItem() }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
            updateStatusItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            popover?.close()
        }
    }

    func setMenuBar(_ enabled: Bool) {
        guard model.configuration.showInMenuBar == nil else { return }
        UserDefaults.standard.set(enabled, forKey: Self.menuBarKey)
        applyMenuBarSetting()
    }

    /// Takes effect at the next login: the LaunchAgent still starts Barkeep, which then exits.
    func setOpenAtLogin(_ enabled: Bool) {
        guard model.configuration.openAtLogin == nil else { return }
        UserDefaults.standard.set(enabled, forKey: Self.openAtLoginKey)
    }

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(named: "barkeepTemplate") ?? NSImage(systemSymbolName: "mug", accessibilityDescription: "Barkeep")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.toolTip = "Barkeep: \(model.summary)"
        // The logo stays a template, so it follows the menu bar; only the badge has a colour.
        // A small badge only when the user may need to act.
        let badge = badgeView(on: button)
        if model.attention.contains(where: { $0.status == .closingSoon }) {
            badge.color = .systemOrange
        } else if model.waiting.count > 0 {
            badge.color = .controlAccentColor
        } else {
            badge.color = nil
        }
    }

    private func badgeView(on button: NSStatusBarButton) -> BadgeView {
        if let badge = button.subviews.lazy.compactMap({ $0 as? BadgeView }).first { return badge }
        let badge = BadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        // The top right corner of the 18-point logo, centred in the button.
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 6),
            badge.heightAnchor.constraint(equalToConstant: 6),
            badge.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 5),
            badge.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -5),
        ])
        return badge
    }

    @objc func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = self.popover ?? {
            let p = NSPopover()
            p.behavior = .transient
            let host = NSHostingController(rootView: MenuView(model: model, delegate: self))
            // Follow the SwiftUI content's size from then on.
            host.sizingOptions = .preferredContentSize
            p.contentViewController = host
            self.popover = p
            return p
        }()
        model.reload()
        guard let button = statusItem?.button else { return }
        // Size it before showing: a popover that shrinks after appearing keeps its bottom edge,
        // so it would hang away from the menu bar.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Windows

    func showMainWindow(selecting path: String? = nil) {
        popover?.performClose(nil)
        if let path { selection.path = path }
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Barkeep"
            window.contentViewController = NSHostingController(rootView: MainView(model: model, selection: selection, delegate: self))
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.minSize = NSSize(width: 820, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("BarkeepMainWindow")
            window.center()
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Barkeep Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model, delegate: self))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to the menu bar only once no window is left.
        DispatchQueue.main.async {
            let visible = [self.mainWindow, self.settingsWindow].contains { $0?.isVisible == true }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    @objc func openWebsite() { NSWorkspace.shared.open(Self.website) }
    @objc func checkNow() { model.checkNow() }
    @objc func openMainWindow() { showMainWindow() }

    func confirmAndUpdate(_ record: AppRecord) {
        if model.isRunning(record) {
            let alert = NSAlert()
            alert.messageText = "Update \(record.app.name.replacingOccurrences(of: ".app", with: "")) now?"
            alert.informativeText = "It will quit to install version \(record.available?.displayVersion ?? "") and open again when it's done. It will ask you to save anything unsaved."
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            agent?.userRequestedUpdate(record)
        }
        model.updateNow(record)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Barkeep", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Barkeep", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Barkeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Check for Updates", action: #selector(checkNow), keyEquivalent: "r")
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: "Barkeep Website", action: #selector(openWebsite), keyEquivalent: "")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        return main
    }
}

/// The coloured dot on the menu bar logo. Hidden when there is no colour.
final class BadgeView: NSView {
    var color: NSColor? {
        didSet { isHidden = color == nil; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    // Clicks go to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The app selected in the main window, shared so a notification can select one.
@MainActor @Observable
final class Selection {
    var path: String?
}
