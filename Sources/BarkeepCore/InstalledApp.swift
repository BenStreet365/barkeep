import Darwin
import Foundation

/// What barkeep knows about one app on disk: its identity, its signature, and the update
/// metadata it ships with (a Sparkle feed, an electron-builder `app-update.yml`, a VS Code style
/// `product.json`, a Mac App Store receipt). Everything is read without following symlinks, with
/// size limits, since apps in a user's ~/Applications are under that user's control.
public struct InstalledApp: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleIdentifier: String
    public var shortVersion: String?
    public var buildVersion: String?
    /// Owner of the bundle folder: root (or an admin) for /Applications, the user for ~/Applications.
    public var ownerUID: uid_t
    /// Set by a deep inspection: nil when the signature is missing or not valid, and
    /// `signatureProblem` says why. A quick inspection (the routine scan) leaves it nil and
    /// `signatureChecked` false.
    public var signing: SigningInfo?
    public var signatureProblem: String?
    public var signatureChecked = false
    /// The Team ID the signature names, without checking it. For display only.
    public var claimedTeamID: String?
    public var designatedRequirement: String?
    public var metadata: UpdateMetadata

    /// Identifies this copy of the bundle on disk; see `fingerprint(of:)`.
    public var fingerprint: String?

    public var displayVersion: String { AppBundle.displayVersion(short: shortVersion, build: buildVersion) }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Apple's own apps are updated by Software Update or the App Store, never by barkeep.
    public var isApple: Bool { bundleIdentifier.lowercased().hasPrefix("com.apple.") }

    public var teamID: String? { signing?.teamID ?? claimedTeamID }

    public init(path: String, name: String, bundleIdentifier: String, shortVersion: String?, buildVersion: String?,
                ownerUID: uid_t, signing: SigningInfo?, signatureProblem: String?, designatedRequirement: String?,
                metadata: UpdateMetadata) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.ownerUID = ownerUID
        self.signing = signing
        self.signatureProblem = signatureProblem
        self.designatedRequirement = designatedRequirement
        self.metadata = metadata
    }

    /// Changes when the bundle is replaced or its Info.plist rewritten, found with `lstat` alone
    /// so it is cheap and safe to take for every app on every pass, even as root in a user's folder.
    public static func fingerprint(of url: URL) -> String? {
        var bundle = stat(), info = stat(), contents = stat()
        guard lstat(url.path, &bundle) == 0, (bundle.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let contentsPath = url.path + "/Contents"
        guard lstat(contentsPath, &contents) == 0, (contents.st_mode & S_IFMT) == S_IFDIR,
              lstat(contentsPath + "/Info.plist", &info) == 0 else { return "\(bundle.st_dev):\(bundle.st_ino)" }
        return "\(bundle.st_dev):\(bundle.st_ino):\(contents.st_ino):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// Reads the app at `url` in this process. As root, use `AppScanner.inspect` for bundles that
    /// a user owns. `deep` validates the whole signature, nested code included, which takes a
    /// while for big apps; without it only what the signature claims is read.
    public static func inspect(_ url: URL, deep: Bool = false) throws -> InstalledApp {
        let bundle = try AppBundle(url: url)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw BarkeepError(.appNotFound, "Cannot inspect \(url.path)") }
        var app = InstalledApp(path: url.path, name: url.lastPathComponent, bundleIdentifier: bundle.bundleIdentifier,
                               shortVersion: bundle.shortVersion, buildVersion: bundle.buildVersion, ownerUID: st.st_uid,
                               signing: nil, signatureProblem: nil, designatedRequirement: nil,
                               metadata: UpdateMetadata.read(from: url, info: bundle.info))
        guard !app.isApple else { return app }
        let claimed = CodeSignature.claimedIdentity(of: url)
        app.claimedTeamID = claimed.teamID
        app.designatedRequirement = claimed.designatedRequirement
        if deep {
            app.signatureChecked = true
            do {
                app.signing = try CodeSignature.inspect(url)
            } catch let error as BarkeepError {
                app.signatureProblem = error.message
                app.designatedRequirement = nil
            }
        }
        return app
    }
}

/// Update hints found inside an app bundle.
public struct UpdateMetadata: Codable, Sendable, Equatable {
    /// Sparkle: `SUFeedURL` in Info.plist.
    public var sparkleFeedURL: String?
    /// Sparkle: `SUPublicEDKey`, the base64 Ed25519 key that signs the app's updates.
    public var sparklePublicEDKey: String?
    /// Sparkle's framework is in the bundle, even if the feed URL is set at run time.
    public var hasSparkleFramework = false
    /// electron-builder's `Contents/Resources/app-update.yml`, parsed.
    public var electronUpdate: [String: String]?
    /// VS Code style `Contents/Resources/app/product.json`: `updateUrl`, `quality`, `commit`.
    public var productUpdateURL: String?
    public var productQuality: String?
    public var productCommit: String?
    /// `Contents/_MASReceipt/receipt`: installed from the Mac App Store.
    public var hasAppStoreReceipt = false
    /// The vendor's own updater, if the app is known to use one barkeep does not drive.
    public var vendorUpdater: String?
    /// The bundle's executable is arm64 only, x86_64 only or both.
    public var architectures: [String] = []

    public init() {}

    static let maxMetadataFileSize = 1024 * 1024

    /// Vendors whose own updaters look after their apps, which barkeep reports but leaves alone.
    public static func vendorUpdater(for bundleID: String) -> String? {
        let id = bundleID.lowercased()
        if id.hasPrefix("com.microsoft.") && !id.hasPrefix("com.microsoft.vscode") { return "Microsoft AutoUpdate" }
        if id.hasPrefix("com.adobe.") { return "Adobe Creative Cloud" }
        return nil
    }

    static func read(from bundle: URL, info: [String: Any]) -> UpdateMetadata {
        var m = UpdateMetadata()
        m.sparkleFeedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        m.sparklePublicEDKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        m.hasSparkleFramework = AppBundle.exists(["Contents", "Frameworks", "Sparkle.framework"], in: bundle)
        if let data = AppBundle.readFile(["Contents", "Resources", "app-update.yml"], in: bundle, maxSize: maxMetadataFileSize) {
            m.electronUpdate = SimpleYAML.parseFlat(String(decoding: data, as: UTF8.self))
        }
        if let data = AppBundle.readFile(["Contents", "Resources", "app", "product.json"], in: bundle, maxSize: 4 * maxMetadataFileSize),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            m.productUpdateURL = json["updateUrl"] as? String
            m.productQuality = json["quality"] as? String
            m.productCommit = json["commit"] as? String
        }
        m.hasAppStoreReceipt = AppBundle.exists(["Contents", "_MASReceipt", "receipt"], in: bundle)
        m.vendorUpdater = vendorUpdater(for: info["CFBundleIdentifier"] as? String ?? "")
        if let executable = info["CFBundleExecutable"] as? String {
            m.architectures = MachO.architectures(of: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
        }
        return m
    }
}

/// Just enough YAML for electron-builder's files: `key: value` lines and, for `latest-mac.yml`,
/// the `files:` list of `- url:` entries.
public enum SimpleYAML {
    public static func parseFlat(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix(" "), !line.hasPrefix("-"), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// The entries of the top-level `files:` list, each as a flat dictionary.
    public static func parseFiles(_ text: String) -> [[String: String]] {
        var files: [[String: String]] = []
        var inFiles = false
        var current: [String: String]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.hasPrefix("-") {
                if let current { files.append(current) }
                current = nil
                inFiles = line.trimmingCharacters(in: .whitespaces) == "files:"
                continue
            }
            guard inFiles else { continue }
            var body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("- ") {
                if let current { files.append(current) }
                current = [:]
                body = String(body.dropFirst(2))
            }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquote(body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            current?[key] = value
        }
        if let current { files.append(current) }
        return files
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Reads the architectures of a Mach-O file from its header.
enum MachO {
    static func architectures(of url: URL) -> [String] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return [] }
        var header = [UInt8](repeating: 0, count: 4096)
        let count = header.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count >= 8 else { return [] }
        func be32(_ o: Int) -> UInt32 { header[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ o: Int) -> UInt32 { header[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func name(_ cpu: UInt32) -> String? {
            switch cpu {
            case 0x0100000C: "arm64"
            case 0x01000007: "x86_64"
            default: nil
            }
        }
        switch be32(0) {
        case 0xCAFEBABE, 0xCAFEBABF:
            let n = Int(be32(4))
            let stride = be32(0) == 0xCAFEBABF ? 32 : 20
            return (0..<min(n, 8)).compactMap { i in
                let o = 8 + i * stride
                return o + 4 <= count ? name(be32(o)) : nil
            }
        default:
            let magic = le32(0)
            guard magic == 0xFEEDFACF || magic == 0xFEEDFACE else { return [] }
            return name(le32(4)).map { [$0] } ?? []
        }
    }
}

extension AppBundle {
    /// Whether `components` exist below `bundle`, without following symlinks.
    static func exists(_ components: [String], in bundle: URL) -> Bool {
        let fd = openWithoutSymlinks(components, in: bundle, flags: O_RDONLY | O_NONBLOCK)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// A regular file below `bundle`, read without following symlinks, or nil if it is missing,
    /// not a regular file or larger than `maxSize`.
    static func readFile(_ components: [String], in bundle: URL, maxSize: Int) -> Data? {
        let fd = openWithoutSymlinks(components, in: bundle, flags: O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxSize else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { return nil }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            if data.count > maxSize { return nil }
        }
        return data
    }
}
