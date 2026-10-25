import XCTest
@testable import BarkeepCore

final class ConfigurationTests: XCTestCase {
    func testDefaults() {
        let config = Configuration()
        XCTAssertEqual(config.scanPaths, ["/Applications", "~/Applications"])
        XCTAssertEqual(config.coolingOffHours, 168)
        XCTAssertEqual(config.deadlineDays, 14)
        XCTAssertEqual(config.deadlineBasis, .released)
        XCTAssertNil(config.showInMenuBar)
        XCTAssertNil(config.openAtLogin)
        XCTAssertTrue(config.enforceDeadlines)
        XCTAssertFalse(config.forceQuitAtDeadline)
        XCTAssertTrue(config.requireGatekeeperAssessment)
        XCTAssertFalse(config.allowUnverifiedSignatures)
        XCTAssertFalse(config.allowFileURLs)
    }

    func testAppliesEveryKind() {
        var config = Configuration()
        let warnings = config.apply([
            "ExcludedBundleIdentifiers": ["com.microsoft.Excel", " com.adobe.* "],
            "CoolingOffHours": 48,
            "DeadlineDays": 3,
            "DeadlineBasis": "discovered",
            "EnforceDeadlines": false,
            "ScanPaths": ["/Applications", "/Users/Shared/Apps"],
            "ShowInMenuBar": false,
            "OpenAtLogin": true,
            "AppSettings": ["com.google.Chrome": ["CoolingOffHours": 0, "DeadlineDays": 1, "Excluded": false]],
        ], source: "test")
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.excludedBundleIdentifiers, ["com.microsoft.Excel", "com.adobe.*"])
        XCTAssertEqual(config.coolingOffHours, 48)
        XCTAssertEqual(config.deadlineBasis, .discovered)
        XCTAssertFalse(config.enforceDeadlines)
        XCTAssertEqual(config.scanPaths, ["/Applications", "/Users/Shared/Apps"])
        XCTAssertEqual(config.showInMenuBar, false)
        XCTAssertEqual(config.openAtLogin, true)
        XCTAssertEqual(config.timing(for: "com.google.Chrome").coolingOffHours, 0)
        XCTAssertEqual(config.timing(for: "com.google.Chrome").deadlineDays, 1)
        XCTAssertEqual(config.timing(for: "org.mozilla.firefox").coolingOffHours, 48)
        XCTAssertEqual(config.sources, ["test"])
    }

    func testWrongTypesAreReportedAndIgnored() {
        var config = Configuration()
        let warnings = config.apply([
            "CoolingOffHours": true,          // a boolean is not 1 hour
            "DeadlineDays": 9999,             // clamped
            "EnforceDeadlines": "yes",
            "ExcludedBundleIdentifiers": "com.example",
            "DeadlineBasis": "Tomorrow",
        ], source: "p")
        XCTAssertEqual(config.coolingOffHours, 168)
        XCTAssertEqual(config.deadlineDays, 365)
        XCTAssertTrue(config.enforceDeadlines)
        XCTAssertEqual(config.excludedBundleIdentifiers, [])
        XCTAssertEqual(config.deadlineBasis, .released)
        XCTAssertEqual(warnings.count, 5, "\(warnings)")
    }

    func testExclusionWildcardsAndInclusion() {
        var config = Configuration()
        config.excludedBundleIdentifiers = ["com.microsoft.excel", "com.adobe.*"]
        XCTAssertTrue(config.isExcluded("com.microsoft.Excel"))
        XCTAssertTrue(config.isExcluded("com.adobe.Photoshop"))
        XCTAssertFalse(config.isExcluded("com.microsoft.Word"))
        config.includedBundleIdentifiers = ["org.mozilla.*"]
        XCTAssertTrue(config.isExcluded("com.google.Chrome"))
        XCTAssertFalse(config.isExcluded("org.mozilla.firefox"))
        config.appSettings["org.mozilla.firefox"] = { var o = AppOverrides(); o.excluded = true; return o }()
        XCTAssertTrue(config.isExcluded("org.mozilla.firefox"))
    }

    func testAppSourcesAreValidated() {
        var config = Configuration()
        let warnings = config.apply(["AppSources": [
            ["BundleIdentifier": "com.example.a", "Type": "Sparkle", "FeedURL": "https://example.com/appcast.xml"],
            ["BundleIdentifier": "com.example.b", "Type": "Sparkle"],                        // no FeedURL
            ["BundleIdentifier": "com.example.c", "Type": "GitHub", "Repository": "nope"],   // not owner/repo
            ["BundleIdentifier": "com.example.d", "Type": "Telepathy"],
            ["BundleIdentifier": "com.example.e", "Type": "json", "FeedURL": "https://e", "VersionPath": "v",
             "DownloadURL": "https://e/{version}.zip", "ExpectedTeamIdentifier": "ABCDE12345"],
            ["BundleIdentifier": "com.example.f", "Type": "GitHub", "Repository": "o/r", "AssetPattern": "(["],
        ]], source: "p")
        XCTAssertEqual(config.appSources.map(\.bundleIdentifier), ["com.example.a", "com.example.e"])
        XCTAssertEqual(config.appSources.last?.kind, .json)
        XCTAssertEqual(warnings.count, 4, "\(warnings)")
        XCTAssertEqual(config.source(for: "COM.EXAMPLE.A")?.feedURL, "https://example.com/appcast.xml")
    }

    func testLoaderRejectsUntrustedFiles() throws {
        let fixtures = try Fixtures()
        let dir = try fixtures.folder("prefs")
        let path = dir.appendingPathComponent("\(Configuration.domain).plist")
        try PropertyListSerialization.data(fromPropertyList: ["CoolingOffHours": 5], format: .xml, options: 0).write(to: path)
        // Owned by the test user, not root: ignored.
        // Not this Mac's own Settings.plist, which may exist.
        let local = dir.appendingPathComponent("Settings.plist").path
        let (strict, warnings) = ConfigurationLoader(managedPreferencesDirectory: dir.path, localSettingsPath: local).load()
        XCTAssertEqual(strict.coolingOffHours, 168)
        XCTAssertTrue(warnings.first?.contains("not owned by root") == true)
        let (relaxed, _) = ConfigurationLoader(managedPreferencesDirectory: dir.path, localSettingsPath: local,
                                               requireRootOwnership: false).load()
        XCTAssertEqual(relaxed.coolingOffHours, 5)
    }

    func testSampleProfileHasNoWarnings() throws {
        let profile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Profiles/uk.street365.barkeep.mobileconfig")
        let data = try Data(contentsOf: profile)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payload = try XCTUnwrap((plist["PayloadContent"] as? [[String: Any]])?.first)
        var config = Configuration()
        XCTAssertEqual(config.apply(payload, source: "sample"), [])
        var defaults = Configuration()
        defaults.sources = ["sample"]
        XCTAssertEqual(config, defaults, "The sample profile should spell out the defaults")
    }

    func testExampleProfilesHaveNoWarnings() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Profiles/Examples")
        let profiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mobileconfig" }
        XCTAssertFalse(profiles.isEmpty)
        for profile in profiles {
            let data = try Data(contentsOf: profile)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let payload = try XCTUnwrap((plist["PayloadContent"] as? [[String: Any]])?.first)
            var config = Configuration()
            XCTAssertEqual(config.apply(payload, source: profile.lastPathComponent), [])
            var defaults = Configuration()
            defaults.sources = [profile.lastPathComponent]
            XCTAssertNotEqual(config, defaults, "\(profile.lastPathComponent) should change something")
        }
    }
}
