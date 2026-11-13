import Foundation

/// What to do about an available update right now.
public enum PolicyAction: String, Codable, Sendable {
    /// Nothing yet.
    case wait
    /// The app is closed: install now.
    case install
    /// Ask the app to quit (as if the user chose Quit, so it can save its work), then install.
    case askToQuit
    /// The deadline and grace period have passed and `ForceQuitAtDeadline` is on: terminate it.
    case forceQuit
}

public struct PolicyDecision: Equatable, Sendable {
    public var status: AppStatus
    public var action: PolicyAction
    public var message: String
    public var installableAfter: Date
    public var deadline: Date?
    public var closeAt: Date?
}

/// Chooses which of the releases barkeep has seen to work on. An app that releases more often
/// than the cooling-off period lasts always has a newest release that is too fresh, so waiting for
/// "the newest" would wait for ever. Instead barkeep installs the newest release that *has* cooled
/// off, and moves on to the next when that one has.
public enum ReleaseSelection {
    /// The newest release whose cooling-off period is over, or if none is, the one that will be
    /// ready first. Releases barkeep has set aside are passed over. `releases` is oldest first.
    public static func select(from releases: [KnownRelease], coolingOffHours: Int, now: Date) -> KnownRelease? {
        let usable = releases.filter { $0.setAside == nil }
        if let ready = usable.last(where: { $0.installableAfter(coolingOffHours: coolingOffHours, now: now) <= now }) { return ready }
        // `min` keeps the first of equals; reversed, that is the newest.
        return usable.reversed().min {
            $0.installableAfter(coolingOffHours: coolingOffHours, now: now) < $1.installableAfter(coolingOffHours: coolingOffHours, now: now)
        }
    }

    /// Releases worth keeping: every one still cooling off, and the newest few that have (the
    /// one to install, and others to fall back on if its download has gone). Thinned from the
    /// middle if there are still too many, so the oldest and newest always stay.
    public static func prune(_ releases: [KnownRelease], coolingOffHours: Int, now: Date, keepReady: Int = 3, limit: Int = 60) -> [KnownRelease] {
        let ready = releases.filter { $0.installableAfter(coolingOffHours: coolingOffHours, now: now) <= now }
        var cooling = releases.filter { $0.installableAfter(coolingOffHours: coolingOffHours, now: now) > now }
        while cooling.count > max(limit, 2) {
            cooling = cooling.enumerated().filter { $0.offset == 0 || $0.offset == cooling.count - 1 || $0.offset % 2 == 0 }.map(\.element)
        }
        return ready.suffix(keepReady) + cooling
    }
}

/// Decides when an update is installed. Updates are only ever installed while the app is closed,
/// once they have been out for the cooling-off period. If the app stays open past the deadline,
/// the user is told it will close after the grace period, and then it is asked to quit.
public enum UpdatePolicy {
    /// `firstSeen` is when the app was first found out of date, and `firstReleased` the earliest
    /// release date among the updates seen since; the deadline counts from one of them. The
    /// cooling-off period applies to `update` itself, from its release date or, if the feed has
    /// none, from `versionSeen`, when barkeep first saw that version.
    public static func decide(update: AvailableUpdate, firstSeen: Date, firstReleased: Date? = nil, versionSeen: Date? = nil,
                              timing: UpdateTiming, now: Date, isRunning: Bool, userRequested: Bool, appName: String) -> PolicyDecision {
        let version = update.displayVersion
        // A version cannot have been released after barkeep first saw it, so a release date in the
        // future counts from then: a wrong date cannot hold an update back for ever.
        let seen = min(versionSeen ?? firstSeen, now)
        let released = min(update.releaseDate ?? seen, seen)
        let installableAfter = released.addingTimeInterval(TimeInterval(timing.coolingOffHours) * 3600)
        var deadline: Date?
        var closeAt: Date?
        if timing.enforceDeadline {
            let start = timing.deadlineBasis == .released ? min(firstReleased ?? released, released, firstSeen) : firstSeen
            deadline = max(start.addingTimeInterval(TimeInterval(timing.deadlineDays) * 86400), installableAfter)
            closeAt = deadline!.addingTimeInterval(TimeInterval(timing.graceMinutes) * 60)
        }
        var decision = PolicyDecision(status: .waitingForQuit, action: .wait, message: "", installableAfter: installableAfter,
                                      deadline: deadline, closeAt: closeAt)

        if now < installableAfter {
            decision.status = .coolingOff
            decision.message = "\(appName) \(version) will be installed after \(format(installableAfter)) (cooling-off period)"
            return decision
        }
        if !isRunning {
            decision.action = .install
            decision.status = .installing
            decision.message = "Installing \(appName) \(version)"
            return decision
        }
        if userRequested {
            decision.action = .askToQuit
            decision.status = .closingSoon
            decision.message = "\(appName) will close to install \(version)"
            return decision
        }
        if let deadline, let closeAt, now >= deadline {
            decision.status = .closingSoon
            if now >= closeAt {
                decision.action = timing.forceQuit ? .forceQuit : .askToQuit
                decision.message = "\(appName) is closing to install \(version)"
            } else {
                decision.message = "\(appName) will close at \(format(closeAt)) to install \(version)"
            }
            return decision
        }
        decision.message = deadline.map { "\(appName) \(version) will be installed when it quits, or by \(format($0))" }
            ?? "\(appName) \(version) will be installed when it quits"
        return decision
    }

    static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
