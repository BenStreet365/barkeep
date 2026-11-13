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
///
/// It is meant to stay running: Quit (Command-Q, the Dock) closes its windows and leaves it in the
/// menu bar, doing its background duties. Only Quit in the menu bar icon's own menu (a right
/// click) stops it, until the next login. The daemon runs regardless.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
    /// Quit was chosen from the menu bar icon's menu: the one way to really quit.
    private var quitting = false

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
        // Any window closing (the About panel has no delegate) may leave none to show in the Dock for.
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
        if !launchedAsAgent { showMainWindow() }
    }

    // MARK: Quitting

    /// Whether Barkeep has anything to stay running for once its windows are closed.
    var staysInBackground: Bool { launchedAsAgent || showsInMenuBar }

    /// Quit closes the windows and nothing more, so the menu bar icon, the launch guard and the
    /// notifications carry on. Barkeep really quits when asked to from its menu bar menu, when the
    /// user logs out, restarts or shuts down, or when it would have nothing left to do.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || !staysInBackground || Self.isSessionEnding { return .terminateNow }
        closeWindows()
        return .terminateCancel
    }

    /// Whether the Quit being handled comes from the system ending the session, which must never
    /// be held up.
    static var isSessionEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.typeCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .contains { OSType($0) == reason }
    }

    func closeWindows() {
        popover?.performClose(nil)
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) { window.close() }
    }

    @objc func quitCompletely() {
        quitting = true
        NSApp.terminate(nil)
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
            item.button?.action = #selector(statusItemClicked(_:))
            // A click shows the popover; a right click (or Control-click) the menu.
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    @objc func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            togglePopover(sender)
        }
    }

    /// The menu bar icon's menu, attached only while it is open so a plain click still gets the popover.
    private func showStatusMenu() {
        popover?.performClose(nil)
        guard let item = statusItem else { return }
        item.menu = makeStatusMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let summary = menu.addItem(withTitle: model.summary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(.separator())
        let check = add("Check for Updates", #selector(checkNow), symbol: "arrow.clockwise", to: menu)
        check.isEnabled = model.userUpdatesAllowed && !model.checking
        if !model.userUpdatesAllowed { check.toolTip = "Turned off by your administrator" }
        add("Open Barkeep", #selector(openMainWindow), symbol: "macwindow", to: menu)
        add("Settings…", #selector(showSettings), symbol: "gear", to: menu)
        add("About Barkeep", #selector(showAbout), symbol: "info.circle", to: menu)
        menu.addItem(.separator())
        add("Quit Barkeep", #selector(quitCompletely), symbol: "power", to: menu)
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, symbol: String, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
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
            window.toolbarStyle = .unified
            let host = NSHostingController(rootView: MainView(model: model, selection: selection, delegate: self))
            // The view's title, subtitle, toolbar and search field become the window's.
            host.sceneBridgingOptions = [.title, .toolbars]
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.minSize = NSSize(width: 820, height: 420)
            window.isReleasedWhenClosed = false
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Barkeep Settings"
            let host = NSHostingController(rootView: SettingsView(model: model, delegate: self))
            // A grouped form scrolls, so it has no height of its own and would shrink the window
            // to its title bar: the window sets the size, the form only its minimum.
            host.sizingOptions = [.minSize]
            window.contentViewController = host
            window.setContentSize(NSSize(width: 600, height: 720))
            window.setFrameAutosaveName("BarkeepSettingsWindow")
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard (notification.object as? NSWindow)?.styleMask.contains(.titled) == true else { return }
        // Back to the menu bar only (no Dock icon) once no window is left.
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// About Barkeep: the icon, the version and what it is for.
    @objc func showAbout() {
        popover?.performClose(nil)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: "Keeps the apps on this Mac up to date, quietly.", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func openWebsite() { NSWorkspace.shared.open(Self.website) }
    @objc func checkNow() { model.checkNow() }
    @objc func openMainWindow() { showMainWindow() }

    func confirmAndUpdate(_ record: AppRecord) {
        if model.isRunning(record) {
            let alert = NSAlert()
            alert.messageText = "Update \(record.app.displayName) now?"
            alert.informativeText = "It will quit to install version \(record.available?.displayVersion ?? "") and open again when it's done. It will ask you to save anything unsaved."
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            agent?.userRequestedUpdate(record)
        }
        model.updateNow(record)
    }

    /// The standard menus: Barkeep, File, Edit, Window and Help.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func own(_ item: NSMenuItem) { item.target = self }

        let appMenu = submenu("Barkeep")
        own(appMenu.addItem(withTitle: "About Barkeep", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(.separator())
        own(appMenu.addItem(withTitle: "Check for Updates", action: #selector(checkNow), keyEquivalent: "r"))
        appMenu.addItem(.separator())
        own(appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Barkeep", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Closes the windows; Barkeep stays in the menu bar (see `applicationShouldTerminate`).
        appMenu.addItem(withTitle: "Quit Barkeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = submenu("File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = submenu("Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = submenu("Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        own(windowMenu.addItem(withTitle: "Barkeep", action: #selector(openMainWindow), keyEquivalent: "0"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpMenu = submenu("Help")
        own(helpMenu.addItem(withTitle: "Barkeep Website", action: #selector(openWebsite), keyEquivalent: ""))
        NSApp.helpMenu = helpMenu
        return main
    }

    /// Check for Updates is dimmed while a check runs or when the profile turns it off.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkNow) ? model.userUpdatesAllowed && !model.checking : true
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
