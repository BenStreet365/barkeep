import CryptoKit
import XCTest
@testable import BarkeepCore

final class FeedTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertEqual(Version.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(Version.compare("2.0", "2"), .orderedSame)
        XCTAssertEqual(Version.compare("7.2.2 (88465)", "7.2.2.88465"), .orderedSame)
        XCTAssertEqual(Version.compare("7.2.3 (1)", "7.2.2.88465"), .orderedDescending)
        XCTAssertEqual(Version.compare("1.0b2", "1.0b1"), .orderedDescending)
        XCTAssertEqual(Version.compare("156.0.8078.48", "156.0.8078.12"), .orderedDescending)
        XCTAssertEqual(Version.fromTag("v1.2.3"), "1.2.3")
        XCTAssertEqual(Version.fromTag("release-4.5"), "4.5")
        // A leading "v" is ignored, so v-prefixed installed versions still update.
        XCTAssertEqual(Version.compare("v2.0.12", "2.0.12"), .orderedSame)
        XCTAssertEqual(Version.compare("2.0.13", "v2.0.12"), .orderedDescending)
        XCTAssertEqual(Version.compare("V3", "2.9"), .orderedDescending)
    }

    func app(short: String?, build: String?) -> InstalledApp {
        InstalledApp(path: "/Applications/X.app", name: "X.app", bundleIdentifier: "x", shortVersion: short, buildVersion: build,
                     ownerUID: 0, signing: nil, signatureProblem: nil, designatedRequirement: nil, metadata: UpdateMetadata())
    }

    func testIsNewer() {
        XCTAssertTrue(AvailableUpdate(version: "1.2").isNewer(than: app(short: "1.1", build: "40")))
        XCTAssertFalse(AvailableUpdate(version: "1.1").isNewer(than: app(short: "1.1", build: "40")))
        // Sparkle compares builds: a rebuilt 1.1 is newer.
        XCTAssertTrue(AvailableUpdate(version: "1.1", build: "41").isNewer(than: app(short: "1.1", build: "40")))
        XCTAssertFalse(AvailableUpdate(version: "1.2", build: "39").isNewer(than: app(short: "1.1", build: "40")))
        XCTAssertTrue(AvailableUpdate(version: "2.0.13").isNewer(than: app(short: "v2.0.12", build: nil)))
        XCTAssertFalse(AvailableUpdate(version: "2.0.12").isNewer(than: app(short: "v2.0.12", build: nil)))
    }

    static let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>Version 2.0</title>
          <pubDate>Tue, 20 Oct 2026 10:00:00 +0000</pubDate>
          <sparkle:version>200</sparkle:version>
          <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-2.0.zip" length="1234" type="application/octet-stream"
                     sparkle:edSignature="c2lnbmF0dXJl"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/App-2.0-delta.delta" sparkle:version="200" sparkle:deltaFrom="190"/>
          </sparkle:deltas>
        </item>
        <item>
          <title>Version 3.0 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/App-3.0b1.zip" sparkle:version="300" sparkle:shortVersionString="3.0b1"/>
        </item>
        <item>
          <title>Version 2.5 for the future</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-2.5.zip" sparkle:version="250" sparkle:shortVersionString="2.5"/>
        </item>
        <item>
          <title>Windows</title>
          <enclosure url="https://example.com/App.exe" sparkle:version="400" sparkle:os="windows"/>
        </item>
        <item>
          <title>Docker style</title>
          <pubDate>2026-10-22T17:39:14Z</pubDate>
          <enclosure url="https://example.com/App-1.9.dmg" sparkle:version="190" sparkle:shortVersionString="1.9"/>
        </item>
      </channel>
    </rss>
    """

    func testSparkleAppcast() throws {
        let items = try SparkleAppcast.parse(Data(Self.appcast.utf8))
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].build, "200")
        XCTAssertEqual(items[0].url, "https://example.com/App-2.0.zip", "the delta must not replace the full update")
        XCTAssertEqual(items[0].edSignature, "c2lnbmF0dXJl")
        XCTAssertEqual(items[0].length, 1234)
        XCTAssertNotNil(items[0].date)
        XCTAssertEqual(items[1].channel, "beta")
        XCTAssertFalse(items[3].isForMac)
        XCTAssertNotNil(items[4].date, "ISO 8601 pubDate")
    }

    func testSparkleFinderPicksNewestUsableItem() throws {
        let fixtures = try Fixtures()
        let feed = try fixtures.write(Self.appcast, to: "appcast.xml")
        var finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        finder.systemVersion = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        let update = try XCTUnwrap(finder.latest(for: app(short: "1.0", build: "100"),
                                                 source: AppSourceDefinition(bundleIdentifier: "x", kind: .sparkle, feedURL: feed.absoluteString)))
        XCTAssertEqual(update.version, "2.0")
        XCTAssertEqual(update.build, "200")
        XCTAssertEqual(update.edSignature, "c2lnbmF0dXJl")
    }

    func testSparkleRelativeEnclosureURL() throws {
        XCTAssertEqual(UpdateFinder.resolve("Tailscale-1.104.2-macos.zip", against: "https://pkgs.tailscale.com/stable/appcast.xml"),
                       "https://pkgs.tailscale.com/stable/Tailscale-1.104.2-macos.zip")
        XCTAssertEqual(UpdateFinder.resolve("https://cdn.example.com/App.zip", against: "https://example.com/appcast.xml"),
                       "https://cdn.example.com/App.zip")
        let fixtures = try Fixtures()
        let feed = try fixtures.write("""
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
          <sparkle:version>101.104.2</sparkle:version><sparkle:shortVersionString>1.104.2</sparkle:shortVersionString>
          <enclosure url="Tailscale-1.104.2-macos.zip" length="10" sparkle:edSignature="c2ln"/>
        </item></channel></rss>
        """, to: "appcast.xml")
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let update = try XCTUnwrap(finder.latest(for: app(short: "1.102.4", build: "101.102.4"),
                                                 source: AppSourceDefinition(bundleIdentifier: "x", kind: .sparkle, feedURL: feed.absoluteString)))
        XCTAssertEqual(update.downloadURL, feed.deletingLastPathComponent().appendingPathComponent("Tailscale-1.104.2-macos.zip").absoluteString)
    }

    func testFileURLsNeedPermission() throws {
        let fixtures = try Fixtures()
        let feed = try fixtures.write(Self.appcast, to: "appcast.xml")
        let finder = UpdateFinder(config: Configuration(), log: Fixtures.quietLog())
        XCTAssertThrowsError(try finder.latest(for: app(short: "1", build: "1"),
                                               source: AppSourceDefinition(bundleIdentifier: "x", kind: .sparkle, feedURL: feed.absoluteString)))
    }

    static let latestMac = """
    version: 1.4.2
    files:
      - url: Example-1.4.2-mac.zip
        sha512: aW50ZWw=
        size: 100
      - url: Example-1.4.2-arm64-mac.zip
        sha512: YXJtNjQ=
        size: 90
      - url: Example-1.4.2-arm64.dmg
        sha512: ZG1n
        size: 95
    path: Example-1.4.2-mac.zip
    sha512: aW50ZWw=
    releaseDate: '2026-10-01T12:00:00.000Z'
    """

    func testElectronBuilderGenericFeed() throws {
        let fixtures = try Fixtures()
        let base = try fixtures.folder("electron")
        try Data(Self.latestMac.utf8).write(to: base.appendingPathComponent("latest-mac.yml"))
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let update = try XCTUnwrap(finder.latest(for: app(short: "1.4.1", build: "1.4.1"),
                                                 source: AppSourceDefinition(bundleIdentifier: "x", kind: .electronBuilder, feedURL: base.absoluteString)))
        XCTAssertEqual(update.version, "1.4.2")
        XCTAssertTrue(update.downloadURL?.hasSuffix("Example-1.4.2-arm64-mac.zip") == true, update.downloadURL ?? "")
        XCTAssertEqual(update.sha512, "YXJtNjQ=")
        XCTAssertNotNil(update.releaseDate)
    }

    func testYAMLParsing() {
        let flat = SimpleYAML.parseFlat("provider: github\nowner: 'acme'\nrepo: \"app\"\n# comment\nupdaterCacheDirName: x\n")
        XCTAssertEqual(flat["provider"], "github")
        XCTAssertEqual(flat["owner"], "acme")
        XCTAssertEqual(flat["repo"], "app")
        XCTAssertEqual(SimpleYAML.parseFiles(Self.latestMac).count, 3)
    }

    func testElectronSourceFromAppUpdateYML() {
        let github = SourceResolver.electronDefinition("x", ["provider": "github", "owner": "acme", "repo": "app"])
        XCTAssertEqual(github?.repository, "acme/app")
        let generic = SourceResolver.electronDefinition("x", ["provider": "generic", "url": "https://dl.example.com/app"])
        XCTAssertEqual(generic?.feedURL, "https://dl.example.com/app")
        XCTAssertNil(SourceResolver.electronDefinition("x", ["provider": "generic", "url": "http://insecure.example.com"]))
        let s3 = SourceResolver.electronDefinition("x", ["provider": "s3", "bucket": "b", "region": "eu-west-2", "path": "/mac/"])
        XCTAssertEqual(s3?.feedURL, "https://s3.eu-west-2.amazonaws.com/b/mac")
    }

    func testGitHubAssetChoice() {
        typealias A = UpdateFinder.GitHubRelease.Asset
        let assets = [
            A(name: "App-1.0-x64.dmg", browserDownloadUrl: "x64", size: 1, digest: nil),
            A(name: "App-1.0-arm64.dmg", browserDownloadUrl: "arm", size: 1, digest: "sha256:ABC"),
            A(name: "App-1.0-universal.zip", browserDownloadUrl: "uni", size: 1, digest: nil),
            A(name: "App-1.0.exe", browserDownloadUrl: "win", size: 1, digest: nil),
            A(name: "App-1.0-arm64.dmg.blockmap", browserDownloadUrl: "map", size: 1, digest: nil),
        ]
        XCTAssertEqual(UpdateFinder.pickGitHubAsset(assets, pattern: nil)?.browserDownloadUrl, "arm")
        XCTAssertEqual(UpdateFinder.pickGitHubAsset(assets, pattern: "universal\\.zip$")?.browserDownloadUrl, "uni")
    }

    func testJSONSourceWithPathsAndTemplate() throws {
        let fixtures = try Fixtures()
        let feed = try fixtures.write(#"{"releases":[{"version":"156.0.1","serving":{"startTime":"2026-10-20T19:57:09.680119Z"}}]}"#, to: "v.json")
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let source = AppSourceDefinition(bundleIdentifier: "x", kind: .json, feedURL: feed.absoluteString,
                                         versionPath: "releases.0.version", releaseDatePath: "releases.0.serving.startTime",
                                         downloadURL: "https://example.com/{version}/App.dmg")
        let update = try XCTUnwrap(finder.latest(for: app(short: "1", build: "1"), source: source))
        XCTAssertEqual(update.version, "156.0.1")
        XCTAssertEqual(update.downloadURL, "https://example.com/156.0.1/App.dmg")
        XCTAssertNotNil(update.releaseDate)
    }

    func testJSONSourceWithPattern() throws {
        let fixtures = try Fixtures()
        let feed = try fixtures.write("<html>Latest version: <b>4.2.1</b></html>", to: "page.html")
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let source = AppSourceDefinition(bundleIdentifier: "x", kind: .json, feedURL: feed.absoluteString,
                                         versionPattern: "Latest version: <b>([0-9.]+)</b>", downloadURL: "https://e/{version}.zip")
        XCTAssertEqual(try finder.latest(for: app(short: "1", build: "1"), source: source)?.version, "4.2.1")
    }

    func testJSONSourceWithDownloadPath() throws {
        let fixtures = try Fixtures()
        let feed = try fixtures.write(#"{"currentRelease":"3.6556.2","releases":[{"version":"3.6556.2","updateTo":{"version":"3.6556.2","pub_date":"2026-10-22T23:07:11.824Z","url":"https://example.com/3.6556.2/App-20c019a1.zip"}}]}"#, to: "RELEASES.json")
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        var source = AppSourceDefinition(bundleIdentifier: "x", kind: .json, feedURL: feed.absoluteString,
                                         versionPath: "releases.0.updateTo.version", releaseDatePath: "releases.0.updateTo.pub_date",
                                         downloadPath: "releases.0.updateTo.url")
        XCTAssertNoThrow(try source.validate())
        let update = try XCTUnwrap(finder.latest(for: app(short: "3.6000.0", build: "3.6000.0"), source: source))
        XCTAssertEqual(update.version, "3.6556.2")
        XCTAssertEqual(update.downloadURL, "https://example.com/3.6556.2/App-20c019a1.zip")
        XCTAssertNotNil(update.releaseDate)

        source.downloadPath = "releases.0.updateTo.missing"
        XCTAssertThrowsError(try finder.latest(for: app(short: "1", build: "1"), source: source))
    }

    func testJSONSourceNeedsOneDownload() throws {
        let base: [String: Any] = ["BundleIdentifier": "x", "Type": "JSON", "FeedURL": "https://e/v.json", "VersionPath": "v"]
        XCTAssertThrowsError(try AppSourceDefinition(plist: base), "no download")
        XCTAssertEqual(try AppSourceDefinition(plist: base.merging(["DownloadPath": "url"]) { $1 }).downloadPath, "url")
        XCTAssertThrowsError(try AppSourceDefinition(plist: base.merging(["DownloadPath": "url", "DownloadURL": "https://e/{version}.zip"]) { $1 }),
                             "DownloadURL and DownloadPath together")
    }

    func testBuiltInCatalog() throws {
        var seen = Set<String>()
        for entry in BuiltInCatalog.entries {
            XCTAssertNoThrow(try entry.validate(), entry.bundleIdentifier)
            XCTAssertNotNil(entry.expectedTeamIdentifier, "\(entry.bundleIdentifier) must pin a Team ID")
            XCTAssertTrue(seen.insert(entry.bundleIdentifier.lowercased()).inserted, "\(entry.bundleIdentifier) is listed twice")
        }
        XCTAssertEqual(BuiltInCatalog.entry(for: "MD.OBSIDIAN")?.repository, "obsidianmd/obsidian-releases")
        let assets = ["obsidian-1.14.5-arm64.tar.gz", "obsidian-1.14.5.asar.gz", "Obsidian-1.14.5.dmg", "obsidian-1.14.5.tar.gz"]
            .map { UpdateFinder.GitHubRelease.Asset(name: $0, browserDownloadUrl: $0, size: 1, digest: nil) }
        XCTAssertEqual(UpdateFinder.pickGitHubAsset(assets, pattern: BuiltInCatalog.entry(for: "md.obsidian")?.assetPattern)?.name,
                       "Obsidian-1.14.5.dmg")
    }

    func testSquirrelFeed() throws {
        let fixtures = try Fixtures()
        let base = try fixtures.folder("vscode")
        let endpoint = base.appendingPathComponent("api/update/darwin-arm64/stable/latest")
        try FileManager.default.createDirectory(at: endpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"url":"https://example.com/VSCode-darwin-arm64.zip","name":"1.143.1","version":"e646868","productVersion":"1.143.1","timestamp":1792690529437,"sha256hash":"65CED7"}"#.utf8).write(to: endpoint)
        let finder = UpdateFinder(config: Fixtures.testConfiguration(), log: Fixtures.quietLog())
        let update = try XCTUnwrap(finder.latest(for: app(short: "1.100.0", build: "1.100.0"),
                                                 source: AppSourceDefinition(bundleIdentifier: "x", kind: .squirrel, feedURL: base.absoluteString, channel: "stable")))
        XCTAssertEqual(update.version, "1.143.1")
        XCTAssertEqual(update.sha256, "65ced7")
        XCTAssertEqual(update.releaseDate.map { Int($0.timeIntervalSince1970) }, 1792690529)
    }

    func testDates() {
        XCTAssertNotNil(DateParsing.parse("Tue, 20 Oct 2026 10:00:00 +0000"))
        XCTAssertNotNil(DateParsing.parse("Tue, 20 Oct 2026 10:00:00 GMT"))
        XCTAssertNotNil(DateParsing.parse("2026-10-22T17:14:30"))
        XCTAssertNotNil(DateParsing.parse("2026-10-20T19:57:09.680119Z"))
        XCTAssertNil(DateParsing.parse("next Tuesday"))
        XCTAssertEqual(DateParsing.fromEpoch(1792690529437).map { Int($0.timeIntervalSince1970) }, 1792690529)
    }

    func testEdDSA() throws {
        let fixtures = try Fixtures()
        let file = try fixtures.write("the update", to: "update.zip")
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data("the update".utf8)).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(try Archive.verifyEdDSA(file: file, signature: signature, publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(try Archive.verifyEdDSA(file: file, signature: signature, publicKey: other))
        XCTAssertThrowsError(try Archive.verifyEdDSA(file: file, signature: signature, publicKey: "not a key"))
    }

    func testArchiveKindIsSniffed() throws {
        let fixtures = try Fixtures()
        let app = try fixtures.makeApp(in: fixtures.folder("a"), version: "1.0")
        let zip = try fixtures.zip(app, as: "named.dmg") // wrong extension on purpose
        XCTAssertEqual(ArchiveKind.detect(zip), .zip)
        XCTAssertNil(ArchiveKind.detect(try fixtures.write("<html>not found</html>", to: "x.zip")))
        // A bzip2-compressed disk image starts with "BZh" but is still a disk image.
        let image = fixtures.root.appendingPathComponent("bz.dmg")
        // hdiutil sometimes fails on CI runners for no reason it reports, so try a few times.
        var made = try Command.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", app.deletingLastPathComponent().path,
                                                        "-format", "UDBZ", image.path])
        for _ in 0..<3 where made.status != 0 {
            try? FileManager.default.removeItem(at: image)
            Thread.sleep(forTimeInterval: 2)
            made = try Command.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", app.deletingLastPathComponent().path,
                                                        "-format", "UDBZ", image.path])
        }
        XCTAssertEqual(made.status, 0, made.stderrString)
        XCTAssertEqual(ArchiveKind.detect(image), .diskImage)
    }
}
