import Foundation

/// How an app gets its updates.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    /// A Sparkle appcast (RSS with enclosures), usually `SUFeedURL` in Info.plist. Updates are
    /// signed with the app's EdDSA key (`SUPublicEDKey`), which barkeep checks.
    case sparkle = "Sparkle"
    /// electron-builder's `latest-mac.yml`, found from `app-update.yml` (GitHub, generic or S3
    /// provider). Files carry SHA-512 checksums.
    case electronBuilder = "ElectronBuilder"
    /// A Squirrel-style JSON update API such as VS Code's
    /// (`<updateUrl>/api/update/darwin-arm64/<quality>/latest`), with a SHA-256 checksum.
    case squirrel = "Squirrel"
    /// The newest non-prerelease GitHub release of `Repository`, picking the asset that matches
    /// `AssetPattern`.
    case gitHub = "GitHub"
    /// Any URL that returns the newest version, read with `VersionPath` (JSON) or
    /// `VersionPattern` (a regular expression), and a `DownloadURL` template.
    case json = "JSON"
    /// Installed from the Mac App Store. Reported, not installed: use the App Store or your MDM.
    case appStore = "AppStore"
    /// The vendor's own updater looks after it (Microsoft AutoUpdate, Adobe). Reported only.
    case vendor = "Vendor"
    /// Explicitly not managed.
    case none = "None"

    /// Kinds barkeep can install from.
    public var installs: Bool { ![.appStore, .vendor, .none].contains(self) }
}

/// One update source. Built in (the catalog), worked out from the app's own files, or written by
/// an admin in the profile's `AppSources`.
public struct AppSourceDefinition: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var kind: SourceKind
    /// Sparkle appcast, electron-builder base URL, Squirrel update URL or JSON version URL.
    public var feedURL: String?
    /// GitHub `owner/repo`.
    public var repository: String?
    /// Regular expression the GitHub asset or electron-builder file name must match.
    public var assetPattern: String?
    /// Dot path to the version in a JSON response: `LATEST_FIREFOX_VERSION`, `releases.0.version`.
    public var versionPath: String?
    /// Regular expression whose first capture group is the version, for non-JSON responses.
    public var versionPattern: String?
    /// Dot path to the release date (ISO 8601, RFC 822 or Unix seconds/milliseconds).
    public var releaseDatePath: String?
    /// Download URL; `{version}` is replaced with the version found.
    public var downloadURL: String?
    /// The Apple Team ID the app must be signed with. Recommended for every custom source.
    public var expectedTeamIdentifier: String?
    /// Squirrel: the release channel (`stable`, `insider`).
    public var channel: String?
    /// Shown to admins: which updater handles a `Vendor` app, for example.
    public var note: String?

    public init(bundleIdentifier: String, kind: SourceKind, feedURL: String? = nil, repository: String? = nil,
                assetPattern: String? = nil, versionPath: String? = nil, versionPattern: String? = nil,
                releaseDatePath: String? = nil, downloadURL: String? = nil, expectedTeamIdentifier: String? = nil,
                channel: String? = nil, note: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.kind = kind
        self.feedURL = feedURL
        self.repository = repository
        self.assetPattern = assetPattern
        self.versionPath = versionPath
        self.versionPattern = versionPattern
        self.releaseDatePath = releaseDatePath
        self.downloadURL = downloadURL
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.channel = channel
        self.note = note
    }

    enum Key {
        static let bundleIdentifier = "BundleIdentifier"
        static let type = "Type"
        static let feedURL = "FeedURL"
        static let repository = "Repository"
        static let assetPattern = "AssetPattern"
        static let versionPath = "VersionPath"
        static let versionPattern = "VersionPattern"
        static let releaseDatePath = "ReleaseDatePath"
        static let downloadURL = "DownloadURL"
        static let expectedTeamIdentifier = "ExpectedTeamIdentifier"
        static let channel = "Channel"
        static let note = "Note"
    }

    /// Reads one `AppSources` entry from a profile, checking that it has what its type needs.
    public init(plist: [String: Any]) throws {
        func string(_ key: String) throws -> String? {
            guard let value = plist[key] else { return nil }
            guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw BarkeepError(.usage, "\(key) must be a non-empty string")
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        guard let id = try string(Key.bundleIdentifier) else { throw BarkeepError(.usage, "\(Key.bundleIdentifier) is required") }
        guard let rawType = try string(Key.type),
              let kind = SourceKind.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(rawType) == .orderedSame }) else {
            throw BarkeepError(.usage, "\(Key.type) must be one of \(SourceKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self.init(bundleIdentifier: id, kind: kind, feedURL: try string(Key.feedURL), repository: try string(Key.repository),
                  assetPattern: try string(Key.assetPattern), versionPath: try string(Key.versionPath),
                  versionPattern: try string(Key.versionPattern), releaseDatePath: try string(Key.releaseDatePath),
                  downloadURL: try string(Key.downloadURL), expectedTeamIdentifier: try string(Key.expectedTeamIdentifier),
                  channel: try string(Key.channel), note: try string(Key.note))
        try validate()
    }

    public func validate() throws {
        switch kind {
        case .sparkle, .squirrel:
            guard feedURL != nil else { throw BarkeepError(.usage, "\(kind.rawValue) needs \(Key.feedURL)") }
        case .electronBuilder:
            guard feedURL != nil || repository != nil else { throw BarkeepError(.usage, "ElectronBuilder needs \(Key.feedURL) or \(Key.repository)") }
        case .gitHub:
            guard let repository, repository.split(separator: "/").count == 2 else {
                throw BarkeepError(.usage, "GitHub needs \(Key.repository) as owner/repo")
            }
        case .json:
            guard feedURL != nil, downloadURL != nil, versionPath != nil || versionPattern != nil else {
                throw BarkeepError(.usage, "JSON needs \(Key.feedURL), \(Key.downloadURL) and \(Key.versionPath) or \(Key.versionPattern)")
            }
        case .appStore, .vendor, .none: break
        }
        for pattern in [assetPattern, versionPattern].compactMap({ $0 }) {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw BarkeepError(.usage, "\(pattern) is not a valid regular expression")
            }
        }
    }
}

/// Where a source came from, which decides how far it is trusted.
public enum SourceOrigin: String, Codable, Sendable {
    /// `AppSources` in the profile.
    case profile = "Profile"
    /// Barkeep's built-in catalog.
    case catalog = "Catalog"
    /// Worked out from the installed app's own files.
    case detected = "Detected"
}

public struct ResolvedSource: Codable, Sendable, Equatable {
    public var definition: AppSourceDefinition
    public var origin: SourceOrigin
    /// What it was found from, in words: "SUFeedURL in Info.plist".
    public var evidence: String
}

/// Works out how an app updates. In order: the profile, a Mac App Store receipt, the built-in
/// catalog, then the app's own update metadata. A source from the app's own files is only as
/// trustworthy as the app, but every update must still be signed like the installed copy.
public enum SourceResolver {
    public static func resolve(_ app: InstalledApp, config: Configuration) -> (ResolvedSource?, String?) {
        let id = app.bundleIdentifier
        if let definition = config.source(for: id) {
            return (ResolvedSource(definition: definition, origin: .profile, evidence: "AppSources in the profile"), nil)
        }
        let m = app.metadata
        if m.hasAppStoreReceipt {
            return (ResolvedSource(definition: AppSourceDefinition(bundleIdentifier: id, kind: .appStore),
                                   origin: .detected, evidence: "Mac App Store receipt"), nil)
        }
        if id.caseInsensitiveCompare(Paths.appBundleIdentifier) == .orderedSame {
            return (ResolvedSource(definition: AppSourceDefinition(bundleIdentifier: id, kind: .vendor, note: "barkeep's own updates"),
                                   origin: .detected, evidence: "Barkeep.app is updated with barkeep"), nil)
        }
        if let entry = BuiltInCatalog.entry(for: id) {
            return (ResolvedSource(definition: entry, origin: .catalog, evidence: "Barkeep's catalog"), nil)
        }
        if let feed = m.sparkleFeedURL, !feed.isEmpty {
            return (ResolvedSource(definition: AppSourceDefinition(bundleIdentifier: id, kind: .sparkle, feedURL: feed),
                                   origin: .detected, evidence: "SUFeedURL in Info.plist"), nil)
        }
        if let updateURL = m.productUpdateURL, !updateURL.isEmpty {
            return (ResolvedSource(definition: AppSourceDefinition(bundleIdentifier: id, kind: .squirrel, feedURL: updateURL,
                                                                   channel: m.productQuality ?? "stable"),
                                   origin: .detected, evidence: "updateUrl in Resources/app/product.json"), nil)
        }
        if let yml = m.electronUpdate, let definition = electronDefinition(id, yml) {
            return (ResolvedSource(definition: definition, origin: .detected, evidence: "Resources/app-update.yml"), nil)
        }
        if let vendor = m.vendorUpdater ?? UpdateMetadata.vendorUpdater(for: id) {
            return (ResolvedSource(definition: AppSourceDefinition(bundleIdentifier: id, kind: .vendor, note: vendor),
                                   origin: .detected, evidence: "Updated by \(vendor)"), nil)
        }
        if m.hasSparkleFramework {
            return (nil, "Uses Sparkle but sets its feed at run time; add it to AppSources")
        }
        if m.electronUpdate != nil {
            return (nil, "Uses electron-builder with a provider barkeep does not read; add it to AppSources")
        }
        return (nil, "No update feed found; add it to AppSources")
    }

    /// An electron-builder `app-update.yml` as a source: `provider: github` (owner, repo),
    /// `generic` (url) or `s3` (bucket, region, path).
    static func electronDefinition(_ id: String, _ yml: [String: String]) -> AppSourceDefinition? {
        switch yml["provider"]?.lowercased() {
        case "github":
            guard let owner = yml["owner"], let repo = yml["repo"] else { return nil }
            return AppSourceDefinition(bundleIdentifier: id, kind: .electronBuilder, repository: "\(owner)/\(repo)",
                                       channel: yml["channel"])
        case "generic":
            guard let url = yml["url"], url.hasPrefix("https://") else { return nil }
            return AppSourceDefinition(bundleIdentifier: id, kind: .electronBuilder, feedURL: url, channel: yml["channel"])
        case "s3":
            guard let bucket = yml["bucket"] else { return nil }
            let host = yml["region"].map { "s3.\($0).amazonaws.com" } ?? "s3.amazonaws.com"
            let path = yml["path"].map { "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
            return AppSourceDefinition(bundleIdentifier: id, kind: .electronBuilder, feedURL: "https://\(host)/\(bucket)\(path)",
                                       channel: yml["channel"])
        default:
            return nil
        }
    }
}
