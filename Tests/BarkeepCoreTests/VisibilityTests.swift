import Darwin
import Foundation
import XCTest
@testable import BarkeepCore

final class VisibilityTests: XCTestCase {
    let alex = TargetUser(name: "alex", uid: 9501, gid: 20, home: URL(fileURLWithPath: "/Users/alex"))
    let al = TargetUser(name: "al", uid: 9502, gid: 20, home: URL(fileURLWithPath: "/Users/al"))
    var visibility: Visibility { Visibility(accounts: [alex, al]) }

    func record(_ path: String) -> AppRecord {
        let app = InstalledApp(path: path, name: (path as NSString).lastPathComponent, bundleIdentifier: "com.example.app",
                               shortVersion: "1", buildVersion: nil, ownerUID: 0, signing: nil, signatureProblem: nil,
                               designatedRequirement: nil, metadata: UpdateMetadata())
        return AppRecord(app: app, status: .upToDate, message: "")
    }

    func testAppsInAHomeBelongToItsOwner() {
        XCTAssertEqual(visibility.owner(of: "/Users/alex/Applications/Tool.app")?.uid, 9501)
        XCTAssertEqual(visibility.owner(of: "/Users/al/Applications/Tool.app")?.uid, 9502, "/Users/al is not inside /Users/alex")
        XCTAssertEqual(visibility.owner(of: "/USERS/Alex/Desktop/Tool.app")?.uid, 9501, "case doesn't matter on APFS")
        XCTAssertEqual(visibility.owner(of: "/Users/alex/../al/Tool.app")?.uid, 9502)
        XCTAssertNil(visibility.owner(of: "/Applications/Tool.app"))
        XCTAssertNil(visibility.owner(of: "/Users/Shared/Tool.app"))
        let root = TargetUser(name: "odd", uid: 9503, gid: 20, home: URL(fileURLWithPath: "/"))
        XCTAssertNil(Visibility(accounts: [root]).owner(of: "/Applications/Tool.app"), "a home of / owns nothing")
    }

    func testAViewLeavesOutOtherPeoplesApps() {
        var state = State()
        state.apps = ["/Applications/Shared.app", "/Users/alex/Applications/Alex.app", "/Users/al/Applications/Al.app"].map(record)
        XCTAssertEqual(visibility.view(of: state, for: 9501).apps.map(\.app.name), ["Shared.app", "Alex.app"])
        XCTAssertEqual(visibility.view(of: state, for: 9502).apps.map(\.app.name), ["Shared.app", "Al.app"])
        XCTAssertEqual(visibility.view(of: state, for: 9600).apps.map(\.app.name), ["Shared.app"])
        XCTAssertTrue(visibility.isVisible("/Users/alex/Applications/Alex.app", to: 0))
    }

    func testStateIsNotReadableByEveryone() throws {
        let fixtures = try Fixtures()
        let path = fixtures.root.appendingPathComponent("State.json").path
        var state = State()
        try state.save(to: path)
        try state.save(to: path)
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o640)
        XCTAssertEqual(State.load(from: path, requireRootOwnership: false)?.generation, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixtures.root.path), ["State.json"], "no temporary files left")
    }

    func testSavingReplacesASymlinkRatherThanFollowingIt() throws {
        let fixtures = try Fixtures()
        let target = try fixtures.write("keep", to: "target")
        let path = fixtures.root.appendingPathComponent("State.json").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        var state = State()
        try state.save(to: path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        XCTAssertNotNil(State.load(from: path, requireRootOwnership: false))
    }

    func testEachAccountGetsItsOwnPrivateView() throws {
        let fixtures = try Fixtures()
        let me = try XCTUnwrap(TargetUser.lookup(uid: getuid()))
        let mine = TargetUser(name: me.name, uid: me.uid, gid: me.gid, home: fixtures.root)
        let views = fixtures.root.appendingPathComponent("Users").path
        try FileManager.default.createDirectory(atPath: views, withIntermediateDirectories: true)
        let stale = State.viewPath(for: 4242, in: views)
        FileManager.default.createFile(atPath: stale, contents: Data())

        var state = State()
        state.apps = [record("/Applications/Shared.app"), record(fixtures.root.path + "/Applications/Mine.app"),
                      record("/Users/alex/Applications/Alex.app")]
        try state.saveViews(Visibility(accounts: [mine, alex]), to: views)

        let path = State.viewPath(for: me.uid, in: views)
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let view = try XCTUnwrap(State.load(from: path, requireRootOwnership: false))
        XCTAssertEqual(view.apps.map(\.app.name), ["Shared.app", "Mine.app"])
        let theirs = State.viewPath(for: 9501, in: views)
        XCTAssertEqual(State.load(from: theirs, requireRootOwnership: false)?.apps.map(\.app.name), ["Shared.app", "Alex.app"])
        let acl = acl_get_file(theirs, ACL_TYPE_EXTENDED)
        XCTAssertNotNil(acl, "shared with its account by an ACL")
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale), "the views of accounts that are gone are removed")
        XCTAssertEqual(lstat(views, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o711, "the folder can't be listed")
    }

    func testLeasesDontNameTheirAppsAndCanBePrivate() throws {
        let fixtures = try Fixtures()
        let leases = fixtures.root.appendingPathComponent("Leases").path
        let app = record("/Users/alex/Applications/Secret.app").app
        let lease = try UpdateLease.acquire(for: app, directory: leases, privateTo: getuid())
        let names = try FileManager.default.contentsOfDirectory(atPath: leases)
        XCTAssertEqual(names.count, 1)
        XCTAssertNotNil(names[0].wholeMatch(of: /[0-9a-f]{64}\.json/), "a hash, not the path")
        var st = stat()
        XCTAssertEqual(lstat(leases + "/" + names[0], &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(UpdateLease.live(directory: leases, requireRootOwnership: false).map(\.path), [app.path])
        lease.release(directory: leases)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: leases).isEmpty)
    }
}
