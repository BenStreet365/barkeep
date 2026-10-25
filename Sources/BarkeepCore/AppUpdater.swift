import Darwin
import Foundation

public struct UpdateOutcome: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable { case updated, deferredRunning, failed }
    public var result: Result
    public var exitCode: Int32
    public var message: String
    public var newVersion: String?
}

/// Downloads, verifies and installs one update. The new copy must be the same app, from the
/// same developer, and newer:
///
/// 1. HTTPS only, size-limited, and the download must match any checksum or Sparkle EdDSA
///    signature in the feed (an app with `SUPublicEDKey` must have a valid signature).
/// 2. The archive must hold exactly one app with the installed app's bundle ID.
/// 3. That app is copied next to the installed one, and every check runs on that copy: a valid,
///    strict code signature; the installed copy's designated requirement; the same Apple-verified
///    Team ID (and the source's expected one, and `AllowedTeamIdentifiers`); Gatekeeper; a newer
///    version; a macOS and architecture this Mac can run.
/// 4. While a short lease stops the app being opened, it is swapped in atomically, so the app is
///    never half-updated. A package is checked the same way (installer team, Gatekeeper) and the
///    app it installs is checked afterwards.
public final class AppUpdater {
    public let config: Configuration
    public let log: Log
    public var effectiveUID: uid_t = geteuid()
    /// The barkeep binary, re-run as a user to delete the old copy of an app they own.
    public var helperExecutable: String?
    public var registersWithLaunchServices = true
    /// Root-owned folder for leases. Tests use their own.
    public var leaseDirectory = UpdateLease.directory
    public var systemVersion = ProcessInfo.processInfo.operatingSystemVersion

    static let installerTimeout: TimeInterval = 1800
    static let removeTimeout: TimeInterval = 300

    public init(config: Configuration, log: Log) {
        self.config = config
        self.log = log
    }

    var isRoot: Bool { effectiveUID == 0 }

    /// The one person who may see the lease on `app`: the owner of the home folder it is in.
    func leaseReader(_ app: InstalledApp) -> uid_t? {
        isRoot ? Visibility.local().owner(of: app.path)?.uid : nil
    }

    public func update(_ app: InstalledApp, to update: AvailableUpdate, source: ResolvedSource) -> UpdateOutcome {
        do {
            let version = try perform(app, update, source)
            return UpdateOutcome(result: .updated, exitCode: 0,
                                 message: "Updated \(app.name) from \(app.displayVersion) to \(version) at \(app.path)", newVersion: version)
        } catch let error as BarkeepError where error.status == .appRunning {
            return UpdateOutcome(result: .deferredRunning, exitCode: error.status.rawValue, message: error.message)
        } catch let error as BarkeepError {
            return UpdateOutcome(result: .failed, exitCode: error.status.rawValue, message: error.message)
        } catch {
            return UpdateOutcome(result: .failed, exitCode: ExitStatus.installFailed.rawValue, message: error.localizedDescription)
        }
    }

    func perform(_ app: InstalledApp, _ update: AvailableUpdate, _ source: ResolvedSource) throws -> String {
        guard source.definition.kind.installs, let raw = update.downloadURL, let url = URL(string: raw) else {
            throw BarkeepError(.noUpdateSource, "\(app.name) is updated by \(source.definition.note ?? source.definition.kind.rawValue), not barkeep")
        }
        guard url.scheme == "https" || (url.isFileURL && config.allowFileURLs) else {
            throw BarkeepError(.feedError, "Refusing to download \(raw): not HTTPS")
        }
        try checkInstalledIdentity(app, source: source.definition)

        let work = try Self.makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let download = work.appendingPathComponent("download")
        log.info("Downloading \(app.name) \(update.displayVersion) from \(raw)")
        try HTTPClient.download(url, to: download, maxBytes: Int64(config.maximumDownloadSizeMB) * 1024 * 1024,
                                allowFile: config.allowFileURLs)
        try verifyDownload(download, update: update, app: app)

        guard let kind = ArchiveKind.detect(download) else {
            throw BarkeepError(.archiveError, "The download from \(raw) is not a zip, disk image, package or tar archive")
        }
        switch kind {
        case .package:
            // installer only accepts a path ending in .pkg.
            let package = work.appendingPathComponent("update.pkg")
            try FileManager.default.moveItem(at: download, to: package)
            return try installPackage(package, app: app, update: update, source: source.definition)
        case .diskImage:
            try DiskImage.preflight(download.path, acceptLicense: true)
            let image = try DiskImage(attaching: download.path, log: log)
            defer { image.detach() }
            let found = try Archive.findApp(bundleID: app.bundleIdentifier, in: image.volumes)
            return try installApp(found, replacing: app, source: source.definition)
        case .zip, .tar:
            let extracted = work.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Archive.extract(download, kind: kind, into: extracted)
            let found = try Archive.findApp(bundleID: app.bundleIdentifier, in: [extracted])
            return try installApp(found, replacing: app, source: source.definition)
        }
    }

    // MARK: Identity

    /// The installed copy is what new copies are judged against, so it must have a signature that
    /// says who made it. An unsigned or tampered copy can only be updated from a source that names
    /// the Team ID to expect (the catalog or the profile).
    func checkInstalledIdentity(_ app: InstalledApp, source: AppSourceDefinition) throws {
        if app.signing == nil || app.designatedRequirement == nil, source.expectedTeamIdentifier == nil {
            throw BarkeepError(.invalidSignature,
                               "The installed \(app.name) has no valid signature (\(app.signatureProblem ?? "unknown problem")), so an update cannot be matched to it; add ExpectedTeamIdentifier for it in AppSources")
        }
        if let expected = source.expectedTeamIdentifier, let team = app.signing?.teamID,
           expected.caseInsensitiveCompare(team) != .orderedSame {
            throw BarkeepError(.teamMismatch, "The installed \(app.name) is signed by team \(team), not the expected \(expected)")
        }
    }

    func verifyDownload(_ file: URL, update: AvailableUpdate, app: InstalledApp) throws {
        let digests = try Archive.digests(of: file)
        var verified: [String] = []
        if let expected = update.sha256 {
            guard digests.sha256 == expected.lowercased() else {
                throw BarkeepError(.checksumMismatch, "The download of \(app.name) does not match its published SHA-256")
            }
            verified.append("SHA-256")
        }
        if let expected = update.sha512 {
            guard digests.sha512 == expected else {
                throw BarkeepError(.checksumMismatch, "The download of \(app.name) does not match its published SHA-512")
            }
            verified.append("SHA-512")
        }
        // Like Sparkle itself: an app that has an EdDSA key only accepts updates signed with it.
        if let key = app.metadata.sparklePublicEDKey, !key.isEmpty, update.build != nil {
            guard let signature = update.edSignature else {
                throw BarkeepError(.checksumMismatch, "The appcast has no EdDSA signature for \(app.name) \(update.displayVersion), but the app requires one")
            }
            guard try Archive.verifyEdDSA(file: file, signature: signature, publicKey: key) else {
                throw BarkeepError(.checksumMismatch, "The download of \(app.name) does not match the EdDSA signature in its appcast")
            }
            verified.append("EdDSA")
        }
        log.info("Downloaded \(app.name): sha256 \(digests.sha256)\(verified.isEmpty ? "" : ", matches the feed's \(verified.joined(separator: " and "))")")
    }

    /// The checks a new copy must pass to replace `app`. `candidate` must be a copy only root (or
    /// barkeep's user) can change, so what is checked is what gets installed.
    func verifyCandidate(_ candidate: URL, replacing app: InstalledApp, source: AppSourceDefinition) throws -> (AppBundle, SigningInfo) {
        let bundle = try AppBundle(url: candidate)
        guard bundle.bundleIdentifier == app.bundleIdentifier else {
            throw BarkeepError(.bundleIDMismatch, "The update has bundle ID \(bundle.bundleIdentifier), not \(app.bundleIdentifier)")
        }
        let signing = try CodeSignature.inspect(candidate)
        let unverified = config.allowUnverifiedSignatures
        if signing.isAdHoc && !unverified {
            throw BarkeepError(.invalidSignature, "The update of \(app.name) is only ad-hoc signed")
        }
        if signing.teamID == nil && !unverified {
            throw BarkeepError(.invalidSignature, "The update of \(app.name) is not signed with a certificate issued by Apple")
        }
        // Who made it: the same team as the installed copy, and as the source expects.
        if let installedTeam = app.signing?.teamID, signing.teamID?.caseInsensitiveCompare(installedTeam) != .orderedSame {
            throw BarkeepError(.teamMismatch, "The update of \(app.name) is signed by team \(signing.teamID ?? signing.unverifiedTeamID ?? "none"), not \(installedTeam) like the installed copy")
        }
        if let expected = source.expectedTeamIdentifier, signing.teamID?.caseInsensitiveCompare(expected) != .orderedSame {
            throw BarkeepError(.teamMismatch, "The update of \(app.name) is signed by team \(signing.teamID ?? "none"), not the expected \(expected)")
        }
        guard config.isTeamAllowed(signing.teamID) else {
            throw BarkeepError(.teamMismatch, "Team \(signing.teamID ?? "none") is not in AllowedTeamIdentifiers")
        }
        // The same app: the rule the installed copy's signature sets for its successors.
        if let requirement = app.designatedRequirement {
            guard CodeSignature.satisfies(candidate, requirement: requirement) else {
                throw BarkeepError(.teamMismatch, "The update of \(app.name) does not satisfy the installed copy's designated requirement (\(requirement))")
            }
        }
        if config.requireGatekeeperAssessment {
            try Gatekeeper.assess(candidate)
        } else {
            log.info("Gatekeeper assessment is disabled by configuration")
        }
        switch AppBundle.compareVersions(short: (bundle.shortVersion, app.shortVersion), build: (bundle.buildVersion, app.buildVersion)) {
        case .orderedDescending?: break
        default:
            throw BarkeepError(.notNewer, "The download contains \(app.name) \(bundle.displayVersion), which is not newer than \(app.displayVersion)")
        }
        if let minimum = bundle.info["LSMinimumSystemVersion"] as? String,
           !UpdateFinder.systemSatisfies(minimum, systemVersion) {
            throw BarkeepError(.archiveError, "\(app.name) \(bundle.displayVersion) needs macOS \(minimum)")
        }
        let architectures = MachO.architectures(of: bundle.executableURL)
        if !architectures.isEmpty, !architectures.contains("arm64"), app.metadata.architectures.contains("arm64") {
            throw BarkeepError(.archiveError, "\(app.name) \(bundle.displayVersion) is not built for Apple silicon, unlike the installed copy")
        }
        log.info("Verified \(app.name) \(bundle.displayVersion): team \(signing.teamID ?? "none"), designated requirement satisfied, cdhash \(signing.cdHash ?? "none")")
        return (bundle, signing)
    }

    // MARK: Apps

    func installApp(_ found: URL, replacing app: InstalledApp, source: AppSourceDefinition) throws -> String {
        let destination = app.url
        let parent = destination.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw BarkeepError(.destinationConflict, "\(parent.path) is not a folder")
        }
        let staging = try makeStagingDirectory(near: parent)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try copy(found, to: staged)
        let (bundle, _) = try verifyCandidate(staged, replacing: app, source: source)
        try setOwnership(of: staged, like: destination)

        let lease = try? UpdateLease.acquire(for: app, directory: leaseDirectory, privateTo: leaseReader(app))
        defer { lease?.release(directory: leaseDirectory) }
        let pids = RunningProcesses.pids(inside: destination)
        guard pids.isEmpty else {
            throw BarkeepError(.appRunning, "\(app.name) is running (pid \(pids.map(String.init).joined(separator: ", "))); will retry when it quits")
        }
        try swapIntoPlace(staging: staging, parent: parent, name: destination.lastPathComponent, owner: app.ownerUID)
        registerWithLaunchServices(destination)
        return bundle.displayVersion
    }

    // MARK: Packages

    func installPackage(_ package: URL, app: InstalledApp, update: AvailableUpdate, source: AppSourceDefinition) throws -> String {
        guard config.allowPackageInstallers else {
            throw BarkeepError(.archiveError, "The update of \(app.name) is an installer package, and AllowPackageInstallers is off")
        }
        guard isRoot else { throw BarkeepError(.notAuthorized, "Installer packages can only be installed by root") }
        guard app.path.hasPrefix("/Applications/") else {
            throw BarkeepError(.destinationConflict, "\(app.name) is in \(app.url.deletingLastPathComponent().path), but its update is an installer package, which installs into /Applications")
        }
        guard let team = try Gatekeeper.packageTeamID(package) else {
            throw BarkeepError(.invalidSignature, "The update of \(app.name) is not a package signed with a Developer ID Installer certificate")
        }
        let expected = source.expectedTeamIdentifier ?? app.signing?.teamID
        guard let expected, team.caseInsensitiveCompare(expected) == .orderedSame else {
            throw BarkeepError(.teamMismatch, "The package for \(app.name) is signed by team \(team), not \(expected ?? "the app's team")")
        }
        guard config.isTeamAllowed(team) else { throw BarkeepError(.teamMismatch, "Team \(team) is not in AllowedTeamIdentifiers") }
        if config.requireGatekeeperAssessment { try Gatekeeper.assess(package, type: "install") }

        let lease = try? UpdateLease.acquire(for: app, directory: leaseDirectory, privateTo: leaseReader(app))
        defer { lease?.release(directory: leaseDirectory) }
        let pids = RunningProcesses.pids(inside: app.url)
        guard pids.isEmpty else {
            throw BarkeepError(.appRunning, "\(app.name) is running (pid \(pids.map(String.init).joined(separator: ", "))); will retry when it quits")
        }
        log.info("Installing the package for \(app.name) (signed by team \(team))")
        let result = try Command.run("/usr/sbin/installer", ["-pkg", package.path, "-target", "/"], timeout: Self.installerTimeout)
        guard result.status == 0, !result.timedOut else {
            let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BarkeepError(.installFailed, "installer could not install the update of \(app.name): \(result.timedOut ? "timed out" : detail)")
        }
        // The package has run; check that what it left is still the same app, and newer.
        let after = try InstalledApp.inspect(app.url)
        let sameApp = app.designatedRequirement.map { CodeSignature.satisfies(app.url, requirement: $0) }
            ?? (CodeSignature.claimedIdentity(of: app.url).teamID == expected)
        guard after.bundleIdentifier == app.bundleIdentifier, sameApp else {
            throw BarkeepError(.teamMismatch, "After installing its package, \(app.name) is not signed like the copy it replaced")
        }
        guard AppBundle.compareVersions(short: (after.shortVersion, app.shortVersion), build: (after.buildVersion, app.buildVersion)) == .orderedDescending else {
            throw BarkeepError(.notNewer, "The package for \(app.name) installed \(after.displayVersion), which is not newer than \(app.displayVersion)")
        }
        return after.displayVersion
    }

    // MARK: Filesystem

    static func makePrivateDirectory() throws -> URL {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("barkeep-update.XXXXXX").path.utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw BarkeepError(.installFailed, "Cannot create a download folder: \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// A private folder on the same volume as `parent`, so the final rename is atomic. As root it
    /// is root-owned and outside any user's control.
    func makeStagingDirectory(near parent: URL) throws -> URL {
        let base = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: parent, create: true)
        var st = stat()
        guard lstat(base.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == effectiveUID else {
            throw BarkeepError(.installFailed, "Staging folder \(base.path) is not safe to use")
        }
        chmod(base.path, 0o700)
        if isRoot, let problem = PathSafety.problem(with: base.path) {
            rmdir(base.path) // Never a recursive delete in a folder someone else controls.
            throw BarkeepError(.installFailed, "Staging folder \(base.path) is not safe to use: \(problem)")
        }
        return base
    }

    func copy(_ source: URL, to destination: URL) throws {
        // --noacl: vendor ACLs would stop the owner updating or removing the app later.
        let result = try Command.run("/usr/bin/ditto", ["--noqtn", "--noacl", source.path, destination.path], timeout: 1800)
        guard result.status == 0, !result.timedOut else {
            throw BarkeepError(.installFailed, "Copy failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // The app is verified before it is installed, so it should open without the
        // "downloaded from the internet" prompt, as an app updated by its own updater does.
        var paths = [destination.path]
        if let enumerator = FileManager.default.enumerator(atPath: destination.path) {
            while let relative = enumerator.nextObject() as? String { paths.append(destination.appendingPathComponent(relative).path) }
        }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    /// Gives the new copy the installed copy's owner and group, with nothing writable by others
    /// and no setuid bits. Modes are not part of the code signature.
    func setOwnership(of staged: URL, like destination: URL) throws {
        var st = stat()
        guard lstat(destination.path, &st) == 0 else { return }
        let chmod = try Command.run("/bin/chmod", ["-R", "o-w,ug-s", staged.path])
        guard chmod.status == 0 else { throw BarkeepError(.installFailed, "chmod failed: \(chmod.stderrString)") }
        guard isRoot else { return }
        let chown = try Command.run("/usr/sbin/chown", ["-R", "-h", "\(st.st_uid):\(st.st_gid)", staged.path])
        guard chown.status == 0 else { throw BarkeepError(.installFailed, "chown failed: \(chown.stderrString)") }
    }

    /// Swaps the staged app with the installed one through folder descriptors opened with
    /// O_NOFOLLOW, so nobody can redirect root's write by swapping in symlinks. The old copy lands
    /// in staging and is deleted.
    func swapIntoPlace(staging: URL, parent: URL, name: String, owner: uid_t) throws {
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else {
            throw BarkeepError(.destinationConflict, "Cannot open \(parent.path): \(String(cString: strerror(errno)))")
        }
        defer { close(parentFD) }
        let stageFD = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else { throw BarkeepError(.installFailed, "Cannot open the staging folder: \(String(cString: strerror(errno)))") }
        defer { close(stageFD) }

        if renameatx_np(stageFD, name, parentFD, name, UInt32(RENAME_SWAP)) != 0 {
            let err = errno
            if err == EPERM || err == EACCES {
                // App Management (TCC) protects signed app bundles, even from root.
                throw BarkeepError(.appManagementDenied,
                                   "macOS blocked replacing \(name). Deploy the App Management (SystemPolicyAppBundles) profile for barkeep")
            }
            if err == ENOENT { throw BarkeepError(.appNotFound, "\(name) was removed from \(parent.path) during the update") }
            throw BarkeepError(.installFailed, "Cannot move \(name) into place: \(String(cString: strerror(err)))")
        }
        removeOldCopy(stageFD: stageFD, parentFD: parentFD, parent: parent, name: name, owner: owner)
    }

    /// The swap left the previous copy in staging. If a user owns it, they may hold a descriptor
    /// inside it and swap in symlinks while it is deleted, so root moves it back beside the new
    /// copy under a hidden name and deletes it as that user.
    func removeOldCopy(stageFD: Int32, parentFD: Int32, parent: URL, name: String, owner: uid_t) {
        guard isRoot, owner != 0 else { return } // Deleted with the staging folder.
        let trashName = ".\(name).barkeep-old-\(UUID().uuidString)"
        guard renameatx_np(stageFD, name, parentFD, trashName, UInt32(RENAME_EXCL)) == 0 else {
            log.warning("Cannot move the previous copy of \(name) out of staging: \(String(cString: strerror(errno)))")
            return
        }
        let trash = parent.appendingPathComponent(trashName)
        if let helper = helperExecutable,
           let result = try? Command.run(helper, ["_remove", trash.path, "--uid", String(owner)], timeout: Self.removeTimeout),
           result.status == 0, !result.timedOut {
            return
        }
        log.warning("Could not delete the previous copy of \(name); it was left at \(trash.path)")
    }

    func registerWithLaunchServices(_ app: URL) {
        guard registersWithLaunchServices else { return }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if isRoot, let user = TargetUser.consoleUser() {
            _ = try? Command.run("/bin/launchctl", ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-u", user.name, lsregister, "-f", app.path], timeout: 60)
        } else {
            _ = try? Command.run(lsregister, ["-f", app.path], timeout: 60)
        }
    }
}

/// Serialises updates so two runs cannot race on the same app.
public final class UpdateLock {
    private var fd: Int32
    static let rootPath = "/private/var/run/\(Configuration.domain).lock"

    public init(timeout: TimeInterval) throws {
        let path = geteuid() == 0 ? Self.rootPath
                                  : FileManager.default.temporaryDirectory.appendingPathComponent("\(Configuration.domain).lock").path
        fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BarkeepError(.installFailed, "Cannot open lock file \(path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                close(fd)
                throw BarkeepError(.installFailed, "Cannot lock \(path): \(String(cString: strerror(errno)))")
            }
            guard Date() < deadline else {
                close(fd)
                throw BarkeepError(.busy, "Another barkeep run is updating apps; try again later")
            }
            usleep(500_000)
        }
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
