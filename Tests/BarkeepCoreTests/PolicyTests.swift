import XCTest
@testable import BarkeepCore

final class PolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86400

    func timing(coolingOff: Int = 24, deadline: Int = 7, basis: DeadlineBasis = .discovered, enforce: Bool = true,
                forceQuit: Bool = false, grace: Int = 60) -> UpdateTiming {
        UpdateTiming(coolingOffHours: coolingOff, deadlineDays: deadline, deadlineBasis: basis, enforceDeadline: enforce,
                     forceQuit: forceQuit, graceMinutes: grace)
    }

    func decide(_ update: AvailableUpdate, firstSeen: Date? = nil, _ timing: UpdateTiming, at now: Date,
                running: Bool, requested: Bool = false) -> PolicyDecision {
        UpdatePolicy.decide(update: update, firstSeen: firstSeen ?? t0, timing: timing, now: now, isRunning: running,
                            userRequested: requested, appName: "Example")
    }

    func testCoolingOffCountsFromReleaseDate() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0)
        XCTAssertEqual(decide(update, timing(), at: t0 + 23 * hour, running: false).status, .coolingOff)
        XCTAssertEqual(decide(update, timing(), at: t0 + 24 * hour, running: false).action, .install)
    }

    func testCoolingOffWithoutReleaseDateCountsFromDiscovery() {
        let update = AvailableUpdate(version: "2.0")
        let d = decide(update, firstSeen: t0 + 10 * hour, timing(), at: t0 + 30 * hour, running: false)
        XCTAssertEqual(d.status, .coolingOff)
        XCTAssertEqual(d.installableAfter, t0 + 34 * hour)
    }

    func testFutureReleaseDateCannotHoldUpdatesForever() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0 + 365 * day)
        XCTAssertEqual(decide(update, timing(coolingOff: 1), at: t0 + 30 * 60, running: false).status, .coolingOff)
        XCTAssertEqual(decide(update, timing(coolingOff: 1), at: t0 + 2 * hour, running: false).action, .install)
    }

    func testOpenAppWaitsUntilDeadlineThenGraceThenAsksToQuit() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0)
        let t = timing(coolingOff: 0, deadline: 3)
        let before = decide(update, t, at: t0 + 2 * day, running: true)
        XCTAssertEqual(before.status, .waitingForQuit)
        XCTAssertEqual(before.action, .wait)
        XCTAssertEqual(before.deadline, t0 + 3 * day)
        let warned = decide(update, t, at: t0 + 3 * day + 10 * 60, running: true)
        XCTAssertEqual(warned.status, .closingSoon)
        XCTAssertEqual(warned.action, .wait)
        XCTAssertEqual(warned.closeAt, t0 + 3 * day + hour)
        XCTAssertEqual(decide(update, t, at: t0 + 3 * day + hour, running: true).action, .askToQuit)
        XCTAssertEqual(decide(update, timing(coolingOff: 0, deadline: 3, forceQuit: true), at: t0 + 3 * day + hour, running: true).action, .forceQuit)
    }

    func testClosedAppInstallsAtOnceAfterCoolingOff() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0)
        XCTAssertEqual(decide(update, timing(coolingOff: 0), at: t0, running: false).action, .install)
    }

    func testNoDeadlineMeansWaitForever() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0)
        let d = decide(update, timing(coolingOff: 0, enforce: false), at: t0 + 400 * day, running: true)
        XCTAssertEqual(d.action, .wait)
        XCTAssertNil(d.deadline)
    }

    func testDeadlineNeverBeforeCoolingOff() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0)
        let d = decide(update, timing(coolingOff: 72, deadline: 1), at: t0, running: true)
        XCTAssertEqual(d.deadline, t0 + 72 * hour)
    }

    func testReleasedBasisUsesEarliestRelease() {
        let update = AvailableUpdate(version: "2.1", releaseDate: t0 + 5 * day)
        let d = UpdatePolicy.decide(update: update, firstSeen: t0 + 6 * day, firstReleased: t0, timing: timing(coolingOff: 0, deadline: 7, basis: .released),
                                    now: t0 + 6 * day, isRunning: true, userRequested: false, appName: "Example")
        XCTAssertEqual(d.deadline, t0 + 7 * day)
    }

    func testUserRequestAsksToQuitButNotBeforeCoolingOff() {
        let update = AvailableUpdate(version: "2.0", releaseDate: t0)
        XCTAssertEqual(decide(update, timing(coolingOff: 0), at: t0, running: true, requested: true).action, .askToQuit)
        XCTAssertEqual(decide(update, timing(coolingOff: 48), at: t0, running: true, requested: true).status, .coolingOff)
    }
}

final class SourceResolverTests: XCTestCase {
    func app(_ id: String, _ configure: (inout UpdateMetadata) -> Void = { _ in }) -> InstalledApp {
        var m = UpdateMetadata()
        configure(&m)
        return InstalledApp(path: "/Applications/X.app", name: "X.app", bundleIdentifier: id, shortVersion: "1", buildVersion: "1",
                            ownerUID: 0, signing: nil, signatureProblem: nil, designatedRequirement: nil, metadata: m)
    }

    func testOrder() {
        var config = Configuration()
        // Sparkle from the app's own Info.plist.
        XCTAssertEqual(SourceResolver.resolve(app("com.example") { $0.sparkleFeedURL = "https://e/a.xml" }, config: config).0?.definition.kind, .sparkle)
        // The catalog wins over the app's own hints.
        let chrome = SourceResolver.resolve(app("com.google.Chrome") { $0.sparkleFeedURL = "https://evil.example/a.xml" }, config: config).0
        XCTAssertEqual(chrome?.origin, .catalog)
        XCTAssertEqual(chrome?.definition.expectedTeamIdentifier, "EQHXZ8M8AV")
        // A Mac App Store copy is the App Store's, whatever the catalog says.
        XCTAssertEqual(SourceResolver.resolve(app("com.google.Chrome") { $0.hasAppStoreReceipt = true }, config: config).0?.definition.kind, .appStore)
        // The profile wins over everything.
        config.appSources = [AppSourceDefinition(bundleIdentifier: "com.google.Chrome", kind: .none)]
        XCTAssertEqual(SourceResolver.resolve(app("com.google.Chrome") { $0.hasAppStoreReceipt = true }, config: config).0?.origin, .profile)
    }

    func testVSCodeStyleProductJSON() {
        let resolved = SourceResolver.resolve(app("com.todesktop.cursor") {
            $0.productUpdateURL = "https://update.example.com"; $0.productQuality = "stable"
        }, config: Configuration()).0
        XCTAssertEqual(resolved?.definition.kind, .squirrel)
        XCTAssertEqual(resolved?.definition.channel, "stable")
    }

    func testVendorAndUnknown() {
        XCTAssertEqual(SourceResolver.resolve(app("com.microsoft.Word"), config: Configuration()).0?.definition.kind, .vendor)
        let (none, why) = SourceResolver.resolve(app("com.example.mystery") { $0.hasSparkleFramework = true }, config: Configuration())
        XCTAssertNil(none)
        XCTAssertTrue(why?.contains("run time") == true)
    }
}
