import CryptoKit
import Darwin
import Foundation

/// Tamper protection for what the daemon remembers between runs: the releases it has seen, when it
/// first saw each one, where to download them and their checksums. Those dates decide when an
/// update installs, so the daemon must be able to tell its own record from an edited one.
///
/// Every `State.json` the daemon writes is sealed with an HMAC-SHA256 under a random key that only
/// root can read (`Seal.key`, mode 600, beside the state). The daemon only acts on a state whose
/// seal matches. Anything else is discarded and built again from scratch, which can only make
/// updates wait longer, never install sooner. Whatever the state says, every download still has
/// to pass every signature, notarisation and version check before it is installed.
///
/// This protects against anyone but root. Root can read the key, as it can replace barkeep itself.
public struct StateSeal: Sendable {
    public var keyPath: String
    public var sealPath: String
    /// The key and seal are only trusted when owned by root. Tests turn this off.
    public var requireRootOwnership = true

    static let keyLength = 32

    /// The seal for the state in `directory`.
    public init(directory: String = State.directory) {
        keyPath = directory + "/Seal.key"
        sealPath = directory + "/State.seal"
    }

    public enum Verdict: Equatable, Sendable {
        case valid
        /// There is no key and no seal: nothing here was ever sealed (an upgrade from a barkeep
        /// that did not seal its state).
        case neverSealed
        case invalid(String)
    }

    /// The seals on file: of the state as last saved, and of the one before it, which is what
    /// is on disk if barkeep stopped between writing the seal and replacing the state.
    struct Record: Codable, Equatable {
        var current: String
        var previous: String?
    }

    public func verify(_ data: Data) -> Verdict {
        let keyExists = exists(keyPath), sealExists = exists(sealPath)
        if !keyExists, !sealExists { return .neverSealed }
        guard let key = readKey() else { return .invalid("its seal's key is missing or not root's alone") }
        guard let record = readRecord() else { return .invalid("its seal is missing or not root's alone") }
        let code = Self.code(for: data, key: key)
        return Self.matches(code, record.current) || record.previous.map { Self.matches(code, $0) } == true
            ? .valid : .invalid("it does not match its seal, so it was changed by something other than barkeep")
    }

    /// Seals `data`, which is about to replace `existing` (the state file's bytes now, if any).
    public func seal(_ data: Data, replacing existing: Data?) throws {
        let key = try readKey() ?? makeKey()
        var record = Record(current: Self.code(for: data, key: key), previous: nil)
        // Only a file that passes now is vouched for again.
        if let existing, let old = readRecord() {
            let code = Self.code(for: existing, key: key)
            if Self.matches(code, old.current) || old.previous.map({ Self.matches(code, $0) }) == true { record.previous = code }
        }
        try ProtectedFile.write(JSONEncoder().encode(record), to: sealPath, mode: 0o600)
    }

    // MARK: Files

    private func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// A file that only its owner (root) can read or write, never a link.
    private func readPrivate(_ path: String, maxSize: Int) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= maxSize,
              st.st_mode & (S_IRWXG | S_IRWXO) == 0 else { return nil }
        if requireRootOwnership, st.st_uid != 0 { return nil }
        return FileManager.default.contents(atPath: path)
    }

    private func readKey() -> SymmetricKey? {
        guard let data = readPrivate(keyPath, maxSize: Self.keyLength), data.count == Self.keyLength else { return nil }
        return SymmetricKey(data: data)
    }

    private func readRecord() -> Record? {
        readPrivate(sealPath, maxSize: 4096).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    private func makeKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let directory = (keyPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try ProtectedFile.write(key.withUnsafeBytes { Data($0) }, to: keyPath, mode: 0o600)
        return key
    }

    // MARK: Codes

    static func code(for data: Data, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Compared in constant time.
    static func matches(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
