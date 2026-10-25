import Foundation

/// Removes everything barkeep's package installed, and what barkeep wrote since. Root only.
public enum Uninstaller {
    public struct Report: Codable, Sendable {
        public var removed: [String] = []
        public var problems: [String] = []
    }

    static var items: [String] {
        [Paths.daemonPlistPath, Paths.agentPlistPath, Paths.appPath, Paths.binaryPath, State.directory,
         "/Library/Logs/barkeep.log", UpdateLock.rootPath]
    }

    public static func uninstall(dryRun: Bool) -> Report {
        var report = Report()
        if !dryRun {
            // The agent runs in every logged-in user's session; the daemon in the system domain.
            for user in (try? TargetUser.localAccounts()) ?? [] {
                _ = try? Command.run("/bin/launchctl", ["bootout", "gui/\(user.uid)/\(Paths.agentLabel)"], timeout: 30)
            }
            _ = try? Command.run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"], timeout: 30)
            // Before the binary goes: the system checks the code of whoever changes a right.
            if SettingsAuthorization.unregister() {
                report.removed.append("authorization right \(SettingsAuthorization.right)")
            }
        }
        for path in items where FileManager.default.fileExists(atPath: path) {
            if dryRun {
                report.removed.append(path)
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                report.removed.append(path)
            } catch {
                report.problems.append("\(path): \(error.localizedDescription)")
            }
        }
        if !dryRun, (try? Command.run("/usr/sbin/pkgutil", ["--forget", Paths.packageIdentifier], timeout: 60))?.status == 0 {
            report.removed.append("package receipt \(Paths.packageIdentifier)")
        }
        return report
    }
}
