import XCTest
@testable import BarkeepCore

/// Real updates of fixture apps, without root: download (from file URLs), verification and the
/// atomic swap. What only root does (helpers that drop to a user, installer packages, the
/// daemon) is covered by the VM tests in docs/DEVELOPMENT.md.
final class UpdateTests: XCTestCase {
    var fixtures: Fixtures!
    var applications: URL!
    var leases: URL!
    let id = "uk.street365.barkeep.test"

    override func setUpWithError() throws {
        fixtures = try Fixtures()
        applications = try fixtures.folder("Applications")
        leases = try fixtures.folder("Leases")
    }

    func makeUpdater(_ config: Configuration = Fixtures.testConfiguration()) -> AppUpdater {
        let updater = AppUpdater(config: config, log: Fixtures.quietLog())
        updater.registersWithLaunchServices = false
        updater.leaseDirectory = leases.path
        return updater
    }

    func installed(version: String = "1.0", extraInfo: [String: Any] = [:], executable: String = "/usr/bin/true") throws -> InstalledApp {
        let url = try fixtures.makeApp(in: applications, bundleID: id, version: version, extraInfo: extraInfo, executable: executable)
        return try InstalledApp.inspect(url, deep: true)
    }

    /// A zip of a new version, built elsewhere, and the update pointing at it.
    func published(version: String, bundleID: String? = nil, signingIdentifier: String? = nil, folder: String? = nil) throws -> (AvailableUpdate, URL) {
        let build = try fixtures.folder(folder ?? "build-\(version)-\(UUID().uuidString)")
        let app = try fixtures.makeApp(in: build, bundleID: bundleID ?? id, version: version, signingIdentifier: signingIdentifier)
        let zip = try fixtures.zip(app, as: "Test-\(version)-\(UUID().uuidString).zip")
        return (AvailableUpdate(version: version, downloadURL: zip.absoluteString), zip)
    }

    let source = ResolvedSource(definition: AppSourceDefinition(bundleIdentifier: "uk.street365.barkeep.test", kind: .json,
                                                                feedURL: "file:///unused", versionPath: "v", downloadURL: "file:///unused"),
                                origin: .profile, evidence: "test")

    func testUpdatesInPlace() throws {
        let app = try installed()
        XCTAssertEqual(app.designatedRequirement, #"identifier "uk.street365.barkeep.test""#)
        let (update, _) = try published(version: "2.0")
        let outcome = makeUpdater().update(app, to: update, source: source)
        XCTAssertEqual(outcome.result, .updated, outcome.message)
        XCTAssertEqual(try AppBundle(url: app.url).shortVersion, "2.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        XCTAssertEqual(leftovers, ["Test.app"], "the old copy and staging are gone")
        XCTAssertTrue(UpdateLease.live(directory: leases.path, requireRootOwnership: false).isEmpty, "the lease is released")
    }

    func testRefusesAnotherAppWithTheSameName() throws {
        let app = try installed()
        let (update, _) = try published(version: "2.0", bundleID: "com.example.other")
        let outcome = makeUpdater().update(app, to: update, source: source)
        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(outcome.exitCode, ExitStatus.bundleIDMismatch.rawValue, outcome.message)
        XCTAssertEqual(try AppBundle(url: app.url).shortVersion, "1.0", "nothing changed")
    }

    func testRefusesAFakeUpdateThatIsNotSignedLikeTheInstalledCopy() throws {
        let app = try installed()
        // Same bundle ID and a higher version, but signed by "someone else".
        let (update, _) = try published(version: "9.9", signingIdentifier: "com.example.impostor")
        let outcome = makeUpdater().update(app, to: update, source: source)
        XCTAssertEqual(outcome.exitCode, ExitStatus.teamMismatch.rawValue, outcome.message)
        XCTAssertTrue(outcome.message.contains("designated requirement"), outcome.message)
        XCTAssertEqual(try AppBundle(url: app.url).shortVersion, "1.0")
    }

    func testRefusesAdHocSignaturesUnlessTesting() throws {
        let app = try installed()
        let (update, _) = try published(version: "2.0")
        var strict = Fixtures.testConfiguration()
        strict.allowUnverifiedSignatures = false
        let outcome = makeUpdater(strict).update(app, to: update, source: source)
        XCTAssertEqual(outcome.exitCode, ExitStatus.invalidSignature.rawValue, outcome.message)
    }

    func testRefusesDowngradesAndSameVersion() throws {
        let app = try installed(version: "3.0")
        let (older, _) = try published(version: "2.0")
        XCTAssertEqual(makeUpdater().update(app, to: older, source: source).exitCode, ExitStatus.notNewer.rawValue)
        let (same, _) = try published(version: "3.0")
        XCTAssertEqual(makeUpdater().update(app, to: same, source: source).exitCode, ExitStatus.notNewer.rawValue)
    }

    func testRefusesADownloadThatDoesNotMatchTheFeedChecksum() throws {
        let app = try installed()
        var (update, _) = try published(version: "2.0")
        update.sha256 = String(repeating: "0", count: 64)
        XCTAssertEqual(makeUpdater().update(app, to: update, source: source).exitCode, ExitStatus.checksumMismatch.rawValue)
    }

    func testAcceptsAMatchingChecksum() throws {
        let app = try installed()
        var (update, zip) = try published(version: "2.0")
        update.sha256 = try Archive.digests(of: zip).sha256
        update.sha512 = try Archive.digests(of: zip).sha512
        XCTAssertEqual(makeUpdater().update(app, to: update, source: source).result, .updated)
    }

    func testSparkleAppsNeedAnEdDSASignature() throws {
        let app = try installed(extraInfo: ["SUPublicEDKey": "c29tZSBrZXkgdGhhdCBpcyAzMiBieXRlcyBsb25nISE="])
        var (update, _) = try published(version: "2.0")
        update.build = "2.0" // From a Sparkle feed
        let outcome = makeUpdater().update(app, to: update, source: source)
        XCTAssertEqual(outcome.exitCode, ExitStatus.checksumMismatch.rawValue, outcome.message)
        XCTAssertTrue(outcome.message.contains("EdDSA"), outcome.message)
    }

    func testWaitsForARunningApp() throws {
        let app = try installed(executable: "/bin/sleep")
        let process = Process()
        process.executableURL = app.url.appendingPathComponent("Contents/MacOS/Test")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let (update, _) = try published(version: "2.0")
        let outcome = makeUpdater().update(app, to: update, source: source)
        XCTAssertEqual(outcome.result, .deferredRunning, outcome.message)
        XCTAssertEqual(try AppBundle(url: app.url).shortVersion, "1.0")
    }

    func testRefusesAnUnsignedInstalledAppWithoutAnExpectedTeam() throws {
        let url = try fixtures.makeApp(in: applications, bundleID: id, version: "1.0", sign: false)
        let app = try InstalledApp.inspect(url, deep: true)
        let (update, _) = try published(version: "2.0")
        XCTAssertEqual(makeUpdater().update(app, to: update, source: source).exitCode, ExitStatus.invalidSignature.rawValue)
    }

    func testNonHTTPSDownloadsAreRefused() throws {
        let app = try installed()
        let update = AvailableUpdate(version: "2.0", downloadURL: "http://example.com/Test.zip")
        XCTAssertEqual(makeUpdater().update(app, to: update, source: source).exitCode, ExitStatus.feedError.rawValue)
    }

    // MARK: The whole pass

    func testCycleFindsCoolsOffAndUpdates() throws {
        _ = try installed()
        let (_, zip) = try published(version: "2.0")
        let feed = try fixtures.write(#"{"v":"2.0"}"#, to: "feed.json")
        var config = Fixtures.testConfiguration(scanning: applications)
        config.coolingOffHours = 24
        config.appSources = [AppSourceDefinition(bundleIdentifier: id, kind: .json, feedURL: feed.absoluteString, versionPath: "v",
                                                 downloadURL: zip.absoluteString)]
        let statePath = fixtures.root.appendingPathComponent("State.json").path

        func barkeeper(_ config: Configuration, now: Date = Date()) -> Barkeeper {
            let b = Barkeeper(config: config, log: Fixtures.quietLog())
            b.statePath = statePath
            b.stateMustBeRootOwned = false
            b.effectiveUID = 0 // installs, but the scanner and updater stay unprivileged
            b.scanner.isRoot = false
            b.scanner.homes = []
            b.updater = makeUpdater(config)
            b.now = { now }
            return b
        }

        let first = barkeeper(config).cycle(CycleOptions())
        let record = try XCTUnwrap(first.apps.first)
        XCTAssertEqual(record.status, .coolingOff, record.message)
        XCTAssertEqual(record.source?.origin, .profile)
        XCTAssertNotNil(record.firstSeen)

        // A day later the cooling-off period is over and the app is closed, so it installs.
        let later = barkeeper(config, now: Date().addingTimeInterval(25 * 3600)).cycle(CycleOptions())
        let updated = try XCTUnwrap(later.apps.first)
        XCTAssertEqual(updated.status, .updated, updated.message)
        XCTAssertEqual(updated.app.shortVersion, "2.0")
        XCTAssertEqual(updated.previousVersion, "1.0")
        XCTAssertNil(updated.available)

        // Saved for Barkeep.app.
        let saved = try XCTUnwrap(State.load(from: statePath, requireRootOwnership: false))
        XCTAssertEqual(saved.apps.first?.app.shortVersion, "2.0")
    }

    func testCycleSkipsExcludedAndUnknownApps() throws {
        try fixtures.makeApp(in: applications, name: "Excluded", bundleID: "com.example.excluded", version: "1")
        try fixtures.makeApp(in: applications, name: "Mystery", bundleID: "com.example.mystery", version: "1")
        try fixtures.makeApp(in: applications, name: "Notes", bundleID: "com.apple.Notes", version: "1")
        var config = Fixtures.testConfiguration(scanning: applications)
        config.excludedBundleIdentifiers = ["com.example.excl*"]
        let b = Barkeeper(config: config, log: Fixtures.quietLog())
        b.statePath = fixtures.root.appendingPathComponent("State.json").path
        b.stateMustBeRootOwned = false
        b.scanner.homes = []
        let state = b.cycle(CycleOptions())
        let statuses = Dictionary(uniqueKeysWithValues: state.apps.map { ($0.app.bundleIdentifier, $0.status) })
        XCTAssertEqual(statuses["com.example.excluded"], .excluded)
        XCTAssertEqual(statuses["com.example.mystery"], .noSource)
        XCTAssertEqual(statuses["com.apple.Notes"], .apple)
    }

    func testScannerFindsAppsOneFolderDownButNotInsideApps() throws {
        try fixtures.makeApp(in: applications, name: "Top", bundleID: "a.top", version: "1")
        let suite = try fixtures.folder("Applications/Suite")
        let outer = try fixtures.makeApp(in: suite, name: "Inner", bundleID: "a.inner", version: "1")
        try fixtures.makeApp(in: outer.appendingPathComponent("Contents/Helpers"), name: "Helper", bundleID: "a.helper", version: "1", sign: false)
        var config = Configuration()
        config.scanPaths = [applications.path]
        var scanner = AppScanner(config: config, log: Fixtures.quietLog())
        scanner.homes = []
        XCTAssertEqual(Set(scanner.scan().map(\.bundleIdentifier)), ["a.top", "a.inner"])
    }

    func testScannerLeavesOutBarkeepApp() throws {
        try fixtures.makeApp(in: applications, name: "Top", bundleID: "a.top", version: "1")
        try fixtures.makeApp(in: applications, name: "Barkeep", bundleID: AppScanner.ownBundleIdentifier, version: "1")
        var config = Configuration()
        config.scanPaths = [applications.path]
        var scanner = AppScanner(config: config, log: Fixtures.quietLog())
        scanner.homes = []
        XCTAssertEqual(scanner.scan().map(\.bundleIdentifier), ["a.top"])
    }

    func testRefreshRereadsOnlyChangedApps() throws {
        var config = Configuration()
        config.scanPaths = [applications.path]
        var scanner = AppScanner(config: config, log: Fixtures.quietLog())
        scanner.homes = []
        try fixtures.makeApp(in: applications, name: "Stays", bundleID: "a.stays", version: "1")
        let url = try fixtures.makeApp(in: applications, name: "Changes", bundleID: "a.changes", version: "1")
        let known = scanner.scan()
        XCTAssertTrue(known.allSatisfy { $0.fingerprint != nil })
        // Replaced by another version, as an app's own updater (or a user) would.
        try FileManager.default.removeItem(at: url)
        try fixtures.makeApp(in: applications, name: "Changes", bundleID: "a.changes", version: "2")
        let refreshed = scanner.refresh(known)
        XCTAssertEqual(refreshed.first { $0.bundleIdentifier == "a.changes" }?.shortVersion, "2")
        XCTAssertEqual(refreshed.first { $0.bundleIdentifier == "a.stays" }, known.first { $0.bundleIdentifier == "a.stays" })
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(scanner.refresh(known).map(\.bundleIdentifier), ["a.stays"], "a deleted app drops out")
    }

    func testAnAppThatUpdatedItselfAfterBeingAskedToQuitIsReopened() throws {
        let old = try installed(version: "1.0")
        var previous = AppRecord(app: old, status: .closingSoon, message: "")
        previous.quitRequestedAt = Date()
        previous.available = AvailableUpdate(version: "2.0")
        var newer = old
        newer.shortVersion = "2.0"
        newer.buildVersion = "2.0"
        let barkeeper = Barkeeper(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let record = barkeeper.carryOver(newer, previous: previous)
        XCTAssertEqual(record.relaunchRequested, true)
        XCTAssertEqual(record.updatedBySelf, true)
        XCTAssertEqual(record.previousVersion, "1.0")
        // Without a quit request, a version change is just noted.
        previous.quitRequestedAt = nil
        XCTAssertNil(barkeeper.carryOver(newer, previous: previous).relaunchRequested)
    }

    func testTildeExpandsToEveryHome() {
        var config = Configuration()
        config.scanPaths = ["/Applications", "~/Applications", "/Applications/"]
        var scanner = AppScanner(config: config, log: Fixtures.quietLog())
        scanner.homes = [URL(fileURLWithPath: "/Users/alex"), URL(fileURLWithPath: "/Users/sam")]
        XCTAssertEqual(scanner.folders().map(\.path), ["/Applications", "/Users/alex/Applications", "/Users/sam/Applications"])
    }

    func testLeasesExpire() throws {
        let app = try installed()
        let lease = try UpdateLease.acquire(for: app, duration: 60, directory: leases.path)
        XCTAssertEqual(UpdateLease.live(directory: leases.path, requireRootOwnership: false).count, 1)
        XCTAssertFalse(lease.isLive(at: Date().addingTimeInterval(61)))
        XCTAssertFalse(lease.isLive(at: Date(), processExists: { _ in false }), "a lease dies with its holder")
        lease.release(directory: leases.path)
        XCTAssertTrue(UpdateLease.live(directory: leases.path, requireRootOwnership: false).isEmpty)
    }

    func testMetadataIsReadFromTheBundle() throws {
        let url = try fixtures.makeApp(in: applications, bundleID: "com.example.electron", version: "1", extraInfo: [
            "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "abc",
        ], resources: [
            "app-update.yml": "provider: github\nowner: acme\nrepo: app\n",
            "app/product.json": #"{"updateUrl":"https://update.example.com","quality":"stable","commit":"abc"}"#,
        ])
        let app = try InstalledApp.inspect(url)
        XCTAssertEqual(app.metadata.sparkleFeedURL, "https://example.com/appcast.xml")
        XCTAssertEqual(app.metadata.sparklePublicEDKey, "abc")
        XCTAssertEqual(app.metadata.electronUpdate?["repo"], "app")
        XCTAssertEqual(app.metadata.productUpdateURL, "https://update.example.com")
        XCTAssertTrue(app.metadata.architectures.contains("arm64"))
        XCTAssertFalse(app.signatureChecked)
    }
}
