import AppKit
import BarkeepCore
import Foundation
import Observation

/// What Barkeep.app shows: the daemon's `State.json` (for a standard user, their own view of it,
/// without other people's apps), reloaded whenever the daemon writes it, and the requests the
/// user makes to the daemon.
@MainActor @Observable
final class BarModel {
    private(set) var state: State?
    private(set) var configuration = Configuration()
    private(set) var configurationWarnings: [String] = []
    /// Shown under the toolbar while a request runs, and after it only if it failed. A successful
    /// answer ("2 updates found") would repeat the summary and go stale as the state moves on.
    var banner: String?
    private(set) var checking = false
    /// Paths being updated at the user's request.
    private(set) var updating: Set<String> = []
    /// Called after every reload, for the agent's duties.
    @ObservationIgnored var onReload: ((State) -> Void)?

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let startedFrom = Bundle.main.executablePath.flatMap(FileIdentity.init(path:))

    init() {
        reload()
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.model.reload() }
        }
    }

    var apps: [AppRecord] { state?.apps ?? [] }
    var waiting: [AppRecord] { apps.filter { $0.available != nil && $0.status != .managedElsewhere } }
    var attention: [AppRecord] { apps.filter { [.closingSoon, .waitingForQuit, .failed].contains($0.status) } }
    var userUpdatesAllowed: Bool { state?.allowUserInitiatedUpdates ?? configuration.allowUserInitiatedUpdates }

    var summary: String {
        guard let state else { return "Barkeep's service hasn't reported yet" }
        let monitored = state.apps.filter { ![.excluded, .apple, .noSource].contains($0.status) }.count
        switch waiting.count {
        case 0: return "All \(monitored) monitored apps are up to date"
        case 1: return "1 update waiting"
        default: return "\(waiting.count) updates waiting"
        }
    }

    func reload() {
        // A new Barkeep.app was installed: as the agent, exit so launchd starts the new one.
        if CommandLine.arguments.contains(BarkeepApp.agentArgument), let startedFrom,
           Bundle.main.executablePath.flatMap(FileIdentity.init(path:)) != startedFrom {
            exit(1)
        }
        let (config, warnings) = ConfigurationLoader().load()
        configuration = config
        configurationWarnings = warnings
        let fresh = State.loadForCurrentUser()
        guard fresh != state else { return }
        state = fresh
        if let fresh { onReload?(fresh) }
    }

    /// `State.json` is replaced on every save, so watch its folder rather than the file.
    private func watch() {
        let fd = open(State.directory, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.model.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: Requests

    func checkNow() {
        guard !checking else { return }
        checking = true
        banner = "Checking for updates…"
        Task.detached {
            let failure = Self.failure(of: .checkNow)
            await MainActor.run {
                self.checking = false
                self.banner = failure
                self.reload()
            }
        }
    }

    /// Asks the daemon to update one app now. If it is open, the daemon asks Barkeep to quit it
    /// first, so the caller confirms with the user before this.
    func updateNow(_ record: AppRecord) {
        let path = record.app.path
        guard !updating.contains(path) else { return }
        updating.insert(path)
        banner = "Updating \(record.app.name)…"
        Task.detached {
            let failure = Self.failure(of: .updateNow(path: path))
            await MainActor.run {
                self.updating.remove(path)
                self.banner = failure
                self.reload()
            }
        }
    }

    /// Sends a request to the daemon and returns why it failed, or nil if it worked.
    private nonisolated static func failure(of request: DaemonRequest) -> String? {
        do {
            let reply = try DaemonClient.send(request)
            return reply.ok ? nil : reply.message
        } catch {
            return "\(error)"
        }
    }

    func isRunning(_ record: AppRecord) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == record.app.path }
    }
}

extension AppStatus {
    var label: String {
        switch self {
        case .upToDate: "Up to date"
        case .excluded: "Excluded"
        case .apple: "Apple"
        case .noSource: "Unknown source"
        case .managedElsewhere: "Updated elsewhere"
        case .coolingOff: "Cooling off"
        case .waitingForQuit: "Waiting to close"
        case .closingSoon: "Closing soon"
        case .installing: "Installing"
        case .updated: "Updated"
        case .failed: "Problem"
        }
    }

    var symbol: String {
        switch self {
        case .upToDate, .updated: "checkmark.circle.fill"
        case .excluded: "minus.circle"
        case .apple: "apple.logo"
        case .noSource: "questionmark.circle"
        case .managedElsewhere: "arrow.triangle.2.circlepath"
        case .coolingOff: "hourglass"
        case .waitingForQuit: "clock"
        case .closingSoon: "exclamationmark.circle.fill"
        case .installing: "arrow.down.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
