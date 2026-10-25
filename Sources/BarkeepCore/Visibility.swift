import Darwin
import Darwin.membership
import Foundation

/// Who may see which apps. An app in someone's home folder is theirs: barkeep keeps it up to date
/// like any other, but only they, administrators and root see it, in Barkeep.app, `barkeep status`,
/// the daemon's replies and the launch guard's leases. Apps anywhere else are everyone's.
public struct Visibility: Sendable {
    public let accounts: [TargetUser]

    public init(accounts: [TargetUser]) {
        self.accounts = accounts
    }

    /// Every local account, and the console user if it is not one (a network account).
    public static func local() -> Visibility {
        var accounts = (try? TargetUser.localAccounts()) ?? []
        if let console = TargetUser.consoleUser(), !accounts.contains(where: { $0.uid == console.uid }) {
            accounts.append(console)
        }
        return Visibility(accounts: accounts)
    }

    /// The account whose home folder `path` is in, if any (the deepest, if homes are nested).
    /// Compared without case, as on the default APFS volume, so a path can only match too often.
    public func owner(of path: String) -> TargetUser? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        return accounts
            .map { ($0, $0.home.standardizedFileURL.path.lowercased()) }
            .filter { $0.1 != "/" && (path == $0.1 || path.hasPrefix($0.1 + "/")) }
            .max { $0.1.count < $1.1.count }?.0
    }

    /// Whether `uid` may see the app at `path`.
    public func isVisible(_ path: String, to uid: uid_t) -> Bool {
        if uid == 0 || TargetUser.isAdmin(uid: uid) { return true }
        return owner(of: path).map { $0.uid == uid } ?? true
    }

    /// `state` without the apps in other people's home folders.
    public func view(of state: State, for uid: uid_t) -> State {
        var view = state
        view.apps = state.apps.filter { owner(of: $0.app.path).map { $0.uid == uid } ?? true }
        return view
    }
}

extension TargetUser {
    /// The `admin` group, whose members may see every app.
    public static let adminGroupID: gid_t = getgrnam("admin")?.pointee.gr_gid ?? 80

    /// Whether `uid` is an administrator (a member of `admin`, directly or through another group).
    public static func isAdmin(uid: uid_t) -> Bool {
        guard var user = uuid(forUID: uid) else { return false }
        var group = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var isMember: Int32 = 0
        let ok = withUnsafeMutableBytes(of: &user) { u in
            withUnsafeMutableBytes(of: &group) { g in
                mbr_gid_to_uuid(adminGroupID, g.baseAddress!.assumingMemoryBound(to: UInt8.self)) == 0
                    && mbr_check_membership(u.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                            g.baseAddress!.assumingMemoryBound(to: UInt8.self), &isMember) == 0
            }
        }
        return ok && isMember != 0
    }

    static func uuid(forUID uid: uid_t) -> uuid_t? {
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let status = withUnsafeMutableBytes(of: &uuid) { mbr_uid_to_uuid(uid, $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        return status == 0 ? uuid : nil
    }
}

/// Files that are replaced whole and must never be readable by more people than they end up with.
enum ProtectedFile {
    /// Writes `data` to a new file beside `path` (created mode 0600), sets its group, permissions
    /// and an ACL letting `reader` read it, and only then renames it over `path`. Readers never see
    /// a partial file, and a symlink at `path` is replaced, not followed.
    static func write(_ data: Data, to path: String, mode: mode_t, group: gid_t? = nil, reader: uid_t? = nil) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var template = Array("\(directory)/.\(name).XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw posixError("Cannot create a file in \(directory)") }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary) }
        }
        if let group, fchown(fd, uid_t.max, group) != 0 { throw posixError("Cannot set the group of \(path)") }
        if let reader { try allowRead(fd, by: reader, path: path) }
        guard fchmod(fd, mode) == 0 else { throw posixError("Cannot set the permissions of \(path)") }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw posixError("Cannot write \(path)") }
                offset += n
            }
        }
        guard rename(temporary, path) == 0 else { throw posixError("Cannot replace \(path)") }
        renamed = true
    }

    /// Adds an ACL entry letting `uid` read the open file.
    private static func allowRead(_ fd: Int32, by uid: uid_t, path: String) throws {
        guard var qualifier = TargetUser.uuid(forUID: uid) else {
            throw BarkeepError(.failure, "Cannot find the account with uid \(uid) to share \(path) with")
        }
        var acl: acl_t? = acl_init(1)
        guard let made = acl else { throw posixError("Cannot make an ACL for \(path)") }
        defer { acl_free(UnsafeMutableRawPointer(acl ?? made)) }
        var entry: acl_entry_t?
        var permissions: acl_permset_t?
        guard acl_create_entry(&acl, &entry) == 0, let entry,
              acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
              withUnsafeBytes(of: &qualifier, { acl_set_qualifier(entry, $0.baseAddress) }) == 0,
              acl_get_permset(entry, &permissions) == 0, let permissions,
              acl_add_perm(permissions, ACL_READ_DATA) == 0,
              acl_set_permset(entry, permissions) == 0,
              acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else {
            throw posixError("Cannot share \(path) with uid \(uid)")
        }
    }

    private static func posixError(_ message: String) -> BarkeepError {
        BarkeepError(.failure, "\(message): \(String(cString: strerror(errno)))")
    }
}
