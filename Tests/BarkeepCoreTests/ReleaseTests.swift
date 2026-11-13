import XCTest
@testable import BarkeepCore

/// Apps that release more often than the cooling-off period lasts: barkeep remembers each release
/// and installs the newest that has cooled off. Also the seal on what it remembers, and Gatekeeper
/// being turned off.
final class ReleaseTests: XCTestCase {
    var fixtures: Fixtures!
    var applications: URL!
    var leases: URL!
    var statePath: String!
    let id = "uk.street365.barkeep.test"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86400

    override func setUpWithError() throws {
        fixtures = try Fixtures()
        applications = try fixtures.folder("Applications")
        leases = try fixtures.folder("Leases")
        statePath = try fixtures.folder("State").appendingPathComponent("State.json").path
    }

    // MARK: Choosing a release

    func release(_ version: String, seen: Date, released: Date? = nil) -> KnownRelease {
        KnownRelease(update: AvailableUpdate(version: version, releaseDate: released), seen: seen)
    }

    func testTheNewestCooledOffReleaseIsChosen() {
        let releases = (0..<10).map { release("1.\($0)", seen: t0 + Double($0) * day, released: t0 + Double($0) * day) }
        // Day 9, with a week's cooling off: 1.2 came out a week ago, 1.3 six days ago.
        let chosen = ReleaseSelection.select(from: releases, coolingOffHours: 168, now: t0 + 9 * day)
        XCTAssertEqual(chosen?.update.version, "1.2")
        // With no cooling off, the newest.
        XCTAssertEqual(ReleaseSelection.select(from: releases, coolingOffHours: 0, now: t0 + 9 * day)?.update.version, "1.9")
    }

    func testWithNothingCooledOffTheNextToBeReadyIsChosen() {
        let releases = [release("1.1", seen: t0), release("1.2", seen: t0 + day)]
        let chosen = ReleaseSelection.select(from: releases, coolingOffHours: 168, now: t0 + 2 * day)
        XCTAssertEqual(chosen?.update.version, "1.1")
        XCTAssertNil(ReleaseSelection.select(from: [], coolingOffHours: 0, now: t0))
    }

    func testAReleaseSetAsideIsPassedOver() {
        var releases = [release("1.1", seen: t0), release("1.2", seen: t0 + hour), release("1.3", seen: t0 + 6 * day)]
        releases[1].setAside = "its download has gone"
        XCTAssertEqual(ReleaseSelection.select(from: releases, coolingOffHours: 24, now: t0 + 3 * day)?.update.version, "1.1")
    }

    func testAReleaseDateInTheFutureCountsFromWhenItWasSeen() {
        let r = release("2.0", seen: t0, released: t0 + 365 * day)
        XCTAssertEqual(r.installableAfter(coolingOffHours: 24, now: t0 + hour), t0 + day)
        // Nor can a "seen" in the future (a clock that was wrong) hold a release back.
        XCTAssertEqual(release("2.0", seen: t0 + 365 * day).installableAfter(coolingOffHours: 24, now: t0), t0 + day)
    }

    func testPruningKeepsEveryReleaseStillCoolingOffAndAFewThatAreReady() {
        let releases = (0..<40).map { release("1.\($0)", seen: t0 + Double($0) * day) }
        let kept = ReleaseSelection.prune(releases, coolingOffHours: 168, now: t0 + 40 * day)
        // 1.0 to 1.33 are ready (the newest three stay); 1.34 to 1.39 are cooling off.
        XCTAssertEqual(kept.map(\.update.version), ["1.31", "1.32", "1.33", "1.34", "1.35", "1.36", "1.37", "1.38", "1.39"])
        let thinned = ReleaseSelection.prune(releases, coolingOffHours: 24 * 365, now: t0 + 40 * day, limit: 10)
        XCTAssertLessThanOrEqual(thinned.count, 10)
        XCTAssertEqual(thinned.first?.update.version, "1.0", "the oldest stays: it is ready first")
        XCTAssertEqual(thinned.last?.update.version, "1.39")
    }

    func testSparkleAppcastGivesEveryReleaseOldestFirst() throws {
        let feed = try fixtures.write("""
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><pubDate>Wed, 03 Jan 2029 10:00:00 +0000</pubDate><sparkle:version>130</sparkle:version>
          <sparkle:shortVersionString>1.3</sparkle:shortVersionString><enclosure url="https://example.com/App-1.3.zip" length="1" sparkle:edSignature="Mw=="/></item>
        <item><pubDate>Mon, 01 Jan 2029 10:00:00 +0000</pubDate><sparkle:version>110</sparkle:version>
          <sparkle:shortVersionString>1.1</sparkle:shortVersionString><enclosure url="https://example.com/App-1.1.zip" length="1" sparkle:edSignature="MQ=="/></item>
        <item><pubDate>Tue, 02 Jan 2029 10:00:00 +0000</pubDate><sparkle:version>120</sparkle:version>
          <sparkle:shortVersionString>1.2</sparkle:shortVersionString><enclosure url="https://example.com/App-1.2.zip" length="1" sparkle:edSignature="Mg=="/></item>
        </channel></rss>
        """, to: "appcast.xml")
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let app = try InstalledApp.inspect(fixtures.makeApp(in: applications, bundleID: id, version: "1.0", build: "100"))
        let source = AppSourceDefinition(bundleIdentifier: id, kind: .sparkle, feedURL: feed.absoluteString)
        let releases = try finder.releases(for: app, source: source)
        XCTAssertEqual(releases.map(\.version), ["1.1", "1.2", "1.3"])
        XCTAssertEqual(releases.map(\.edSignature), ["MQ==", "Mg==", "Mw=="], "each with its own signature")
        XCTAssertEqual(releases.map(\.downloadURL), ["https://example.com/App-1.1.zip", "https://example.com/App-1.2.zip", "https://example.com/App-1.3.zip"])
        XCTAssertEqual(try finder.latest(for: app, source: source)?.version, "1.3")
    }

    // MARK: A whole pass

    /// Publishes `version` at `Test-<version>.zip` and makes it the feed's newest.
    func publish(_ version: String) throws {
        let build = try fixtures.folder("build-\(version)")
        let app = try fixtures.makeApp(in: build, bundleID: id, version: version)
        _ = try fixtures.zip(app, as: "Test-\(version).zip")
        _ = try fixtures.write(#"{"v":"\#(version)"}"#, to: "feed.json")
    }

    func configuration(coolingOffHours: Int, download: String? = nil) -> Configuration {
        var config = Fixtures.testConfiguration(scanning: applications)
        config.coolingOffHours = coolingOffHours
        config.checkIntervalMinutes = 15
        let root = fixtures.root.absoluteString
        config.appSources = [AppSourceDefinition(bundleIdentifier: id, kind: .json, feedURL: root + "feed.json", versionPath: "v",
                                                 downloadURL: download ?? root + "Test-{version}.zip")]
        return config
    }

    func barkeeper(_ config: Configuration, now: Date, sealed: Bool = false) -> Barkeeper {
        let b = Barkeeper(config: config, log: Fixtures.quietLog())
        b.statePath = statePath
        b.stateMustBeRootOwned = false
        b.sealsState = sealed
        b.viewDirectory = nil
        b.effectiveUID = 0 // installs, but the scanner and updater stay unprivileged
        b.scanner.isRoot = false
        b.scanner.homes = []
        let updater = AppUpdater(config: config, log: Fixtures.quietLog())
        updater.registersWithLaunchServices = false
        updater.leaseDirectory = leases.path
        b.updater = updater
        b.now = { now }
        return b
    }

    func pass(_ config: Configuration, at now: Date, sealed: Bool = false) throws -> AppRecord {
        try XCTUnwrap(barkeeper(config, now: now, sealed: sealed).cycle(CycleOptions()).apps.first)
    }

    func testAnAppThatReleasesEveryDayIsStillUpdated() throws {
        try fixtures.makeApp(in: applications, bundleID: id, version: "1.0")
        let config = configuration(coolingOffHours: 48)

        // A new release every day. The newest is never two days old, so it never cools off.
        try publish("1.1")
        XCTAssertEqual(try pass(config, at: t0).status, .coolingOff)
        try publish("1.2")
        var record = try pass(config, at: t0 + day)
        XCTAssertEqual(record.status, .coolingOff)
        XCTAssertEqual(record.releases?.map(\.update.version), ["1.1", "1.2"])
        XCTAssertEqual(record.selected?.version, "1.1", "the one that will be ready first")
        XCTAssertEqual(record.available?.version, "1.2")

        // Day 2: 1.3 is out, and 1.1 has cooled off, so 1.1 is installed, from where it was published.
        try publish("1.3")
        record = try pass(config, at: t0 + 2 * day)
        XCTAssertEqual(record.status, .updated, record.message)
        XCTAssertEqual(record.app.shortVersion, "1.1")
        XCTAssertEqual(record.releases?.map(\.update.version), ["1.2", "1.3"], "the rest are still to come")
        XCTAssertEqual(record.available?.version, "1.3")

        // Day 3: 1.2's turn. The app stays two days behind, and never further.
        record = try pass(config, at: t0 + 3 * day)
        XCTAssertEqual(record.app.shortVersion, "1.2", record.message)
        XCTAssertEqual(record.previousVersion, "1.1")
        record = try pass(config, at: t0 + 3 * day + hour)
        XCTAssertEqual(record.status, .coolingOff)
        XCTAssertEqual(record.selected?.version, "1.3")
        XCTAssertEqual(record.installableAfter, t0 + 4 * day)
    }

    func testADownloadThatIsNowANewerReleaseIsNotInstalledEarly() throws {
        try fixtures.makeApp(in: applications, bundleID: id, version: "1.0")
        // One address for every release, as a "latest" link is.
        let latest = fixtures.root.appendingPathComponent("Test-latest.zip")
        let config = configuration(coolingOffHours: 48, download: latest.absoluteString)
        func publishLatest(_ version: String) throws {
            try publish(version)
            try? FileManager.default.removeItem(at: latest)
            try FileManager.default.copyItem(at: fixtures.root.appendingPathComponent("Test-\(version).zip"), to: latest)
        }
        try publishLatest("1.1")
        _ = try pass(config, at: t0)
        try publishLatest("1.2")
        _ = try pass(config, at: t0 + day)

        // 1.1 has cooled off, but its address now serves 1.2, which hasn't.
        var record = try pass(config, at: t0 + 2 * day)
        XCTAssertEqual(record.status, .failed, record.message)
        XCTAssertTrue(record.message.contains("cooling-off"), record.message)
        XCTAssertEqual(record.app.shortVersion, "1.0", "nothing was installed")
        XCTAssertNotNil(record.releases?.first?.setAside, "1.1 can't be had any more")

        // 1.2 is installed when its own cooling-off period is over.
        record = try pass(config, at: t0 + 2 * day + hour)
        XCTAssertEqual(record.status, .coolingOff, record.message)
        XCTAssertEqual(record.selected?.version, "1.2")
        record = try pass(config, at: t0 + 3 * day)
        XCTAssertEqual(record.app.shortVersion, "1.2", record.message)
    }

    func testAReleaseTheVendorWithdrewIsForgotten() throws {
        try fixtures.makeApp(in: applications, bundleID: id, version: "1.0")
        let config = configuration(coolingOffHours: 48)
        try publish("1.1")
        _ = try pass(config, at: t0)
        try publish("1.2")
        _ = try pass(config, at: t0 + day)
        // 1.2 is pulled: the feed goes back to 1.1.
        _ = try fixtures.write(#"{"v":"1.1"}"#, to: "feed.json")
        let record = try pass(config, at: t0 + day + hour)
        XCTAssertEqual(record.releases?.map(\.update.version), ["1.1"])
        XCTAssertEqual(try pass(config, at: t0 + 5 * day).app.shortVersion, "1.1")
    }

    func testAnUpdateAlreadyKnownInstallsWhileItsFeedIsDown() throws {
        try fixtures.makeApp(in: applications, bundleID: id, version: "1.0")
        let config = configuration(coolingOffHours: 24)
        try publish("1.1")
        _ = try pass(config, at: t0)
        try FileManager.default.removeItem(at: fixtures.root.appendingPathComponent("feed.json"))
        let record = try pass(config, at: t0 + 2 * day)
        XCTAssertEqual(record.app.shortVersion, "1.1", record.message)

        // With nothing known, a feed that can't be read is a problem to show, and is asked again sooner.
        let failed = try pass(config, at: t0 + 3 * day)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.feedFailures, 2, "it failed the day before too")
        let b = barkeeper(config, now: t0 + 3 * day + 16 * 60)
        XCTAssertTrue(b.feedIsDue(failed, source: try XCTUnwrap(failed.source), options: CycleOptions(), now: t0 + 3 * day + 16 * 60))
    }

    func testFeedsAreAskedTogetherAndEachAppGetsItsOwnAnswer() throws {
        var config = Fixtures.testConfiguration(scanning: applications)
        let root = fixtures.root.absoluteString
        for index in 0..<12 {
            let bundleID = "com.example.app\(index)"
            try fixtures.makeApp(in: applications, name: "App\(index)", bundleID: bundleID, version: "1.0", sign: false)
            _ = try fixtures.write(#"{"v":"2.\#(index)"}"#, to: "feed\(index).json")
            config.appSources.append(AppSourceDefinition(bundleIdentifier: bundleID, kind: .json, feedURL: root + "feed\(index).json",
                                                         versionPath: "v", downloadURL: "https://example.com/\(index).zip"))
        }
        let b = barkeeper(config, now: t0)
        b.effectiveUID = 501 // looks, installs nothing
        b.stateMustBeRootOwned = false
        let state = b.cycle(CycleOptions())
        XCTAssertEqual(state.apps.count, 12)
        for record in state.apps {
            let index = try XCTUnwrap(Int(record.app.bundleIdentifier.dropFirst("com.example.app".count)))
            XCTAssertEqual(record.available?.version, "2.\(index)")
            XCTAssertEqual(record.lastChecked, t0)
        }
        XCTAssertEqual(state.lastCheck, t0)
    }

    // MARK: The seal

    func seal() -> StateSeal {
        var seal = StateSeal(directory: (statePath as NSString).deletingLastPathComponent)
        seal.requireRootOwnership = false
        return seal
    }

    func testAStateBarkeepSealedIsAcceptedAndAnEditedOneIsNot() throws {
        var state = State()
        state.lastScan = t0
        try state.save(to: statePath, seal: seal())
        XCTAssertEqual(State.loadSealed(from: statePath, seal: seal(), requireRootOwnership: false).state?.lastScan, t0)
        let mode = try FileManager.default.attributesOfItem(atPath: seal().keyPath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "only its owner can read the key")

        // Someone moves a date.
        var text = try String(contentsOfFile: statePath, encoding: .utf8)
        text = text.replacingOccurrences(of: "2027-01-15", with: "2020-01-15")
        try text.write(toFile: statePath, atomically: true, encoding: .utf8)
        let (edited, problem) = State.loadSealed(from: statePath, seal: seal(), requireRootOwnership: false)
        XCTAssertNil(edited)
        XCTAssertTrue(problem?.contains("does not match its seal") == true, problem ?? "")
        XCTAssertNotNil(State.load(from: statePath, requireRootOwnership: false), "Barkeep.app only shows it, and still can")
    }

    func testTheSealCoversACrashBetweenItsTwoWrites() throws {
        var state = State()
        try state.save(to: statePath, seal: seal())
        let first = try Data(contentsOf: URL(fileURLWithPath: statePath))
        state.lastScan = t0
        let second = try State.encoder.encode(state)
        // The seal for the next state is written, and barkeep stops before replacing the state.
        try seal().seal(second, replacing: first)
        XCTAssertEqual(seal().verify(first), .valid, "the state still on disk")
        XCTAssertEqual(seal().verify(second), .valid)
        XCTAssertNotEqual(seal().verify(Data("{}".utf8)), .valid)
    }

    func testAStateFromBeforeSealingIsAcceptedOnceAndAMissingSealIsNot() throws {
        var state = State()
        state.lastScan = t0
        try state.save(to: statePath)
        XCTAssertEqual(seal().verify(try Data(contentsOf: URL(fileURLWithPath: statePath))), .neverSealed)
        XCTAssertNotNil(State.loadSealed(from: statePath, seal: seal(), requireRootOwnership: false).state)

        try state.save(to: statePath, seal: seal())
        try FileManager.default.removeItem(atPath: seal().sealPath)
        XCTAssertNil(State.loadSealed(from: statePath, seal: seal(), requireRootOwnership: false).state)
        // A key that others can read vouches for nothing.
        try state.save(to: statePath, seal: seal())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: seal().keyPath)
        XCTAssertNil(State.loadSealed(from: statePath, seal: seal(), requireRootOwnership: false).state)
    }

    func testEditingTheStateCannotBringAnUpdateForward() throws {
        try fixtures.makeApp(in: applications, bundleID: id, version: "1.0")
        let config = configuration(coolingOffHours: 48)
        try publish("1.1")
        XCTAssertEqual(try pass(config, at: t0, sealed: true).status, .coolingOff)

        // Someone edits the state to say barkeep has known about 1.1 for a year.
        var state = try XCTUnwrap(State.load(from: statePath, requireRootOwnership: false))
        state.apps[0].releases?[0].seen = t0 - 365 * day
        state.apps[0].firstSeen = t0 - 365 * day
        state.apps[0].versionSeen = t0 - 365 * day
        try state.save(to: statePath)

        let record = try pass(config, at: t0 + hour, sealed: true)
        XCTAssertEqual(record.app.shortVersion, "1.0", "nothing was installed early")
        XCTAssertEqual(record.status, .coolingOff, record.message)
        XCTAssertEqual(record.installableAfter, t0 + hour + 2 * day, "the edited state was thrown away; the clock starts again")
        // The state barkeep then saved is its own again.
        XCTAssertEqual(try pass(config, at: t0 + 2 * hour, sealed: true).installableAfter, t0 + hour + 2 * day)
    }

    // MARK: Gatekeeper

    func testGatekeeperTurnedOffIsToldFromGatekeeperSayingYes() {
        let notarised = "/Applications/Example.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (ABCDE12345)"
        XCTAssertEqual(Gatekeeper.assessment(status: 0, output: notarised), .notarised)
        // Turned off, spctl accepts everything without looking: barkeep must check for itself.
        let off = "/Applications/Example.app: accepted\noverride=security disabled"
        XCTAssertEqual(Gatekeeper.assessment(status: 0, output: off), .notPerformed)
        guard case .rejected = Gatekeeper.assessment(status: 3, output: "/Applications/Example.app: rejected\nsource=Unnotarized Developer ID") else {
            return XCTFail("an unnotarised app is rejected")
        }
        guard case .rejected = Gatekeeper.assessment(status: 0, output: "Example.app: accepted\nsource=My local rule") else {
            return XCTFail("a local spctl --add rule is not notarisation")
        }
        guard case .rejected = Gatekeeper.assessment(status: 0, output: "Example.app: accepted\noverride=something else") else {
            return XCTFail("only Gatekeeper being off is handled by checking directly")
        }
    }

    func testGatekeeperStatus() {
        XCTAssertEqual(Gatekeeper.mode(fromStatus: "assessments enabled\n"), .enabled)
        XCTAssertEqual(Gatekeeper.mode(fromStatus: "assessments disabled\n"), .disabled)
        XCTAssertEqual(Gatekeeper.mode(fromStatus: ""), .unknown)
    }

    func testPackageNotarisationIsReadFromPkgutil() {
        let signed = """
        Package "Example.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Signed with a trusted timestamp on: 2026-01-01 10:00:00 +0000
           Certificate Chain:
            1. Developer ID Installer: Example Ltd (ABCDE12345)
        """
        XCTAssertTrue(Gatekeeper.packageIsNotarised(fromCheckSignature: signed))
        XCTAssertFalse(Gatekeeper.packageIsNotarised(fromCheckSignature: signed.replacingOccurrences(of: "   Notarization: trusted by the Apple notary service\n", with: "")))
    }

    func testAnAppThatIsNotNotarisedFailsTheDirectCheck() throws {
        // What barkeep falls back on with Gatekeeper off: an ad-hoc signed app has no ticket.
        let app = try fixtures.makeApp(in: applications, bundleID: id, version: "1.0")
        XCTAssertFalse(try Gatekeeper.isNotarised(app, package: false))
    }
}
