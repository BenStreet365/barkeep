import AppKit
import BarkeepCore
import Foundation
@preconcurrency import UserNotifications
import os

/// What Barkeep.app does in each user's session for the daemon, which runs as root and cannot:
///
/// - **Launch guard.** An app opened while barkeep is swapping in its update (a live
///   `UpdateLease`) is closed straight away and opened again when the update is done.
/// - **Quitting politely.** When the daemon asks for an app to quit (its deadline has passed, or
///   the user chose Update Now), it is asked to quit like the user chose Quit, so it can save.
/// - **Reopening.** An app barkeep closed is opened again once it is updated.
/// - **Notifications**, only when the user needs to know: an app will close for its update.
@MainActor
final class Agent: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: Configuration.domain, category: "agent")
    private let model: BarModel
    /// Apps closed by the launch guard, to reopen when their lease ends.
    private var guarded: [String: Date] = [:]
    /// Apps this session quit for an update, to reopen afterwards (path → when).
    private var quitByUs: [String: Date] = [:]
    /// The quit requests already acted on (path → request date).
    private var handledQuits: [String: Date] = [:]
    private var leaseTimer: Timer?
    private let defaults = UserDefaults.standard
    static let notifiedKey = "NotifiedUpdates"
    static let updateAction = "UPDATE_NOW"
    static let category = "BARKEEP_UPDATE"

    init(model: BarModel) {
        self.model = model
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched(_:)),
                                                          name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let update = UNNotificationAction(identifier: Self.updateAction, title: "Update Now")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [update], intentIdentifiers: [])])
    }

    // MARK: Launch guard

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let path = app.bundleURL?.standardizedFileURL.path else { return }
        guard let lease = UpdateLease.live().first(where: { $0.path == path }) else { return }
        logger.info("\(lease.name, privacy: .public) was opened while it is being updated; closing it until the update is done")
        app.forceTerminate()
        guarded[path] = Date()
        post(id: "guard-\(path)", title: "\(lease.name) is being updated",
             body: "It will open again in a moment, as soon as the update is finished.", category: nil)
        startLeaseTimer()
    }

    private func startLeaseTimer() {
        guard leaseTimer == nil else { return }
        leaseTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.agent?.checkGuarded() }
        }
    }

    fileprivate func checkGuarded() {
        let live = Set(UpdateLease.live().map(\.path))
        for (path, since) in guarded where !live.contains(path) || Date().timeIntervalSince(since) > UpdateLease.maximumDuration {
            guarded[path] = nil
            open(path)
        }
        if guarded.isEmpty {
            leaseTimer?.invalidate()
            leaseTimer = nil
        }
    }

    // MARK: State

    func stateChanged(_ state: State) {
        for record in state.apps {
            handleQuitRequest(record)
            handleRelaunch(record)
            if state.notifyUsers { notifyIfNeeded(record, state: state) }
        }
    }

    private func running(_ record: AppRecord) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == record.app.path }
    }

    private func handleQuitRequest(_ record: AppRecord) {
        guard let requested = record.quitRequestedAt, record.status == .closingSoon,
              Date().timeIntervalSince(requested) < 600, handledQuits[record.app.path] != requested else { return }
        handledQuits[record.app.path] = requested
        let apps = running(record)
        guard !apps.isEmpty else { return }
        logger.info("Asking \(record.app.name, privacy: .public) to quit for its update")
        for app in apps { app.terminate() }
        quitByUs[record.app.path] = Date()
    }

    private func handleRelaunch(_ record: AppRecord) {
        guard record.relaunchRequested == true, record.status == .updated || record.status == .upToDate,
              let asked = quitByUs[record.app.path], let updated = record.lastUpdated, updated > asked else { return }
        quitByUs[record.app.path] = nil
        guard running(record).isEmpty else { return }
        logger.info("Reopening \(record.app.name, privacy: .public) after its update")
        open(record.app.path)
    }

    private func open(_ path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, _ in }
    }

    // MARK: Notifications

    /// Tells the user once per version: when an open app's deadline is getting close, and when
    /// it has passed and the app will close.
    private func notifyIfNeeded(_ record: AppRecord, state: State) {
        guard let available = record.available, !running(record).isEmpty else { return }
        let now = Date()
        let version = available.displayVersion
        let name = record.app.name.replacingOccurrences(of: ".app", with: "")
        if record.status == .closingSoon, let closeAt = record.closeAt, closeAt > now {
            notifyOnce("\(record.app.path)|\(version)|closing", title: "\(name) will close at \(closeAt.formatted(date: .omitted, time: .shortened))",
                       body: "Save your work. \(name) will close to install version \(version), then open again.", path: record.app.path)
        } else if record.status == .waitingForQuit, let deadline = record.deadline,
                  deadline.timeIntervalSince(now) <= TimeInterval(state.notifyBeforeDeadlineHours) * 3600 {
            notifyOnce("\(record.app.path)|\(version)|deadline", title: "An update for \(name) is waiting",
                       body: "Quit \(name) when you can and it will update. Otherwise it will be closed for the update after \(deadline.formatted(date: .abbreviated, time: .shortened)).",
                       path: record.app.path)
        }
    }

    private func notifyOnce(_ key: String, title: String, body: String, path: String) {
        var sent = defaults.stringArray(forKey: Self.notifiedKey) ?? []
        guard !sent.contains(key) else { return }
        sent.append(key)
        defaults.set(Array(sent.suffix(200)), forKey: Self.notifiedKey)
        post(id: key, title: title, body: body, category: model.userUpdatesAllowed ? Self.category : nil, path: path)
    }

    private func post(id: String, title: String, body: String, category: String?, path: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category }
            if let path { content.userInfo = ["path": path] }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let path, let record = model.apps.first(where: { $0.app.path == path }) else {
                (NSApp.delegate as? AppDelegate)?.showMainWindow()
                return
            }
            if action == Self.updateAction {
                quitByUs[path] = Date()
                model.updateNow(record)
            } else {
                (NSApp.delegate as? AppDelegate)?.showMainWindow(selecting: path)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// The user chose Update Now for an open app: it will be quit, then reopened.
    func userRequestedUpdate(_ record: AppRecord) {
        quitByUs[record.app.path] = Date()
    }
}
