import BarkeepCore
import Foundation
import Observation
import Security

/// The Settings window's lock. Unlocking asks for an administrator's name and password, which
/// this authorization then holds for a few minutes; each change sends it to the daemon, which
/// checks it again before writing anything. Barkeep.app itself changes nothing.
@MainActor @Observable
final class SettingsAuthorizer {
    private(set) var unlocked = false
    private(set) var unlocking = false
    /// Keys whose change is on its way to the daemon.
    private(set) var saving: Set<String> = []
    /// Why the last change or unlock failed.
    var problem: String?

    @ObservationIgnored private var authorization: Authorization?

    /// An `AuthorizationRef`, freed with its holder. Only used from one task at a time.
    final class Authorization: @unchecked Sendable {
        let ref: AuthorizationRef
        init?() {
            var ref: AuthorizationRef?
            guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
            self.ref = ref
        }
        deinit { AuthorizationFree(ref, [.destroyRights]) }

        /// Asks for the password if needed (the system shows the dialog).
        func obtain() -> OSStatus {
            SettingsAuthorization.right.withCString { name in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { items in
                    var rights = AuthorizationRights(count: 1, items: items)
                    return AuthorizationCopyRights(ref, &rights, nil, [.extendRights, .interactionAllowed, .preAuthorize], nil)
                }
            }
        }

        var externalForm: Data? {
            var form = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else { return nil }
            return withUnsafeBytes(of: &form) { Data($0) }
        }
    }

    func unlock() {
        guard !unlocked, !unlocking else { return }
        guard let fresh = Authorization() else {
            problem = "Couldn't ask for an administrator's password"
            return
        }
        unlocking = true
        problem = nil
        Task.detached {
            let status = fresh.obtain()
            await MainActor.run {
                self.unlocking = false
                switch status {
                case errAuthorizationSuccess:
                    self.authorization = fresh
                    self.unlocked = true
                case errAuthorizationCanceled:
                    break
                default:
                    self.problem = "That name and password can't change Barkeep's settings (error \(status))"
                }
            }
        }
    }

    func lock() {
        authorization = nil
        unlocked = false
    }

    /// Sends one change (nil: back to the default), then reloads the settings.
    func change(_ key: String, to value: LocalSettings.Value?, model: BarModel) {
        guard unlocked, let form = authorization?.externalForm else { return }
        saving.insert(key)
        problem = nil
        Task.detached {
            let failure: String?
            do {
                let reply = try DaemonClient.send(.changeSetting(key: key, value: value, authorization: form))
                failure = reply.ok ? nil : reply.message
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                self.saving.remove(key)
                self.problem = failure
                // The password has timed out: lock again so the next change asks for it.
                if failure?.contains("password") == true { self.lock() }
                model.reload()
            }
        }
    }
}
