import Foundation

/// When an update's deadline starts counting.
public enum DeadlineBasis: String, Sendable, Codable, CaseIterable {
    /// From when barkeep first found the update on this Mac.
    case discovered = "Discovered"
    /// From when the vendor published it, if the feed says. Falls back to `discovered`.
    case released = "Released"
}

/// Settings that can be set for one app in `AppSettings`, overriding the global ones.
public struct AppOverrides: Sendable, Equatable, Codable {
    public var excluded: Bool?
    public var coolingOffHours: Int?
    public var deadlineDays: Int?
    public var deadlineBasis: DeadlineBasis?
    public var enforceDeadline: Bool?
    public var forceQuitAtDeadline: Bool?

    public init() {}
}

/// Effective settings. Values come from managed preferences delivered by a configuration profile
/// (PayloadType `uk.street365.barkeep`), which users cannot change. Every key is optional: the
/// defaults keep apps updated without ever interrupting anyone until a deadline passes.
public struct Configuration: Sendable, Equatable, Codable {
    public static let domain = "uk.street365.barkeep"
    public static let managedPreferencesDirectory = "/Library/Managed Preferences"

    // MARK: Which apps

    /// Bundle IDs barkeep leaves alone. A trailing `*` matches a prefix: `com.microsoft.*`.
    public var excludedBundleIdentifiers: [String] = []
    /// If non-empty, only these bundle IDs (same wildcard rules) are managed.
    public var includedBundleIdentifiers: [String] = []
    /// Folders searched for apps. `~` stands for every local user's home folder. Setting it
    /// replaces the defaults, so a profile lists every folder it wants.
    public var scanPaths: [String] = Configuration.defaultScanPaths
    /// If non-empty, only apps signed by one of these Team IDs are updated.
    public var allowedTeamIdentifiers: [String] = []
    /// Update sources for apps barkeep cannot work out itself, or to replace what it found.
    public var appSources: [AppSourceDefinition] = []
    /// Per-app overrides of the timing settings, keyed by bundle ID.
    public var appSettings: [String: AppOverrides] = [:]

    // MARK: When

    /// Hours an update must have been published (or, if the feed has no date, known to barkeep)
    /// before it is installed.
    public var coolingOffHours = 168
    /// Days after which a waiting update is installed even if the app is in use. Counted from
    /// `deadlineBasis`, and never before the cooling-off period ends.
    public var deadlineDays = 14
    public var deadlineBasis: DeadlineBasis = .released
    /// Off: updates only ever install while the app is closed, however long that takes.
    public var enforceDeadlines = true
    /// Minutes between telling the user an app will close for its update and closing it.
    public var deadlineGraceMinutes = 60
    /// After asking politely, terminate an app that refuses to quit (an unsaved document dialog,
    /// say). Off by default: the user is asked again at the next check instead.
    public var forceQuitAtDeadline = false
    /// Reopen an app that barkeep closed for its update.
    public var relaunchAfterUpdate = true
    /// How often feeds are checked.
    public var checkIntervalMinutes = 240

    // MARK: Security

    /// Require `spctl --assess` to accept the new copy (notarised Developer ID or Mac App Store).
    public var requireGatekeeperAssessment = true
    /// Allow updates delivered as installer packages, which run the vendor's scripts as root. The
    /// package must be signed by the app's own team and notarised.
    public var allowPackageInstallers = true
    /// Largest download accepted.
    public var maximumDownloadSizeMB = 2048
    /// Testing only: accept apps whose signatures are not issued by Apple (self-signed or ad hoc).
    /// The designated requirement and bundle ID checks still apply.
    public var allowUnverifiedSignatures = false
    /// Testing only: accept `file://` URLs in `AppSources`.
    public var allowFileURLs = false

    // MARK: Users

    /// Post notifications about updates that need an app to close.
    public var notifyUsers = true
    /// Hours before a deadline at which the user is first told about it.
    public var notifyBeforeDeadlineHours = 24
    /// Let users start updates from Barkeep.app ("Update now", "Check for updates").
    public var allowUserInitiatedUpdates = true
    /// Show Barkeep in the menu bar. nil leaves it to the user (on by default).
    public var showInMenuBar: Bool?
    /// Start Barkeep.app when a user logs in. nil leaves it to the user (on by default). Off, there
    /// is no launch guard, polite quitting at deadlines or notifications until the user opens it.
    public var openAtLogin: Bool?

    // MARK: Barkeep itself

    /// Install new releases of barkeep from GitHub while the Mac is idle.
    public var automaticSelfUpdates = true
    /// Days a barkeep release must have been out before it is installed automatically.
    public var selfUpdateDeferralDays = 7
    public var logFilePath: String?

    public static let defaultScanPaths = ["/Applications", "~/Applications"]
    public static let maxSelfUpdateDeferralDays = 30

    /// Where values came from (for `show-config`).
    public var sources: [String] = ["defaults"]

    public init() {}

    public func effectiveLogFilePath(isRoot: Bool = geteuid() == 0) -> String {
        if let logFilePath { return logFilePath }
        if isRoot { return "/Library/Logs/barkeep.log" }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/barkeep.log").path
    }

    // MARK: Matching

    public func isExcluded(_ bundleID: String) -> Bool {
        if appSettings[bundleID]?.excluded == true { return true }
        if Self.matches(bundleID, excludedBundleIdentifiers) { return true }
        if !includedBundleIdentifiers.isEmpty, !Self.matches(bundleID, includedBundleIdentifiers) { return true }
        return false
    }

    /// Exact, case-insensitive matches, and prefixes for patterns that end in `*`.
    public static func matches(_ bundleID: String, _ patterns: [String]) -> Bool {
        let id = bundleID.lowercased()
        return patterns.contains { pattern in
            let p = pattern.lowercased()
            if p == "*" { return true }
            if p.hasSuffix("*") { return id.hasPrefix(String(p.dropLast())) }
            return id == p
        }
    }

    public func isTeamAllowed(_ team: String?) -> Bool {
        guard !allowedTeamIdentifiers.isEmpty else { return true }
        guard let team else { return false }
        return allowedTeamIdentifiers.contains { $0.caseInsensitiveCompare(team) == .orderedSame }
    }

    /// The timing settings for one app, with its `AppSettings` entry applied.
    public func timing(for bundleID: String) -> UpdateTiming {
        let o = appSettings[bundleID]
        return UpdateTiming(coolingOffHours: o?.coolingOffHours ?? coolingOffHours,
                            deadlineDays: o?.deadlineDays ?? deadlineDays,
                            deadlineBasis: o?.deadlineBasis ?? deadlineBasis,
                            enforceDeadline: o?.enforceDeadline ?? enforceDeadlines,
                            forceQuit: o?.forceQuitAtDeadline ?? forceQuitAtDeadline,
                            graceMinutes: deadlineGraceMinutes)
    }

    public func source(for bundleID: String) -> AppSourceDefinition? {
        appSources.last { $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    // MARK: Keys

    public enum Key {
        static let excludedBundleIdentifiers = "ExcludedBundleIdentifiers"
        static let includedBundleIdentifiers = "IncludedBundleIdentifiers"
        static let scanPaths = "ScanPaths"
        static let allowedTeamIdentifiers = "AllowedTeamIdentifiers"
        static let appSources = "AppSources"
        static let appSettings = "AppSettings"
        static let coolingOffHours = "CoolingOffHours"
        static let deadlineDays = "DeadlineDays"
        static let deadlineBasis = "DeadlineBasis"
        static let enforceDeadlines = "EnforceDeadlines"
        static let deadlineGraceMinutes = "DeadlineGraceMinutes"
        static let forceQuitAtDeadline = "ForceQuitAtDeadline"
        static let relaunchAfterUpdate = "RelaunchAfterUpdate"
        static let checkIntervalMinutes = "CheckIntervalMinutes"
        static let requireGatekeeperAssessment = "RequireGatekeeperAssessment"
        static let allowPackageInstallers = "AllowPackageInstallers"
        static let maximumDownloadSizeMB = "MaximumDownloadSizeMB"
        static let allowUnverifiedSignatures = "AllowUnverifiedSignatures"
        static let allowFileURLs = "AllowFileURLs"
        static let notifyUsers = "NotifyUsers"
        static let notifyBeforeDeadlineHours = "NotifyBeforeDeadlineHours"
        static let allowUserInitiatedUpdates = "AllowUserInitiatedUpdates"
        static let showInMenuBar = "ShowInMenuBar"
        static let openAtLogin = "OpenAtLogin"
        static let automaticSelfUpdates = "AutomaticSelfUpdates"
        static let selfUpdateDeferralDays = "SelfUpdateDeferralDays"
        static let logFilePath = "LogFilePath"

        // AppSettings entries
        static let excluded = "Excluded"
        static let enforceDeadline = "EnforceDeadline"
    }

    /// Applies keys from a preferences dictionary. Unknown keys are ignored; keys with the wrong
    /// type or out of range are reported in the returned warnings and ignored or clamped.
    @discardableResult
    public mutating func apply(_ dict: [String: Any], source: String) -> [String] {
        var reader = PlistReader(dict: dict, source: source)

        reader.bool(Key.requireGatekeeperAssessment, &requireGatekeeperAssessment)
        reader.bool(Key.allowPackageInstallers, &allowPackageInstallers)
        reader.bool(Key.allowUnverifiedSignatures, &allowUnverifiedSignatures)
        reader.bool(Key.allowFileURLs, &allowFileURLs)
        reader.bool(Key.enforceDeadlines, &enforceDeadlines)
        reader.bool(Key.forceQuitAtDeadline, &forceQuitAtDeadline)
        reader.bool(Key.relaunchAfterUpdate, &relaunchAfterUpdate)
        reader.bool(Key.notifyUsers, &notifyUsers)
        reader.bool(Key.allowUserInitiatedUpdates, &allowUserInitiatedUpdates)
        reader.bool(Key.automaticSelfUpdates, &automaticSelfUpdates)
        if let value = reader.optionalBool(Key.showInMenuBar) { showInMenuBar = value }
        if let value = reader.optionalBool(Key.openAtLogin) { openAtLogin = value }

        reader.int(Key.coolingOffHours, &coolingOffHours, range: 0...8760)
        reader.int(Key.deadlineDays, &deadlineDays, range: 0...365)
        reader.int(Key.deadlineGraceMinutes, &deadlineGraceMinutes, range: 0...1440)
        reader.int(Key.checkIntervalMinutes, &checkIntervalMinutes, range: 15...10080)
        reader.int(Key.notifyBeforeDeadlineHours, &notifyBeforeDeadlineHours, range: 0...720)
        reader.int(Key.maximumDownloadSizeMB, &maximumDownloadSizeMB, range: 1...20480)
        reader.int(Key.selfUpdateDeferralDays, &selfUpdateDeferralDays, range: 0...Self.maxSelfUpdateDeferralDays)

        if let raw = reader.string(Key.deadlineBasis) {
            if let basis = DeadlineBasis.parse(raw) { deadlineBasis = basis }
            else { reader.warn("\(Key.deadlineBasis) must be one of \(DeadlineBasis.allCases.map(\.rawValue).joined(separator: ", "))") }
        }
        if let path = reader.string(Key.logFilePath) { logFilePath = path }

        if let ids = reader.strings(Key.excludedBundleIdentifiers) { excludedBundleIdentifiers = ids }
        if let ids = reader.strings(Key.includedBundleIdentifiers) { includedBundleIdentifiers = ids }
        if let ids = reader.strings(Key.allowedTeamIdentifiers) { allowedTeamIdentifiers = ids }
        if let paths = reader.strings(Key.scanPaths) { scanPaths = paths }

        if let value = dict[Key.appSources] {
            if let entries = value as? [[String: Any]] {
                appSources = entries.enumerated().compactMap { index, entry in
                    do {
                        return try AppSourceDefinition(plist: entry)
                    } catch {
                        reader.warn("\(Key.appSources)[\(index)]: \(error)")
                        return nil
                    }
                }
            } else {
                reader.warn("\(Key.appSources) must be an array of dictionaries")
            }
        }

        if let value = dict[Key.appSettings] {
            if let entries = value as? [String: Any] {
                var result: [String: AppOverrides] = [:]
                for (bundleID, raw) in entries {
                    guard let entry = raw as? [String: Any] else {
                        reader.warn("\(Key.appSettings).\(bundleID) must be a dictionary")
                        continue
                    }
                    var sub = PlistReader(dict: entry, source: "\(source): \(Key.appSettings).\(bundleID)")
                    var o = AppOverrides()
                    o.excluded = sub.optionalBool(Key.excluded)
                    o.enforceDeadline = sub.optionalBool(Key.enforceDeadline)
                    o.forceQuitAtDeadline = sub.optionalBool(Key.forceQuitAtDeadline)
                    o.coolingOffHours = sub.optionalInt(Key.coolingOffHours, range: 0...8760)
                    o.deadlineDays = sub.optionalInt(Key.deadlineDays, range: 0...365)
                    if let raw = sub.string(Key.deadlineBasis) {
                        o.deadlineBasis = DeadlineBasis.parse(raw)
                        if o.deadlineBasis == nil { sub.warn("\(Key.deadlineBasis) must be Discovered or Released") }
                    }
                    reader.warnings += sub.warnings
                    result[bundleID] = o
                }
                appSettings = result
            } else {
                reader.warn("\(Key.appSettings) must be a dictionary keyed by bundle ID")
            }
        }

        if sources == ["defaults"] { sources = [] }
        sources.append(source)
        return reader.warnings
    }
}

extension DeadlineBasis {
    static func parse(_ raw: String) -> DeadlineBasis? {
        allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
    }
}

/// The timing rules that apply to one app.
public struct UpdateTiming: Sendable, Equatable, Codable {
    public var coolingOffHours: Int
    public var deadlineDays: Int
    public var deadlineBasis: DeadlineBasis
    public var enforceDeadline: Bool
    public var forceQuit: Bool
    public var graceMinutes: Int
}

/// Reads typed values from a property list dictionary, collecting warnings for wrong types.
struct PlistReader {
    let dict: [String: Any]
    let source: String
    var warnings: [String] = []

    init(dict: [String: Any], source: String) {
        self.dict = dict
        self.source = source
    }

    mutating func warn(_ message: String) { warnings.append("\(source): \(message)") }

    static func isBool(_ value: Any) -> Bool { CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() }

    mutating func optionalBool(_ key: String) -> Bool? {
        guard let value = dict[key] else { return nil }
        if Self.isBool(value), let b = value as? Bool { return b }
        warn("\(key) must be a boolean")
        return nil
    }

    mutating func bool(_ key: String, _ target: inout Bool) {
        if let value = optionalBool(key) { target = value }
    }

    mutating func optionalInt(_ key: String, range: ClosedRange<Int>) -> Int? {
        guard let value = dict[key] else { return nil }
        // Property lists store booleans as numbers too, so `true` must not read as 1.
        guard !Self.isBool(value), let number = value as? Int else {
            warn("\(key) must be an integer")
            return nil
        }
        guard range.contains(number) else {
            let clamped = min(max(number, range.lowerBound), range.upperBound)
            warn("\(key) must be \(range.lowerBound) to \(range.upperBound); using \(clamped)")
            return clamped
        }
        return number
    }

    mutating func int(_ key: String, _ target: inout Int, range: ClosedRange<Int>) {
        if let value = optionalInt(key, range: range) { target = value }
    }

    mutating func string(_ key: String) -> String? {
        guard let value = dict[key] else { return nil }
        if let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespaces) }
        warn("\(key) must be a non-empty string")
        return nil
    }

    mutating func strings(_ key: String) -> [String]? {
        guard let value = dict[key] else { return nil }
        guard let items = value as? [String] else {
            warn("\(key) must be an array of strings")
            return nil
        }
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct ConfigurationLoader: Sendable {
    public var managedPreferencesDirectory: String
    /// Managed preference files are only trusted when owned by root and not writable by others.
    /// Tests turn this off.
    public var requireRootOwnership: Bool

    public init(managedPreferencesDirectory: String = Configuration.managedPreferencesDirectory,
                requireRootOwnership: Bool = true) {
        self.managedPreferencesDirectory = managedPreferencesDirectory
        self.requireRootOwnership = requireRootOwnership
    }

    public var devicePath: String { "\(managedPreferencesDirectory)/\(Configuration.domain).plist" }

    /// Precedence (lowest to highest): built-in defaults, the device-scoped profile, then
    /// `overrideFile` (only honoured for root; see the CLI). Barkeep works for the whole Mac, so
    /// user-scoped profiles are not read.
    public func load(overrideFile: String? = nil) -> (Configuration, [String]) {
        var config = Configuration()
        var warnings: [String] = []
        switch readTrusted(devicePath) {
        case .missing: break
        case .rejected(let why): warnings.append("Ignoring \(devicePath): \(why)")
        case .loaded(let dict): warnings += config.apply(dict, source: devicePath)
        }
        if let overrideFile {
            switch Self.readPlist(overrideFile) {
            case .loaded(let dict): warnings += config.apply(dict, source: overrideFile)
            case .missing: warnings.append("Configuration file \(overrideFile) does not exist")
            case .rejected(let why): warnings.append("Ignoring \(overrideFile): \(why)")
            }
        }
        return (config, warnings)
    }

    enum ReadResult {
        case missing
        case rejected(String)
        case loaded([String: Any])
    }

    func readTrusted(_ path: String) -> ReadResult {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        if requireRootOwnership {
            if (st.st_mode & S_IFMT) != S_IFREG { return .rejected("not a regular file") }
            if st.st_uid != 0 { return .rejected("not owned by root") }
            if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return .rejected("writable by group or others") }
        }
        return Self.readPlist(path)
    }

    static func readPlist(_ path: String) -> ReadResult {
        guard let data = FileManager.default.contents(atPath: path) else { return .missing }
        do {
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = object as? [String: Any] else { return .rejected("top level is not a dictionary") }
            return .loaded(dict)
        } catch {
            return .rejected("unreadable property list (\(error.localizedDescription))")
        }
    }
}
