import Foundation
import XCTest
@testable import BarkeepCore

/// Builds small, ad-hoc signed app bundles and archives in a temporary folder.
final class Fixtures {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("barkeep-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An app bundle at `folder/name.app`, signed ad hoc with `bundleID` as its identifier.
    @discardableResult
    func makeApp(in folder: URL, name: String = "Test", bundleID: String = "uk.street365.barkeep.test",
                 version: String, build: String? = nil, extraInfo: [String: Any] = [:],
                 resources: [String: String] = [:], sign: Bool = true, executable: String = "/usr/bin/true",
                 signingIdentifier: String? = nil) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build ?? version,
            "LSMinimumSystemVersion": "13.0",
        ]
        info.merge(extraInfo) { $1 }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(atPath: executable, toPath: macOS.appendingPathComponent(name).path)
        for (relative, text) in resources {
            let url = app.appendingPathComponent("Contents/Resources/\(relative)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        if sign {
            // An explicit designated requirement, as a Developer ID signature would have, so the
            // next version (signed the same way) satisfies it and a copy signed otherwise does not.
            let identifier = signingIdentifier ?? bundleID
            let result = try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier,
                                                              "-r=designated => identifier \"\(identifier)\"", app.path])
            XCTAssertEqual(result.status, 0, result.stderrString)
        }
        return app
    }

    /// A zip of `app` (with its folder name at the top), as vendors publish them.
    func zip(_ app: URL, as name: String) throws -> URL {
        let out = root.appendingPathComponent(name)
        let result = try Command.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path])
        XCTAssertEqual(result.status, 0, result.stderrString)
        return out
    }

    func write(_ text: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Settings for tests: ad-hoc apps, file feeds, no Gatekeeper.
    static func testConfiguration(scanning folder: URL? = nil) -> Configuration {
        var config = Configuration()
        config.allowUnverifiedSignatures = true
        config.allowFileURLs = true
        config.requireGatekeeperAssessment = false
        config.coolingOffHours = 0
        if let folder { config.scanPaths = [folder.path] }
        return config
    }

    static func quietLog() -> Log {
        let log = Log()
        log.quiet = true
        return log
    }
}
