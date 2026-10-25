import Security
import XCTest
@testable import BarkeepCore

final class LocalSettingsTests: XCTestCase {
    func testChangesAreSavedAndRemoved() throws {
        let fixtures = try Fixtures()
        let path = try fixtures.folder("support").appendingPathComponent("Settings.plist").path
        try LocalSettings.set("CoolingOffHours", to: .int(48), managedKeys: [], at: path, requireRootOwnership: false)
        try LocalSettings.set("ExcludedBundleIdentifiers", to: .strings(["com.example.*"]), managedKeys: [], at: path, requireRootOwnership: false)
        let saved = LocalSettings.read(at: path, requireRootOwnership: false)
        XCTAssertEqual(saved["CoolingOffHours"] as? Int, 48)
        XCTAssertEqual(saved["ExcludedBundleIdentifiers"] as? [String], ["com.example.*"])
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o644)

        try LocalSettings.set("CoolingOffHours", to: nil, managedKeys: [], at: path, requireRootOwnership: false)
        XCTAssertNil(LocalSettings.read(at: path, requireRootOwnership: false)["CoolingOffHours"])
    }

    func testRefusals() throws {
        let fixtures = try Fixtures()
        let path = try fixtures.folder("support").appendingPathComponent("Settings.plist").path
        func set(_ key: String, _ value: LocalSettings.Value?, managed: Set<String> = []) throws {
            try LocalSettings.set(key, to: value, managedKeys: managed, at: path, requireRootOwnership: false)
        }
        XCTAssertThrowsError(try set("AllowUnverifiedSignatures", .bool(true)), "testing switches are profile-only")
        XCTAssertThrowsError(try set("LogFilePath", .string("/tmp/x")))
        XCTAssertThrowsError(try set("CoolingOffHours", .int(1), managed: ["CoolingOffHours"]), "the profile wins")
        XCTAssertThrowsError(try set("CoolingOffHours", .int(99_999)), "out of range")
        XCTAssertThrowsError(try set("CoolingOffHours", .bool(true)), "wrong type")
        XCTAssertThrowsError(try set("DeadlineBasis", .string("Tomorrow")))
        XCTAssertThrowsError(try set("ScanPaths", .strings([])), "no folders at all")
        XCTAssertTrue(LocalSettings.read(at: path, requireRootOwnership: false).isEmpty)
    }

    func testProfileWinsKeyByKey() throws {
        let fixtures = try Fixtures()
        let prefs = try fixtures.folder("prefs")
        try PropertyListSerialization.data(fromPropertyList: ["CoolingOffHours": 5], format: .xml, options: 0)
            .write(to: prefs.appendingPathComponent("\(Configuration.domain).plist"))
        let local = try fixtures.folder("support").appendingPathComponent("Settings.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CoolingOffHours": 48, "DeadlineDays": 3, "AllowFileURLs": true],
                                           format: .xml, options: 0).write(to: local)
        var loader = ConfigurationLoader(managedPreferencesDirectory: prefs.path, requireRootOwnership: false)
        loader.localSettingsPath = local.path
        let (config, warnings) = loader.load()
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.coolingOffHours, 5)
        XCTAssertEqual(config.deadlineDays, 3)
        XCTAssertFalse(config.allowFileURLs, "a key that can't be changed on the Mac is ignored in the local file")
        XCTAssertEqual(config.managedKeys, ["CoolingOffHours"])
        XCTAssertEqual(config.localKeys, ["DeadlineDays"])

        // Owned by the test user, not root: ignored outside tests.
        var strict = ConfigurationLoader(managedPreferencesDirectory: prefs.path)
        strict.localSettingsPath = local.path
        XCTAssertEqual(strict.load().0.deadlineDays, 14)
    }

    func testEveryEditableKeyIsKnown() {
        var config = Configuration()
        for key in LocalSettings.editableKeys {
            XCTAssertFalse(config.apply([key: "?"], source: "t").isEmpty, "\(key) should be read by Configuration.apply")
        }
        XCTAssertFalse(LocalSettings.editableKeys.contains("AppSources"))
    }

    func testRequestRoundTrip() throws {
        let request = DaemonRequest.changeSetting(key: "DeadlineDays", value: .int(3), authorization: Data([1, 2]))
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: JSONEncoder().encode(request))
        guard case .changeSetting(let key, let value, let auth) = decoded else { return XCTFail() }
        XCTAssertEqual(key, "DeadlineDays")
        XCTAssertEqual(value, .int(3))
        XCTAssertEqual(auth, Data([1, 2]))
        XCTAssertFalse(SettingsAuthorization.verify(Data([1, 2])), "not an authorization")
        XCTAssertFalse(SettingsAuthorization.verify(Data(count: 32)), "an empty external form holds nothing")

        // A real authorization that nobody entered a password for: what a process running as an
        // administrator could send without asking anyone.
        var empty: AuthorizationRef?
        XCTAssertEqual(AuthorizationCreate(nil, nil, [], &empty), errAuthorizationSuccess)
        defer { empty.map { _ = AuthorizationFree($0, []) } }
        var form = AuthorizationExternalForm()
        XCTAssertEqual(AuthorizationMakeExternalForm(try XCTUnwrap(empty), &form), errAuthorizationSuccess)
        XCTAssertFalse(SettingsAuthorization.verify(withUnsafeBytes(of: &form) { Data($0) }))
    }
}
