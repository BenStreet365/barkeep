import CryptoKit
import Darwin
import Foundation

/// A short-lived claim that an app is being replaced, so it should not be opened. Barkeep.app
/// watches for launches and closes an app that is opened while a lease on it is live, then opens
/// it again once the update is done.
///
/// A lease is never a lock on the app itself: it is a file in barkeep's own folder that expires
/// on its own (after `maximumDuration`, or as soon as the process holding it is gone), so an update
/// that crashes or hangs cannot keep the app closed.
public struct UpdateLease: Codable, Sendable, Equatable {
    public static let directory = State.directory + "/Leases"
    public static let maximumDuration: TimeInterval = 15 * 60

    public var path: String
    public var bundleIdentifier: String
    public var name: String
    public var holder: pid_t
    public var started: Date
    public var expires: Date

    public var isLive: Bool { isLive(at: Date()) }

    public func isLive(at now: Date, processExists: (pid_t) -> Bool = UpdateLease.processExists) -> Bool {
        now < expires && now >= started.addingTimeInterval(-60) && processExists(holder)
    }

    public static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// A hash of the path, so the folder listing doesn't say which apps are being updated.
    static func fileName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Takes a lease on `app`. Root only; the folder is root-owned. With `privateTo` (an app in
    /// someone's home folder) only root and that user can read it; otherwise everyone can.
    public static func acquire(for app: InstalledApp, duration: TimeInterval = maximumDuration,
                               directory: String = UpdateLease.directory, privateTo reader: uid_t? = nil) throws -> UpdateLease {
        let now = Date()
        let lease = UpdateLease(path: app.path, bundleIdentifier: app.bundleIdentifier, name: app.name, holder: getpid(),
                                started: now, expires: now.addingTimeInterval(min(duration, maximumDuration)))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let file = URL(fileURLWithPath: directory).appendingPathComponent(fileName(for: app.path))
        try ProtectedFile.write(State.encoder.encode(lease), to: file.path, mode: reader == nil ? 0o644 : 0o600, reader: reader)
        return lease
    }

    public func release(directory: String = UpdateLease.directory) {
        unlink(URL(fileURLWithPath: directory).appendingPathComponent(Self.fileName(for: path)).path)
    }

    /// Live leases. Expired ones are deleted when `cleanUp` is set (root).
    public static func live(directory: String = UpdateLease.directory, requireRootOwnership: Bool = true,
                            cleanUp: Bool = false) -> [UpdateLease] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var result: [UpdateLease] = []
        for name in names where name.hasSuffix(".json") {
            let path = directory + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  !requireRootOwnership || (st.st_uid == 0 && st.st_mode & (S_IWGRP | S_IWOTH) == 0),
                  st.st_size < 64 * 1024,
                  let data = FileManager.default.contents(atPath: path),
                  let lease = try? State.decoder.decode(UpdateLease.self, from: data) else { continue }
            if lease.isLive {
                result.append(lease)
            } else if cleanUp {
                unlink(path)
            }
        }
        return result
    }
}
