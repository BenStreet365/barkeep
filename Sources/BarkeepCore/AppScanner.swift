import Darwin
import Foundation

/// Finds apps in the scan folders: `/Applications` and every user's `~/Applications` by default,
/// plus one level of subfolders (`/Applications/Utilities`, `/Applications/Microsoft Office`).
/// Symlinks are never followed and apps inside other apps are not counted.
public struct AppScanner {
    public let config: Configuration
    public let log: Log
    public var isRoot = geteuid() == 0
    /// The barkeep binary, re-run as a bundle's owner to inspect apps that are not root's.
    public var helperExecutable: String?
    /// Homes that `~` expands to. Defaults to every local account (as root) or the current user.
    public var homes: [URL]?

    /// Barkeep.app updates with barkeep itself (SelfUpdater), so it is never listed as an app.
    public static let ownBundleIdentifier = "uk.street365.barkeep.app"
    static let inspectTimeout: TimeInterval = 600
    static let maxDepth = 2

    public init(config: Configuration, log: Log) {
        self.config = config
        self.log = log
    }

    /// The folders to search, with `~` expanded, de-duplicated, in order.
    public func folders() -> [URL] {
        let homes = homes ?? defaultHomes()
        var seen = Set<String>()
        var result: [URL] = []
        for raw in config.scanPaths {
            let expanded: [String]
            if raw == "~" || raw.hasPrefix("~/") {
                expanded = homes.map { $0.path + raw.dropFirst() }
            } else {
                expanded = [raw]
            }
            for path in expanded {
                let standard = URL(fileURLWithPath: path).standardizedFileURL.path
                if seen.insert(standard).inserted { result.append(URL(fileURLWithPath: standard, isDirectory: true)) }
            }
        }
        return result
    }

    func defaultHomes() -> [URL] {
        if isRoot { return ((try? TargetUser.localAccounts()) ?? []).map(\.home) }
        return [FileManager.default.homeDirectoryForCurrentUser]
    }

    /// App bundles in the scan folders.
    public func bundles() -> [URL] {
        var result: [URL] = []
        for folder in folders() {
            collect(folder, depth: 1, into: &result)
        }
        return result
    }

    private func collect(_ folder: URL, depth: Int, into result: inout [URL]) {
        var st = stat()
        guard lstat(folder.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name, isDirectory: true)
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            if url.pathExtension.lowercased() == "app" {
                result.append(url)
            } else if depth < Self.maxDepth, !["localized", "bundle", "framework", "plugin"].contains(url.pathExtension.lowercased()) {
                collect(url, depth: depth + 1, into: &result)
            }
        }
    }

    /// Every app found, inspected, except Barkeep.app. Apps that cannot be read are logged and left out.
    public func scan() -> [InstalledApp] {
        bundles().compactMap { url in
            do {
                let app = try inspect(url)
                return app.bundleIdentifier == Self.ownBundleIdentifier ? nil : app
            } catch {
                log.debug("Skipping \(url.path): \(error)")
                return nil
            }
        }
    }

    /// Inspects one app. As root, an app owned by someone else is read by a helper running as
    /// its owner, with a time limit, so a booby-trapped bundle (a FIFO in place of Info.plist,
    /// a symlink to a root-only file) cannot hang barkeep or show it anything the owner can't see.
    public func inspect(_ url: URL, deep: Bool = false) throws -> InstalledApp {
        let fingerprint = InstalledApp.fingerprint(of: url)
        var app = try inspectContents(url, deep: deep)
        app.fingerprint = fingerprint
        return app
    }

    /// Apps already known, re-read only where their fingerprint changed. Apps that are gone are left out.
    public func refresh(_ known: [InstalledApp]) -> [InstalledApp] {
        known.compactMap { app in
            let now = InstalledApp.fingerprint(of: app.url)
            guard now != nil, app.bundleIdentifier != Self.ownBundleIdentifier else { return nil }
            guard now != app.fingerprint else { return app }
            log.debug("\(app.path) changed on disk; reading it again")
            return (try? inspect(app.url)).flatMap { $0.bundleIdentifier == Self.ownBundleIdentifier ? nil : $0 }
        }
    }

    func inspectContents(_ url: URL, deep: Bool) throws -> InstalledApp {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw BarkeepError(.appNotFound, "\(url.path) is not an app bundle")
        }
        guard isRoot, st.st_uid != 0 else { return try InstalledApp.inspect(url, deep: deep) }
        guard let helper = helperExecutable else { throw BarkeepError(.failure, "No helper to inspect \(url.path)") }
        let result = try Command.run(helper, ["_inspect", url.path, "--uid", String(st.st_uid)] + (deep ? ["--deep"] : []), timeout: Self.inspectTimeout)
        guard !result.timedOut else {
            throw BarkeepError(.destinationConflict, "Inspecting \(url.path) took longer than \(Int(Self.inspectTimeout))s")
        }
        guard result.status == 0 else {
            throw BarkeepError(.failure, "Cannot inspect \(url.path): \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        do {
            var app = try JSONDecoder().decode(InstalledApp.self, from: result.stdout)
            // The helper reports what it read; where it was is ours to say.
            app.path = url.path
            app.ownerUID = st.st_uid
            return app
        } catch {
            throw BarkeepError(.failure, "Cannot read the inspection of \(url.path): \(error.localizedDescription)")
        }
    }
}
