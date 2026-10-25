import Foundation
import Security

/// Settings changed on this Mac, from Barkeep.app's Settings window: `Settings.plist` beside the
/// state, owned by root and written only by the daemon, for an administrator. A configuration
/// profile wins key by key, so a Mac that is managed can't be changed where its profile speaks.
public enum LocalSettings {
    public static let path = State.directory + "/Settings.plist"

    /// Keys that can be changed here. Switches meant only for testing, the log path and the
    /// per-app `AppSources` and `AppSettings` only come from a profile.
    public static let editableKeys: Set<String> = [
        K.excludedBundleIdentifiers, K.includedBundleIdentifiers, K.scanPaths, K.allowedTeamIdentifiers,
        K.coolingOffHours, K.deadlineDays, K.deadlineBasis, K.enforceDeadlines, K.deadlineGraceMinutes,
        K.forceQuitAtDeadline, K.relaunchAfterUpdate, K.checkIntervalMinutes,
        K.requireGatekeeperAssessment, K.allowPackageInstallers, K.maximumDownloadSizeMB,
        K.notifyUsers, K.notifyBeforeDeadlineHours, K.allowUserInitiatedUpdates,
        K.automaticSelfUpdates, K.selfUpdateDeferralDays,
    ]
    private typealias K = Configuration.Key

    /// One setting's new value, as it travels from Barkeep.app to the daemon.
    public enum Value: Codable, Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case strings([String])

        var plist: Any {
            switch self {
            case .bool(let b): b
            case .int(let i): i
            case .string(let s): s
            case .strings(let a): a
            }
        }
    }

    /// The saved settings, if the file can be trusted (root-owned, writable only by root).
    public static func read(at path: String = path, requireRootOwnership: Bool = true) -> [String: Any] {
        let loader = ConfigurationLoader(requireRootOwnership: requireRootOwnership)
        if case .loaded(let dict) = loader.readTrusted(path) { return dict }
        return [:]
    }

    /// Changes one setting (nil goes back to the default). Refused for a key that can't be changed
    /// here, one the profile sets, or a value of the wrong type or out of range.
    public static func set(_ key: String, to value: Value?, managedKeys: Set<String>, at path: String = path,
                           requireRootOwnership: Bool = true) throws {
        guard editableKeys.contains(key) else { throw BarkeepError(.usage, "\(key) can only be set by a configuration profile") }
        guard !managedKeys.contains(key) else { throw BarkeepError(.usage, "\(key) is set by your organisation's profile") }
        var settings = read(at: path, requireRootOwnership: requireRootOwnership)
        if let value {
            if case .strings(let items) = value, items.isEmpty, key == K.scanPaths {
                throw BarkeepError(.usage, "\(K.scanPaths) needs at least one folder")
            }
            var check = Configuration()
            let problems = check.apply([key: value.plist], source: key)
            guard problems.isEmpty else { throw BarkeepError(.usage, problems.joined(separator: "; ")) }
            settings[key] = value.plist
        } else {
            settings[key] = nil
        }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        // Readable by everyone, so Barkeep.app can show it: it holds nothing secret.
        try ProtectedFile.write(data, to: path, mode: 0o644)
    }
}

/// The admin password check for changing settings. Barkeep.app asks for it; the daemon checks
/// the authorization it was sent, so a process running as an administrator can't change root's
/// policy without the password.
public enum SettingsAuthorization {
    public static let right = "uk.street365.barkeep.settings"
    /// How long an administrator's password lasts in the Settings window.
    static let timeoutSeconds = 300

    /// Defines the right (as root, at daemon start): an administrator, remembered for five
    /// minutes by the authorization that asked, and not shared with other apps.
    public static func register() throws {
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else {
            throw BarkeepError(.failure, "Cannot create an authorization")
        }
        defer { AuthorizationFree(auth, []) }
        let rule: [String: Any] = [
            "class": "user", "group": "admin", "authenticate-user": true, "allow-root": true,
            "shared": false, "timeout": timeoutSeconds, "version": 1,
            "comment": "Changes Barkeep's settings for this Mac.",
        ]
        let status = AuthorizationRightSet(auth, right, rule as CFDictionary,
                                           "Barkeep wants to change how apps on this Mac are updated." as CFString, nil, nil)
        guard status == errAuthorizationSuccess else {
            throw BarkeepError(.failure, "Cannot define \(right) (error \(status))")
        }
    }

    /// Removes the right (uninstalling). True if there was one.
    public static func unregister() -> Bool {
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return false }
        defer { AuthorizationFree(auth, []) }
        return AuthorizationRightRemove(auth, right) == errAuthorizationSuccess
    }

    /// Whether `externalForm` (from Barkeep.app) holds the right now, without asking anyone.
    public static func verify(_ externalForm: Data) -> Bool {
        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = externalForm.copyBytes(to: $0) }
        var auth: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &auth) == errAuthorizationSuccess, let auth else { return false }
        defer { AuthorizationFree(auth, []) }
        return right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(auth, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
    }
}
