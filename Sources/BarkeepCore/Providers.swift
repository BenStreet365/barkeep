import Foundation

/// The newest version a source offers.
public struct AvailableUpdate: Codable, Sendable, Equatable {
    /// The version people see (CFBundleShortVersionString).
    public var version: String
    /// The build (CFBundleVersion), when the feed gives it. Sparkle compares builds.
    public var build: String?
    /// nil for sources barkeep only reports on.
    public var downloadURL: String?
    /// When the vendor published it, if the feed says.
    public var releaseDate: Date?
    public var size: Int64?
    /// Hex SHA-256 of the download, from the feed.
    public var sha256: String?
    /// Base64 SHA-512 of the download (electron-builder).
    public var sha512: String?
    /// Sparkle's base64 Ed25519 signature of the download.
    public var edSignature: String?
    public var minimumSystemVersion: String?
    public var releaseNotesURL: String?

    public init(version: String, build: String? = nil, downloadURL: String? = nil, releaseDate: Date? = nil) {
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.releaseDate = releaseDate
    }

    public var displayVersion: String { AppBundle.displayVersion(short: version, build: build) }

    /// Whether this is newer than what `app` has. Sparkle feeds give the build, which is what
    /// Sparkle itself compares; other feeds give the marketing version.
    public func isNewer(than app: InstalledApp) -> Bool {
        if let build, let installed = app.buildVersion, build != version {
            let byBuild = Version.compare(build, installed)
            if byBuild != .orderedSame { return byBuild == .orderedDescending }
        }
        guard let installed = app.shortVersion ?? app.buildVersion else { return true }
        return Version.compare(version, installed) == .orderedDescending
    }
}

public enum Version {
    /// Compares versions by their numeric and alphabetic runs, ignoring punctuation:
    /// "1.10" > "1.9", "2.0" == "2", "7.2.2 (88465)" == "7.2.2.88465", "1.0b2" > "1.0b1", "v2.0.12" == "2.0.12".
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var left = tokens(a), right = tokens(b)
        let count = max(left.count, right.count)
        left += Array(repeating: "0", count: count - left.count)
        right += Array(repeating: "0", count: count - right.count)
        for (l, r) in zip(left, right) {
            let result = l.compare(r, options: [.numeric, .caseInsensitive])
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    static func tokens(_ version: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for ch in version {
            let isDigit = ch.isASCII && ch.isNumber
            let isLetter = ch.isASCII && ch.isLetter
            guard isDigit || isLetter else {
                if !current.isEmpty { result.append(current) }
                current = ""
                currentIsDigit = nil
                continue
            }
            if let kind = currentIsDigit, kind != isDigit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(ch)
            currentIsDigit = isDigit
        }
        if !current.isEmpty { result.append(current) }
        // A leading "v" (Raspberry Pi Imager's "v2.0.12") is not part of the version.
        if result.count > 1, result[0].caseInsensitiveCompare("v") == .orderedSame, result[1].first?.isNumber == true {
            result.removeFirst()
        }
        return result
    }

    /// The version in a release tag: "v1.2.3" and "release-1.2.3" give "1.2.3".
    static func fromTag(_ tag: String) -> String {
        guard let start = tag.firstIndex(where: \.isNumber) else { return tag }
        return String(tag[start...])
    }
}

/// Reads the newest version from a source.
public struct UpdateFinder {
    public let config: Configuration
    public let log: Log
    /// The macOS version the update must run on.
    public var systemVersion = ProcessInfo.processInfo.operatingSystemVersion

    public init(config: Configuration, log: Log) {
        self.config = config
        self.log = log
    }

    static let feedLimit = 8 * 1024 * 1024

    func get(_ raw: String, headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: raw) else { throw BarkeepError(.feedError, "\(raw) is not a URL") }
        return try HTTPClient.get(url, maxBytes: Self.feedLimit, headers: headers, allowFile: config.allowFileURLs)
    }

    public func latest(for app: InstalledApp, source: AppSourceDefinition) throws -> AvailableUpdate? {
        switch source.kind {
        case .sparkle: try sparkle(app, source)
        case .electronBuilder: try electronBuilder(app, source)
        case .squirrel: try squirrel(app, source)
        case .gitHub: try gitHub(app, source)
        case .json: try json(app, source)
        case .appStore: try appStore(app)
        case .vendor, .none: nil
        }
    }

    // MARK: Sparkle

    func sparkle(_ app: InstalledApp, _ source: AppSourceDefinition) throws -> AvailableUpdate? {
        let (data, _) = try get(source.feedURL ?? "")
        let items = try SparkleAppcast.parse(data)
        let usable = items.filter { item in
            !item.informational && item.channel == nil && item.isForMac
                && item.minimumSystemVersion.map { Self.systemSatisfies($0, systemVersion) } ?? true
                && item.maximumSystemVersion.map { !Self.systemSatisfies(Self.bump($0), systemVersion) } ?? true
                && (item.hardwareRequirements.isEmpty || item.hardwareRequirements.contains("arm64"))
        }
        guard let best = usable.max(by: { Version.compare($0.build, $1.build) == .orderedAscending }) else { return nil }
        var update = AvailableUpdate(version: best.shortVersion ?? best.build, build: best.build,
                                     downloadURL: Self.resolve(best.url, against: source.feedURL), releaseDate: best.date)
        update.size = best.length
        update.edSignature = best.edSignature
        update.minimumSystemVersion = best.minimumSystemVersion
        update.releaseNotesURL = best.releaseNotesURL
        return update
    }

    /// An enclosure URL relative to the appcast (Tailscale's `Tailscale-1.104.2-macos.zip`), made
    /// absolute. The download itself must still be HTTPS.
    static func resolve(_ url: String, against feed: String?) -> String {
        guard let feed, let base = URL(string: feed), let resolved = URL(string: url, relativeTo: base) else { return url }
        return resolved.absoluteString
    }

    /// The next minor version, so a maximum of "15.99" still accepts 15.99.1.
    static func bump(_ version: String) -> String { version + ".999" }

    static func systemSatisfies(_ minimum: String, _ system: OperatingSystemVersion) -> Bool {
        let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return Version.compare(current, minimum) != .orderedAscending
    }

    // MARK: electron-builder

    func electronBuilder(_ app: InstalledApp, _ source: AppSourceDefinition) throws -> AvailableUpdate? {
        let channel = (source.channel ?? "latest") + "-mac.yml"
        let yml: String
        var resolve: (String) -> String?
        var published: Date?
        if let repository = source.repository {
            let release = try latestGitHubRelease(repository)
            published = release.publishedAt
            guard let asset = release.assets.first(where: { $0.name == channel }) else {
                throw BarkeepError(.feedError, "The newest release of \(repository) has no \(channel)")
            }
            yml = String(decoding: try get(asset.browserDownloadUrl).0, as: UTF8.self)
            resolve = { name in release.assets.first { $0.name == name }?.browserDownloadUrl }
        } else {
            let base = (source.feedURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            yml = String(decoding: try get("\(base)/\(channel)").0, as: UTF8.self)
            resolve = { name in name.hasPrefix("https://") ? name : "\(base)/\(name)" }
        }
        let top = SimpleYAML.parseFlat(yml)
        guard let version = top["version"] else { throw BarkeepError(.feedError, "\(channel) has no version") }
        let files = SimpleYAML.parseFiles(yml)
        guard let file = Self.pickElectronFile(files, pattern: source.assetPattern), let name = file["url"],
              let url = resolve(name) else {
            throw BarkeepError(.feedError, "\(channel) lists no download for Apple silicon")
        }
        var update = AvailableUpdate(version: version, downloadURL: url,
                                     releaseDate: top["releaseDate"].flatMap(DateParsing.parse) ?? published)
        update.sha512 = file["sha512"]
        update.size = file["size"].flatMap { Int64($0) }
        return update
    }

    /// Prefers an arm64 zip, then a universal zip, then the same as dmg. x64-only files are skipped.
    static func pickElectronFile(_ files: [[String: String]], pattern: String?) -> [String: String]? {
        let regex = pattern.flatMap { try? NSRegularExpression(pattern: $0) }
        let candidates = files.filter { file in
            guard let url = file["url"]?.lowercased() else { return false }
            guard url.hasSuffix(".zip") || url.hasSuffix(".dmg") else { return false }
            if let regex { return regex.firstMatch(in: file["url"]!, range: NSRange(file["url"]!.startIndex..., in: file["url"]!)) != nil }
            return !(url.contains("x64") || url.contains("x86_64") || url.contains("intel"))
        }
        func score(_ file: [String: String]) -> Int {
            let url = file["url"]!.lowercased()
            return (url.contains("arm64") ? 4 : url.contains("universal") ? 2 : 0) + (url.hasSuffix(".zip") ? 1 : 0)
        }
        return candidates.max { score($0) < score($1) }
    }

    // MARK: Squirrel (VS Code)

    func squirrel(_ app: InstalledApp, _ source: AppSourceDefinition) throws -> AvailableUpdate? {
        let base = (source.feedURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let platform = app.metadata.architectures == ["x86_64"] ? "darwin" : "darwin-arm64"
        let url = "\(base)/api/update/\(platform)/\(source.channel ?? "stable")/latest"
        guard let parsedURL = URL(string: url) else { throw BarkeepError(.feedError, "\(url) is not a URL") }
        let (data, response) = try HTTPClient.get(parsedURL, maxBytes: Self.feedLimit, accepting: [200, 204],
                                                  allowFile: config.allowFileURLs)
        if response?.statusCode == 204 { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let download = json["url"] as? String else {
            throw BarkeepError(.feedError, "Unexpected response from \(url)")
        }
        let version = json["productVersion"] as? String ?? json["name"] as? String ?? ""
        guard !version.isEmpty else { throw BarkeepError(.feedError, "\(url) gave no version") }
        var update = AvailableUpdate(version: version, downloadURL: download,
                                     releaseDate: (json["timestamp"] as? NSNumber).flatMap { DateParsing.fromEpoch($0.doubleValue) })
        update.sha256 = (json["sha256hash"] as? String)?.lowercased()
        return update
    }

    // MARK: GitHub

    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            let size: Int64?
            let digest: String?
        }
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let assets: [Asset]
    }

    func latestGitHubRelease(_ repository: String) throws -> GitHubRelease {
        let (data, _) = try get("https://api.github.com/repos/\(repository)/releases/latest",
                                headers: ["Accept": "application/vnd.github+json"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw BarkeepError(.feedError, "Cannot read the newest release of \(repository): \(error.localizedDescription)")
        }
    }

    func gitHub(_ app: InstalledApp, _ source: AppSourceDefinition) throws -> AvailableUpdate? {
        let repository = source.repository ?? ""
        let release = try latestGitHubRelease(repository)
        guard !release.draft, !release.prerelease else { return nil }
        guard let asset = Self.pickGitHubAsset(release.assets, pattern: source.assetPattern) else {
            throw BarkeepError(.feedError, "The newest release of \(repository) has no Mac download\(source.assetPattern.map { " matching \($0)" } ?? "")")
        }
        var update = AvailableUpdate(version: Version.fromTag(release.tagName), downloadURL: asset.browserDownloadUrl,
                                     releaseDate: release.publishedAt)
        update.size = asset.size
        if let digest = asset.digest, digest.hasPrefix("sha256:") { update.sha256 = String(digest.dropFirst(7)).lowercased() }
        return update
    }

    static func pickGitHubAsset(_ assets: [GitHubRelease.Asset], pattern: String?) -> GitHubRelease.Asset? {
        if let pattern, let regex = try? NSRegularExpression(pattern: pattern) {
            return assets.first { regex.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) != nil }
        }
        let installable = assets.filter { asset in
            let n = asset.name.lowercased()
            return [".dmg", ".zip", ".pkg"].contains { n.hasSuffix($0) }
                && !["x64", "x86_64", "intel", "win", "linux", "blockmap", "src", "source"].contains { n.contains($0) }
        }
        func score(_ asset: GitHubRelease.Asset) -> Int {
            let n = asset.name.lowercased()
            var s = 0
            if n.contains("arm64") || n.contains("aarch64") || n.contains("apple-silicon") { s += 8 }
            if n.contains("universal") { s += 6 }
            if n.contains("mac") || n.contains("darwin") || n.contains("osx") || n.contains("macos") { s += 4 }
            if n.hasSuffix(".dmg") { s += 2 } else if n.hasSuffix(".zip") { s += 1 }
            return s
        }
        return installable.max { score($0) < score($1) }
    }

    // MARK: JSON / text

    func json(_ app: InstalledApp, _ source: AppSourceDefinition) throws -> AvailableUpdate? {
        let (data, _) = try get(source.feedURL ?? "")
        var version: String?
        var date: Date?
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let path = source.versionPath {
            version = object.flatMap { JSONPath.value(at: path, in: $0) }.flatMap(JSONPath.string)
            if let datePath = source.releaseDatePath, let object {
                date = JSONPath.value(at: datePath, in: object).flatMap(DateParsing.parseAny)
            }
        } else if let pattern = source.versionPattern, let regex = try? NSRegularExpression(pattern: pattern) {
            let text = String(decoding: data, as: UTF8.self)
            if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) {
                version = String(text[range])
            }
        }
        guard let version, !version.isEmpty, !version.containsControlCharacters else {
            throw BarkeepError(.feedError, "No version found in \(source.feedURL ?? "")")
        }
        let download: String
        if let path = source.downloadPath {
            guard let url = object.flatMap({ JSONPath.value(at: path, in: $0) }).flatMap(JSONPath.string),
                  !url.isEmpty, !url.containsControlCharacters else {
                throw BarkeepError(.feedError, "No download URL at \(path) in \(source.feedURL ?? "")")
            }
            download = url
        } else {
            let encoded = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
            download = (source.downloadURL ?? "").replacingOccurrences(of: "{version}", with: encoded)
        }
        return AvailableUpdate(version: version, downloadURL: download, releaseDate: date)
    }

    // MARK: Mac App Store

    func appStore(_ app: InstalledApp) throws -> AvailableUpdate? {
        let id = app.bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.bundleIdentifier
        let (data, _) = try get("https://itunes.apple.com/lookup?bundleId=\(id)&entity=macSoftware")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let version = result["version"] as? String else { return nil }
        var update = AvailableUpdate(version: version, releaseDate: (result["currentVersionReleaseDate"] as? String).flatMap(DateParsing.parse))
        update.minimumSystemVersion = result["minimumOsVersion"] as? String
        return update
    }
}

/// Dot paths into decoded JSON: `a.b.0.c`.
enum JSONPath {
    static func value(at path: String, in object: Any) -> Any? {
        var current: Any? = object
        for key in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func string(_ value: Any) -> String? {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}

public enum DateParsing {
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm zzz",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd",
    ]

    /// ISO 8601 (with or without fractions), RFC 822 and a few common variants.
    public static func parse(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in rfc822Formats {
            formatter.dateFormat = format
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }

    static func parseAny(_ value: Any) -> Date? {
        if let s = value as? String { return parse(s) ?? Double(s).flatMap(fromEpoch) }
        if let n = value as? NSNumber { return fromEpoch(n.doubleValue) }
        return nil
    }

    /// Seconds or milliseconds since 1970.
    static func fromEpoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }
}
