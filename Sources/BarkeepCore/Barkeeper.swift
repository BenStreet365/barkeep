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
    /// Called as each app is dealt with, so the daemon can tell a long pass from a stuck one.
    public var onProgress: (() -> Void)?
    /// Seal the state and only act on a sealed one (see `StateSeal`). On for root.
    public var sealsState = geteuid() == 0
    /// The Mac's Gatekeeper setting, if the caller looked, saved for Barkeep.app to show.
    public var gatekeeperMode: Gatekeeper.Mode?
    /// The saved state failed its seal and was not used, so the next one is saved whatever it holds.
    private var stateWasRejected = false
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
    /// Feeds are asked this many at a time, so one slow vendor doesn't hold up the rest.
    static let feedThreads = 6
    /// A feed that could not be read is asked again after this long, doubling each time, up to
    /// `CheckIntervalMinutes`.
    static let feedRetryBase: TimeInterval = 15 * 60
    /// An older release that fails this often is set aside for a newer one.
    static let releaseFailureLimit = 3
    /// Failures that say an older release's download is no longer that release: set aside at once.
    static let conclusiveFailures: Set<Int32> = [ExitStatus.checksumMismatch.rawValue, ExitStatus.archiveError.rawValue,
                                                 ExitStatus.notNewer.rawValue]

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

    var seal: StateSeal? {
        guard sealsState else { return nil }
        var seal = StateSeal(directory: (statePath as NSString).deletingLastPathComponent)
        seal.requireRootOwnership = stateMustBeRootOwned
        return seal
    }

    /// The saved state. With a seal, one that fails it is not used: barkeep starts again, which
    /// can only make updates wait longer.
    public func loadState() -> State {
        guard let seal else { return State.load(from: statePath, requireRootOwnership: stateMustBeRootOwned) ?? State() }
        let (state, problem) = State.loadSealed(from: statePath, seal: seal, requireRootOwnership: stateMustBeRootOwned)
        if let problem {
            log.warning("Not using \(statePath): \(problem). Starting again; updates already found count from now")
            stateWasRejected = true
        }
        return state ?? State()
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
        if let gatekeeperMode { state.gatekeeper = gatekeeperMode }

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
        let carried = Dictionary(apps.filter(wanted).map { ($0.path, carryOver($0, previous: previous[$0.path])) }, uniquingKeysWith: { a, _ in a })
        // Every feed that is due is asked first, several at a time. Installing stays one by one.
        let feeds = fetchFeeds(for: Array(carried.values), options: options, now: start)
        for app in apps {
            guard wanted(app), var record = carried[app.path] else {
                if let record = byPath[app.path] ?? nil { records.append(record) }
                continue
            }
            evaluate(&record, options: options, state: &state, records: records, feeds: feeds, checkedAt: start)
            records.append(record)
            byPath[app.path] = record
            onProgress?()
        }
        state.apps = records.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        if options.checkFeeds || state.lastCheck == nil || records.contains(where: { $0.lastChecked == start }) {
            state.lastCheck = start
        }
        // A pass that changed nothing leaves the file alone, so Barkeep.app has nothing to reload.
        if state != original || stateWasRejected {
            save(&state)
            stateWasRejected = false
        }
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
            // What the feed has offered is still true; releases it has caught up with are dropped later.
            record.source = previous.source
            record.available = previous.available
            record.releases = previous.releases
            record.lastChecked = previous.lastChecked
            record.feedFailures = previous.feedFailures
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
            record.releases = previous.releases
            record.selected = previous.selected
            record.feedFailures = previous.feedFailures
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

    // MARK: Feeds

    /// Whether to ask `record`'s feed on this pass.
    func feedIsDue(_ record: AppRecord, source: ResolvedSource, options: CycleOptions, now: Date) -> Bool {
        if options.checkFeeds || options.requestedPaths.contains(record.app.path) { return true }
        guard record.source?.definition == source.definition, let last = record.lastChecked else { return true }
        let interval = TimeInterval(config.checkIntervalMinutes) * 60
        let failures = record.feedFailures ?? 0
        let wait = failures > 0 ? min(Self.feedRetryBase * pow(2, Double(min(failures, 16) - 1)), interval) : interval
        return now.timeIntervalSince(last) >= wait
    }

    /// Asks every feed that is due, a few at a time, and returns what each offered (by app path).
    /// Nothing here is acted on: `evaluate` does that, one app after another.
    func fetchFeeds(for records: [AppRecord], options: CycleOptions, now: Date) -> [String: Result<[AvailableUpdate], Error>] {
        var requests: [(app: InstalledApp, source: AppSourceDefinition)] = []
        for record in records {
            let app = record.app
            guard !config.isExcluded(app.bundleIdentifier), !app.isApple,
                  let source = SourceResolver.resolve(app, config: config).0,
                  source.definition.kind != .none, source.definition.kind != .vendor,
                  feedIsDue(record, source: source, options: options, now: now) else { continue }
            requests.append((app, source.definition))
        }
        guard !requests.isEmpty else { return [:] }
        let pending = requests
        let finder = self.finder
        let results = Locked<[String: Result<[AvailableUpdate], Error>]>([:])
        let next = Locked(0)
        let done = DispatchGroup()
        // Threads of their own, as in `Command`: each blocks on the network.
        for _ in 0..<min(Self.feedThreads, pending.count) {
            done.enter()
            Thread {
                while true {
                    let index = next.withValue { value -> Int in
                        defer { value += 1 }
                        return value
                    }
                    guard index < pending.count else { break }
                    let request = pending[index]
                    let result = Result { try finder.releases(for: request.app, source: request.source) }
                    results.withValue { $0[request.app.path] = result }
                }
                done.leave()
            }.start()
        }
        done.wait()
        return results.withValue { $0 }
    }

    /// Adds what the feed offers to the releases already known for the app, keeping when each was
    /// first seen.
    func remember(_ offered: [AvailableUpdate], in record: inout AppRecord, at now: Date) {
        var known = record.releases ?? []
        for update in offered where update.isNewer(than: record.app) {
            guard let index = known.firstIndex(where: { $0.update.isSameRelease(as: update) }) else {
                known.append(KnownRelease(update: update, seen: now))
                continue
            }
            let old = known[index].update
            // A feed that now points somewhere else for this release deserves another try.
            if old.downloadURL != update.downloadURL || old.sha256 != update.sha256 || old.sha512 != update.sha512
                || old.edSignature != update.edSignature {
                known[index].setAside = nil
                known[index].failures = 0
                known[index].lastFailure = nil
                known[index].lastAttempt = nil
            }
            known[index].update = update
        }
        record.releases = known
    }

    // MARK: One app

    func evaluate(_ record: inout AppRecord, options: CycleOptions, state: inout State, records: [AppRecord],
                  feeds: [String: Result<[AvailableUpdate], Error>] = [:], checkedAt: Date? = nil) {
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
        let due = feedIsDue(record, source: source, options: options, now: checkedAt ?? now)
        if record.source?.definition != source.definition {
            // What a different source said (a changed profile, or a --config run) doesn't count.
            record.available = nil
            record.releases = nil
            record.selected = nil
            record.lastChecked = nil
            record.feedFailures = nil
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
        if due {
            let checked = checkedAt ?? now
            let result = feeds[app.path] ?? Result { try finder.releases(for: app, source: source.definition) }
            record.lastChecked = checked
            switch result {
            case .success(let offered):
                record.feedFailures = nil
                record.available = offered.last
                remember(offered, in: &record, at: checked)
            case .failure(let error):
                record.feedFailures = (record.feedFailures ?? 0) + 1
                // An update already known doesn't need the feed again to be installed.
                guard record.available?.isNewer(than: app) == true else {
                    return set(&record, .failed, "Cannot check for updates to \(app.name): \(error)")
                }
                log.debug("Cannot check for updates to \(app.name) (\(error)); carrying on with the release already known")
            }
        }
        guard let available = record.available, available.isNewer(than: app) else {
            record.available = nil
            record.releases = nil
            record.selected = nil
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

        // The releases this copy is missing, oldest first. One the feed no longer offers and has
        // gone back past was withdrawn by its vendor, which is what cooling off is there to catch.
        let timing = config.timing(for: id)
        var releases = (record.releases ?? []).filter {
            $0.update.isNewer(than: app) && $0.update.compare(toShort: available.version, build: available.build) != .orderedDescending
        }
        if !releases.contains(where: { $0.update.isSameRelease(as: available) }) {
            releases.append(KnownRelease(update: available, seen: record.versionSeen ?? record.firstSeen ?? now))
        }
        releases.sort { $0.update.compare(toShort: $1.update.version, build: $1.update.build) == .orderedAscending }
        releases = ReleaseSelection.prune(releases, coolingOffHours: timing.coolingOffHours, now: now)
        // The newest is always worth trying: there is nothing newer to fall back on.
        releases[releases.count - 1].setAside = nil
        record.releases = releases
        // The clocks never move later while the app stays out of date, whatever is pruned.
        record.firstSeen = ([record.firstSeen].compactMap { $0 } + releases.map(\.seen)).min()
        record.firstReleased = ([record.firstReleased].compactMap { $0 } + releases.compactMap(\.update.releaseDate)).min()

        if source.definition.kind == .appStore {
            return set(&record, .managedElsewhere, "The App Store has \(app.name) \(available.displayVersion); it is updated by the App Store")
        }

        // Which release: the newest that has cooled off, however many have come out since.
        guard let chosen = ReleaseSelection.select(from: releases, coolingOffHours: timing.coolingOffHours, now: now),
              let firstSeen = record.firstSeen else { return }
        let pinned = !chosen.update.isSameRelease(as: available)
        record.selected = chosen.update
        record.versionSeen = chosen.seen
        record.failures = chosen.failures
        record.lastFailure = chosen.lastFailure
        record.lastAttempt = chosen.lastAttempt

        let pids = RunningProcesses.pids(inside: app.url)
        let requested = options.requestedPaths.contains(app.path)
        let decision = UpdatePolicy.decide(update: chosen.update, firstSeen: firstSeen, firstReleased: record.firstReleased,
                                           versionSeen: chosen.seen, timing: timing, now: now,
                                           isRunning: !pids.isEmpty, userRequested: requested, appName: app.name)
        record.installableAfter = decision.installableAfter
        record.deadline = decision.deadline
        record.closeAt = decision.closeAt
        set(&record, decision.status, decision.message)
        if pinned, decision.status != .coolingOff {
            record.message += "; \(available.displayVersion) is newer and still in its cooling-off period"
        }
        if decision.action == .wait, decision.status != .closingSoon { record.quitRequestedAt = nil }

        guard isRoot, options.install else {
            if decision.action != .wait { record.message = "\(app.name) \(chosen.update.displayVersion) can be installed (\(decision.action.rawValue))" }
            return
        }
        // After a failure, wait longer before each attempt, unless a user asked.
        if record.failures > 0, !requested, let last = record.lastAttempt,
           now.timeIntervalSince(last) < min(15 * 60 * pow(2, Double(min(record.failures, 16) - 1)), 24 * 3600) {
            record.status = .failed
            record.message = "Will try \(app.name) \(chosen.update.displayVersion) again later. Last time: \(record.lastFailure ?? "unknown problem")"
            return
        }

        switch decision.action {
        case .wait:
            return
        case .askToQuit:
            if record.quitRequestedAt.map({ now.timeIntervalSince($0) >= Self.quitRequestRepeat }) ?? true || requested {
                record.quitRequestedAt = now
                log.info("Asking \(app.name) to quit to install \(chosen.update.displayVersion)")
            }
            record.message = "\(app.name) is being asked to quit to install \(chosen.update.displayVersion)"
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
            install(&record, chosen.update, source, pinned: pinned, state: &state, records: records)
        case .install:
            install(&record, chosen.update, source, pinned: pinned, state: &state, records: records)
        }
    }

    func install(_ record: inout AppRecord, _ update: AvailableUpdate, _ source: ResolvedSource, pinned: Bool = false,
                 state: inout State, records: [AppRecord]) {
        let app = record.app
        let now = self.now()
        record.status = .installing
        record.message = "Installing \(app.name) \(update.displayVersion)"
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
            outcome = updater.update(deep, to: update, source: source, pinned: pinned)
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
            // Releases newer than the one just installed are still to come; their clocks start afresh.
            let installed = record.app
            let remaining = (record.releases ?? []).filter {
                $0.update.compare(toShort: update.version, build: update.build) == .orderedDescending && $0.update.isNewer(than: installed)
            }
            record.releases = remaining.isEmpty ? nil : remaining
            if record.available?.isNewer(than: installed) != true || remaining.isEmpty { record.available = nil }
            record.selected = nil
            record.firstSeen = nil
            record.firstReleased = nil
            record.versionSeen = nil
            record.failures = 0
            record.lastFailure = nil
            record.lastAttempt = nil
            record.quitRequestedAt = nil
            record.installableAfter = nil
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
            guard var releases = record.releases, let index = releases.firstIndex(where: { $0.update.isSameRelease(as: update) }) else { return }
            releases[index].failures = record.failures
            releases[index].lastFailure = outcome.message
            releases[index].lastAttempt = now
            // An older release whose download has gone, or is no longer that release, is passed
            // over: the next one is installed when it has cooled off.
            if pinned, Self.conclusiveFailures.contains(outcome.exitCode) || record.failures >= Self.releaseFailureLimit {
                releases[index].setAside = outcome.message
                log.warning("Setting aside \(app.name) \(update.displayVersion); a newer release will be installed when it has cooled off")
            }
            record.releases = releases
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
            try state.save(to: statePath, group: isRoot ? TargetUser.adminGroupID : nil, seal: seal)
            onSave?(state)
        } catch {
            log.warning("Cannot save \(statePath): \(error)")
        }
    }
}

/// A value shared between threads, behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}
