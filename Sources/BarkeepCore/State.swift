import Darwin
import Foundation

public enum AppStatus: String, Codable, Sendable, CaseIterable {
    /// Nothing newer is available.
    case upToDate
    /// Excluded by the profile.
    case excluded
    /// Apple's own app, updated by Software Update.
    case apple
    /// Barkeep doesn't know where its updates come from.
    case noSource
    /// The App Store or the vendor's own updater looks after it; a newer version may exist.
    case managedElsewhere
    /// A newer version exists but has not been out for the cooling-off period yet.
    case coolingOff
    /// Ready, waiting for the app to quit (or its deadline).
    case waitingForQuit
    /// The deadline has passed: the user has been told the app will close at `closeAt`.
    case closingSoon
    case installing
    case updated
    /// The feed could not be read, or the update failed a check. `message` says why.
    case failed
}

/// Everything barkeep knows about one installed app. Written by the daemon, read by Barkeep.app.
public struct AppRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { app.path }
    public var app: InstalledApp
    public var source: ResolvedSource?
    public var status: AppStatus
    public var message: String
    public var available: AvailableUpdate?
    /// When barkeep first found this app out of date. Newer releases found while an update is
    /// waiting do not restart the clock, so frequent releases cannot put a deadline off for ever.
    public var firstSeen: Date?
    /// When barkeep first saw `available`'s version.
    public var versionSeen: Date?
    /// The earliest release date of the updates seen since `firstSeen`, for `DeadlineBasis` Released.
    public var firstReleased: Date?
    /// When the cooling-off period ends.
    public var installableAfter: Date?
    public var deadline: Date?
    /// When barkeep will close the app to update it, once the deadline has passed.
    public var closeAt: Date?
    public var lastChecked: Date?
    public var lastUpdated: Date?
    public var previousVersion: String?
    /// Barkeep closed the app to update it, so Barkeep.app should reopen it.
    public var relaunchRequested: Bool?
    /// The last update was installed by the app's own updater, not barkeep.
    public var updatedBySelf: Bool?
    /// When barkeep asked Barkeep.app to quit the app (politely, as if the user chose Quit).
    public var quitRequestedAt: Date?
    /// Failed attempts at installing `available`; later attempts back off.
    public var failures = 0
    /// Why the last attempt at `available` failed.
    public var lastFailure: String?
    public var lastAttempt: Date?

    public init(app: InstalledApp, status: AppStatus, message: String) {
        self.app = app
        self.status = status
        self.message = message
    }

    public var needsAttention: Bool { [.waitingForQuit, .closingSoon, .installing].contains(status) }
}

/// What the daemon remembers between runs: `/Library/Application Support/uk.street365.barkeep/State.json`,
/// owned by root and readable by administrators. Everyone else reads their own view of it in
/// `Users/<uid>.json`, without the apps in other people's home folders (see `Visibility`).
public struct State: Codable, Sendable, Equatable {
    public static let directory = "/Library/Application Support/\(Configuration.domain)"
    public static let path = directory + "/State.json"
    public static let viewDirectory = directory + "/Users"

    public static func viewPath(for uid: uid_t, in directory: String = State.viewDirectory) -> String {
        directory + "/\(uid).json"
    }

    public var lastScan: Date?
    public var lastCheck: Date?
    public var apps: [AppRecord] = []
    /// Barkeep's own update, if one is pending or just happened.
    public var selfUpdate: SelfUpdateReport?
    /// Bumped on every save, so readers can tell a new state from the one they have.
    public var generation = 0
    /// Effective settings that Barkeep.app needs (it cannot read what the daemon was told by a
    /// `--config` override).
    public var notifyUsers = true
    public var notifyBeforeDeadlineHours = 24
    public var allowUserInitiatedUpdates = true
    public var showInMenuBar: Bool?
    public var openAtLogin: Bool?

    public init() {}

    public func record(forPath path: String) -> AppRecord? { apps.first { $0.app.path == path } }

    /// The saved state, or nil if there is none or it cannot be trusted (not a regular file owned
    /// by root and writable only by root).
    public static func load(from path: String = State.path, requireRootOwnership: Bool = true) -> State? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        if requireRootOwnership, st.st_uid != 0 || st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decoder.decode(State.self, from: data)
    }

    /// What the current user may see: the whole state for root and administrators, otherwise
    /// their own view of it.
    public static func loadForCurrentUser() -> State? {
        load() ?? load(from: viewPath(for: getuid()))
    }

    /// Saves the state, readable by its owner and `group` (`admin`, for the daemon). Written to a
    /// new file and renamed over the old one, never through a symlink.
    public mutating func save(to path: String = State.path, group: gid_t? = nil) throws {
        generation += 1
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try ProtectedFile.write(Self.encoder.encode(self), to: path, mode: 0o640, group: group)
    }

    /// Writes each account's view of the state, readable only by root and that account, and
    /// removes the views of accounts that are gone. The folder can't be listed by others.
    public func saveViews(_ visibility: Visibility, to directory: String = State.viewDirectory) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o711])
        chmod(directory, 0o711)
        var problems: [String] = []
        var current = Set<String>()
        for account in visibility.accounts {
            let path = Self.viewPath(for: account.uid, in: directory)
            current.insert((path as NSString).lastPathComponent)
            do {
                try ProtectedFile.write(Self.encoder.encode(visibility.view(of: self, for: account.uid)), to: path,
                                        mode: 0o600, reader: account.uid)
            } catch {
                unlink(path)
                problems.append("\(error)")
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where !current.contains(name) {
            unlink(directory + "/" + name)
        }
        if !problems.isEmpty { throw BarkeepError(.failure, problems.joined(separator: "; ")) }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
