import CryptoKit
import Darwin
import Foundation

/// What a download turned out to be, from its first and last bytes rather than its name.
public enum ArchiveKind: String, Codable, Sendable {
    case zip, diskImage, package, tar

    public static func detect(_ url: URL) -> ArchiveKind? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        let bytes = [UInt8](head)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if bytes.starts(with: Array("xar!".utf8)) { return .package }
        // UDIF images end with a 512-byte "koly" trailer. Checked before the compression magic
        // numbers, because a compressed image can start with a bzip2 or gzip chunk.
        if let size = try? handle.seekToEnd(), size >= 512 {
            try? handle.seek(toOffset: size - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) { return .diskImage }
        }
        if bytes.starts(with: [0x1F, 0x8B]) || bytes.starts(with: Array("BZh".utf8))
            || bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tar }
        return nil
    }
}

/// Opens downloads and finds the app inside them.
public enum Archive {
    static let extractTimeout: TimeInterval = 1800

    /// Extracts a zip or tar archive into `directory` (which must be empty and private).
    static func extract(_ archive: URL, kind: ArchiveKind, into directory: URL) throws {
        let result: CommandResult
        switch kind {
        case .zip:
            // ditto keeps the symlinks and extended attributes that app bundles in zips rely on.
            result = try Command.run("/usr/bin/ditto", ["-x", "-k", "--noqtn", archive.path, directory.path], timeout: extractTimeout)
        case .tar:
            result = try Command.run("/usr/bin/bsdtar", ["-x", "-f", archive.path, "-C", directory.path,
                                                         "--no-same-owner", "--no-same-permissions"], timeout: extractTimeout)
        case .diskImage, .package:
            return
        }
        guard result.status == 0, !result.timedOut else {
            throw BarkeepError(.archiveError, "Cannot extract \(archive.lastPathComponent): \(result.timedOut ? "timed out" : result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The app with `bundleID` at the top of `roots` or one folder down. Exactly one must match.
    static func findApp(bundleID: String, in roots: [URL]) throws -> URL {
        var matches: [URL] = []
        var others: [String] = []
        func look(_ folder: URL, depth: Int) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") && name != "__MACOSX" {
                let url = folder.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                if url.pathExtension.lowercased() == "app" {
                    if let bundle = try? AppBundle(url: url), bundle.bundleIdentifier == bundleID {
                        matches.append(url)
                    } else {
                        others.append(name)
                    }
                } else if depth < 2 {
                    look(url, depth: depth + 1)
                }
            }
        }
        roots.forEach { look($0, depth: 1) }
        guard !matches.isEmpty else {
            let found = others.isEmpty ? "no app" : others.joined(separator: ", ")
            throw BarkeepError(.bundleIDMismatch, "The download does not contain \(bundleID) (found \(found))")
        }
        guard matches.count == 1 else {
            throw BarkeepError(.archiveError, "The download contains \(matches.count) copies of \(bundleID); refusing to guess")
        }
        return matches[0]
    }

    // MARK: Checksums

    /// Hex SHA-256 and base64 SHA-512 of a file, read in chunks.
    static func digests(of url: URL) throws -> (sha256: String, sha512: String) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw BarkeepError(.archiveError, "Cannot read \(url.path)") }
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha512 = SHA512()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            sha256.update(data: chunk)
            sha512.update(data: chunk)
        }
        let hex = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        return (hex, Data(sha512.finalize()).base64EncodedString())
    }

    /// Checks a Sparkle EdDSA (Ed25519) signature of the whole file.
    static func verifyEdDSA(file url: URL, signature: String, publicKey: String) throws -> Bool {
        guard let keyData = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw BarkeepError(.checksumMismatch, "The installed app's SUPublicEDKey is not a valid Ed25519 key")
        }
        guard let signatureData = Data(base64Encoded: signature) else { return false }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return key.isValidSignature(signatureData, for: data)
    }
}
