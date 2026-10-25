import Darwin
import Foundation

/// What one pass over the Mac's apps does.
public struct CycleOptions: Sendable {
    /// Ask every feed, whatever `CheckIntervalMinutes` says.
    public var checkFeeds = false
    /// Look for apps again rather than going over the ones already known.
    public var rescan = true
    /// Install what policy allows (root only). Off: report what would happen.
    public var install = true
    /// Apps (by path) a user asked to update now: they are asked to quit if they are open.
    public var requestedPaths: Set<String> = []
    /// Only these apps (by path or bundle ID). nil means all.
    public var only: Set<String>?

    public init() {}
}

/// Keeps the bar: finds apps, works out how each one updates, checks its feed, and installs what
/// the policy allows, saving what it found to `State.json` for Barkeep.app and `barkeep status`.
public final class Barkeeper {
    public let config: Configuration
    public let log: Log
    public var statePath = State.path
    public var stateMustBeRootOwned = true
    /// Where each account's view of the state goes (root only). nil: none are written.
    public var viewDirectory: String? = State.viewDirectory
    /// Whose home folder each app is in, for the views and leases. Read once per Barkeeper.
    public lazy var visibility: Visibility = .local()
    public var helperExecutable: String?
    public var effectiveUID: uid_t = geteuid()
    public var now: () -> Date = Date.init
    /// Called after each change to the state, so a long run shows progress.
    public var onSave: ((State) -> Void)?
    /// For tests.
    public var scanner: AppScanner
    public var finder: UpdateFinder
    public var updater: AppUpdater

    /// Barkeep.app gets this long to quit an app politely before `ForceQuitAtDeadline` applies.
    static let politeQuitWait: TimeInterval = 120
    /// A polite request to quit is repeated this often while the app stays open.
    static let quitRequestRepeat: TimeInterval = 30 * 60
    /// How long Barkeep.app has to reopen an app barkeep closed.
    public static let relaunchWindow: TimeInterval = 15 * 60

    public init(config: Configuration, log: Log, helperExecutable: String? = nil) {
        self.config = config
        self.log = log
        self.helperExecutable = helperExecutable
        scanner = AppScanner(config: config, log: log)
        scanner.helperExecutable = helperExecutable
        finder = UpdateFinder(config: config, log: log)
        updater = AppUpdater(config: config, log: log)
        updater.helperExecutable = helperExecutable
    }

    var isRoot: Bool { effectiveUID == 0 }

    public func loadState() -> State {
        State.load(from: statePath, requireRootOwnership: stateMustBeRootOwned) ?? State()
    }

    @discardableResult
    public func cycle(_ options: CycleOptions) -> State {
        var state = loadState()
        let original = state
        let start = now()
        state.notifyUsers = config.notifyUsers
        state.notifyBeforeDeadlineHours = config.notifyBeforeDeadlineHours
        state.allowUserInitiatedUpdates = config.allowUserInitiatedUpdates
        state.showInMenuBar = config.showInMenuBar
        state.openAtLogin = config.openAtLogin

        let previous = Dictionary(state.apps.map { ($0.app.path, $0) }, uniquingKeysWith: { a, _ in a })
        let apps: [InstalledApp]
        if options.rescan {
            apps = scanner.scan()
            state.lastScan = start
        } else {
            apps = scanner.refresh(state.apps.map(\.app))
        }
        func wanted(_ app: InstalledApp) -> Bool {
            options.only.map { $0.contains(app.path) || $0.contains(app.bundleIdentifier) } ?? true
        }

        var records: [AppRecord] = []
        // Records of apps outside `only` are kept as they were.
        var byPath = Dictionary(apps.map { ($0.path, previous[$0.path]) }, uniquingKeysWith: { a, _ in a })
        for app in apps {
            guard wanted(app) else {
                if let record = byPath[app.path] ?? nil { records.append(record) }
                continue
            }
            var record = carryOver(app, previous: previous[app.path])
            evaluate(&record, options: options, state: &state, records: records)
            records.append(record)
            byPath[app.path] = record
        }
        state.apps = records.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        if options.checkFeeds || state.lastCheck == nil || records.contains(where: { $0.lastChecked == start }) {
            state.lastCheck = start
        }
        // A pass that changed nothing leaves the file alone, so Barkeep.app has nothing to reload.
        if state != original { save(&state) }
        return state
    }

    /// A fresh record for `app`, keeping what is still true from the last run.
    func carryOver(_ app: InstalledApp, previous: AppRecord?) -> AppRecord {
        var record = AppRecord(app: app, status: .upToDate, message: "")
        guard let previous, previous.app.bundleIdentifier == app.bundleIdentifier else { return record }
        guard previous.app.displayVersion == app.displayVersion else {
            // Changed outside barkeep: the app's own updater, or someone replaced it. If barkeep
            // had asked it to quit for this update, the update is done, so it should reopen.
            if previous.quitRequestedAt != nil {
                record.lastUpdated = now()
                record.previousVersion = previous.app.displayVersion
                record.relaunchRequested = config.relaunchAfterUpdate
                record.updatedBySelf = true
            }
            return record
        }
        record.lastUpdated = previous.lastUpdated
        record.previousVersion = previous.previousVersion
        record.updatedBySelf = previous.updatedBySelf
        if let updated = previous.lastUpdated, now().timeIntervalSince(updated) < Self.relaunchWindow {
            record.relaunchRequested = previous.relaunchRequested
        }
        do {
            record.source = previous.source
            record.available = previous.available
            record.firstSeen = previous.firstSeen
            record.firstReleased = previous.firstReleased
            record.versionSeen = previous.versionSeen
            record.lastChecked = previous.lastChecked
            record.failures = previous.failures
            record.lastFailure = previous.lastFailure
            record.lastAttempt = previous.lastAttempt
            record.quitRequestedAt = previous.quitRequestedAt
        }
        return record
    }

    func evaluate(_ record: inout AppRecord, options: CycleOptions, state: inout State, records: [AppRecord]) {
        let app = record.app
        let id = app.bundleIdentifier
        let now = self.now()
        if config.isExcluded(id) {
            return set(&record, .excluded, "\(app.name) is excluded by the profile")
        }
        if app.isApple {
            return set(&record, .apple, "\(app.name) is updated by Software Update or the App Store")
        }
        let (resolved, problem) = SourceResolver.resolve(app, config: config)
        guard let source = resolved else {
            record.source = nil
            return set(&record, .noSource, problem ?? "No update source")
        }
        if record.source?.definition != source.definition {
            // What a different source said (a changed profile, or a --config run) doesn't count.
            record.available = nil
            record.lastChecked = nil
            record.versionSeen = nil
            record.failures = 0
            record.lastFailure = nil
        }
        record.source = source
        if source.definition.kind == .none {
            return set(&record, .excluded, "\(app.name) is not managed (AppSources sets it to None)")
        }
        if source.definition.kind == .vendor {
            return set(&record, .managedElsewhere, "\(app.name) is updated by \(source.definition.note ?? "its own updater")")
        }

        // The feed.
        let knownVersion = record.available?.version
        let interval = TimeInterval(config.checkIntervalMinutes) * 60
        let due = options.checkFeeds || options.requestedPaths.contains(app.path) || record.lastChecked.map { now.timeIntervalSince($0) >= interval } ?? true
        if due {
            do {
                record.available = try finder.latest(for: app, source: source.definition)
                record.lastChecked = now
            } catch {
                record.lastChecked = now
                return set(&record, .failed, "Cannot check for updates to \(app.name): \(error)")
            }
        }
        guard let available = record.available, available.isNewer(than: app) else {
            record.available = nil
            record.firstSeen = nil
            record.firstReleased = nil
            record.versionSeen = nil
            record.failures = 0
            record.lastFailure = nil
            record.quitRequestedAt = nil
            let recently = record.lastUpdated.map { now.timeIntervalSince($0) < 24 * 3600 } ?? false
            let how = record.updatedBySelf == true ? "\(app.name) updated itself to \(app.displayVersion)" : "Updated \(app.name) to \(app.displayVersion)"
            return set(&record, recently ? .updated : .upToDate, recently ? how : "\(app.name) \(app.displayVersion) is up to date")
        }
        if record.firstSeen == nil { record.firstSeen = now }
        if record.versionSeen == nil || knownVersion != available.version { record.versionSeen = now }
        if let released = available.releaseDate { record.firstReleased = min(record.firstReleased ?? released, released) }

        if source.definition.kind == .appStore {
            return set(&record, .managedElsewhere, "The App Store has \(app.name) \(available.displayVersion); it is updated by the App Store")
        }

        let pids = RunningProcesses.pids(inside: app.url)
        let requested = options.requestedPaths.contains(app.path)
        let decision = UpdatePolicy.decide(update: available, firstSeen: record.firstSeen!, firstReleased: record.firstReleased,
                                           versionSeen: record.versionSeen, timing: config.timing(for: id), now: now,
                                           isRunning: !pids.isEmpty, userRequested: requested, appName: app.name)
        record.installableAfter = decision.installableAfter
        record.deadline = decision.deadline
        record.closeAt = decision.closeAt
        set(&record, decision.status, decision.message)
        if decision.action == .wait, decision.status != .closingSoon { record.quitRequestedAt = nil }

        guard isRoot, options.install else {
            if decision.action != .wait { record.message = "\(app.name) \(available.displayVersion) can be installed (\(decision.action.rawValue))" }
            return
        }
        // After a failure, wait longer before each attempt, unless a user asked.
        if record.failures > 0, !requested, let last = record.lastAttempt,
           now.timeIntervalSince(last) < min(15 * 60 * pow(2, Double(record.failures - 1)), 24 * 3600) {
            record.status = .failed
            record.message = "Will try \(app.name) \(available.displayVersion) again later. Last time: \(record.lastFailure ?? "unknown problem")"
            return
        }

        switch decision.action {
        case .wait:
            return
        case .askToQuit:
            if record.quitRequestedAt.map({ now.timeIntervalSince($0) >= Self.quitRequestRepeat }) ?? true || requested {
                record.quitRequestedAt = now
                log.info("Asking \(app.name) to quit to install \(available.displayVersion)")
            }
            record.message = "\(app.name) is being asked to quit to install \(available.displayVersion)"
            return
        case .forceQuit:
            guard let asked = record.quitRequestedAt, now.timeIntervalSince(asked) >= Self.politeQuitWait else {
                if record.quitRequestedAt == nil { record.quitRequestedAt = now }
                return
            }
            log.warning("Terminating \(app.name) (pid \(pids.map(String.init).joined(separator: ", "))): its update deadline has passed")
            guard RunningProcesses.terminate(pids) else {
                return set(&record, .closingSoon, "Could not close \(app.name) for its update")
            }
            install(&record, available, source, state: &state, records: records)
        case .install:
            install(&record, available, source, state: &state, records: records)
        }
    }

    func install(_ record: inout AppRecord, _ available: AvailableUpdate, _ source: ResolvedSource, state: inout State, records: [AppRecord]) {
        let app = record.app
        let now = self.now()
        record.status = .installing
        record.message = "Installing \(app.name) \(available.displayVersion)"
        state.apps = mergeForProgress(records, record, into: state.apps)
        save(&state)

        record.lastAttempt = now
        let outcome: UpdateOutcome
        do {
            // The full signature check of the installed copy happens now, not on every scan.
            let deep = try scanner.inspect(app.url, deep: true)
            guard deep.bundleIdentifier == app.bundleIdentifier, deep.displayVersion == app.displayVersion else {
                return set(&record, .upToDate, "\(app.name) changed since it was scanned; checking again later")
            }
            outcome = updater.update(deep, to: available, source: source)
        } catch {
            outcome = UpdateOutcome(result: .failed, exitCode: (error as? BarkeepError)?.status.rawValue ?? 1, message: "\(error)")
        }
        switch outcome.result {
        case .updated:
            log.info(outcome.message)
            let closedByUs = record.quitRequestedAt != nil
            if let fresh = try? scanner.inspect(app.url) { record.app = fresh }
            record.previousVersion = app.displayVersion
            record.lastUpdated = self.now()
            record.relaunchRequested = closedByUs && config.relaunchAfterUpdate
            record.updatedBySelf = nil
            record.available = nil
            record.firstSeen = nil
            record.firstReleased = nil
            record.versionSeen = nil
            record.failures = 0
            record.quitRequestedAt = nil
            record.deadline = nil
            record.closeAt = nil
            set(&record, .updated, outcome.message)
        case .deferredRunning:
            log.info(outcome.message)
            set(&record, .waitingForQuit, outcome.message)
        case .failed:
            log.error("Updating \(app.name) failed: \(outcome.message)")
            record.failures += 1
            record.lastFailure = outcome.message
            set(&record, .failed, outcome.message)
        }
    }

    /// The state to show while one app installs: what this run has so far, with `record`, and the
    /// rest as they were.
    func mergeForProgress(_ done: [AppRecord], _ record: AppRecord, into old: [AppRecord]) -> [AppRecord] {
        var byPath = Dictionary(old.map { ($0.app.path, $0) }, uniquingKeysWith: { a, _ in a })
        for r in done { byPath[r.app.path] = r }
        byPath[record.app.path] = record
        return byPath.values.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    func set(_ record: inout AppRecord, _ status: AppStatus, _ message: String) {
        record.status = status
        record.message = message
    }

    func save(_ state: inout State) {
        guard isRoot || !stateMustBeRootOwned else { return }
        let views = isRoot ? viewDirectory : nil
        do {
            // The views first: Barkeep.app reloads when State.json is replaced.
            if let views {
                var next = state
                next.generation += 1
                do { try next.saveViews(visibility, to: views) } catch { log.warning("Cannot save every user's view of the state: \(error)") }
            }
            try state.save(to: statePath, group: isRoot ? TargetUser.adminGroupID : nil)
            onSave?(state)
        } catch {
            log.warning("Cannot save \(statePath): \(error)")
        }
    }
}
