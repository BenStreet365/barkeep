import Foundation
@preconcurrency import XPC

/// What Barkeep.app (or `barkeep` run without root) can ask the daemon to do. A request carries
/// nothing the daemon trusts: "update now" still goes through every check and the cooling-off
/// period, and only skips the wait for the app to quit (Barkeep.app asks it to quit instead).
public enum DaemonRequest: Codable, Sendable {
    case ping
    /// Check every feed now.
    case checkNow
    /// Update one app now, by path.
    case updateNow(path: String)
}

public struct DaemonReply: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var record: AppRecord?

    public init(ok: Bool, message: String, record: AppRecord? = nil) {
        self.ok = ok
        self.message = message
        self.record = record
    }
}

/// Requests and replies travel as JSON over the C XPC API, which (unlike `XPCListener`) tells the
/// daemon who is asking, so it can keep other people's apps out of its replies.
enum DaemonWire {
    static let requestKey = "request"
    static let replyKey = "reply"

    static func data(_ object: xpc_object_t, _ key: String) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(object, key, &length) else { return nil }
        return Data(bytes: bytes, count: length)
    }

    static func set(_ data: Data, _ key: String, in object: xpc_object_t) {
        data.withUnsafeBytes { xpc_dictionary_set_data(object, key, $0.baseAddress!, $0.count) }
    }
}

public enum DaemonClient {
    /// Sends a request and waits for the reply, which for an update can take minutes. Throws if
    /// the daemon cannot be reached.
    public static func send(_ request: DaemonRequest) throws -> DaemonReply {
        let unreachable = BarkeepError(.daemonUnavailable, "Cannot reach the barkeep daemon (\(Daemon.label)). Installing barkeep's package again sets it up.")
        // Privileged: only the system's launchd may answer, never a service a user set up.
        let connection = xpc_connection_create_mach_service(Daemon.label, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }
        let message = xpc_dictionary_create(nil, nil, 0)
        DaemonWire.set(try JSONEncoder().encode(request), DaemonWire.requestKey, in: message)
        let reply = xpc_connection_send_message_with_reply_sync(connection, message)
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, let data = DaemonWire.data(reply, DaemonWire.replyKey) else { throw unreachable }
        do {
            return try JSONDecoder().decode(DaemonReply.self, from: data)
        } catch {
            throw BarkeepError(.daemonUnavailable, "The barkeep daemon sent a reply this version cannot read")
        }
    }
}

/// The LaunchDaemon (`barkeep daemon`, run by launchd as root). Every minute it goes over the
/// known apps, which costs nothing unless an update is waiting; it looks for new apps every half
/// hour and checks each feed every `CheckIntervalMinutes`. It also answers Barkeep.app's requests
/// and keeps barkeep itself up to date.
public final class Daemon: @unchecked Sendable {
    public static let label = Paths.daemonLabel
    static let tickInterval: TimeInterval = 60
    static let rescanInterval: TimeInterval = 30 * 60
    static let selfUpdateInterval: TimeInterval = 3600
    /// How long Update Now waits for an open app to quit (in 2-second steps).
    static let quitWaitSteps = 45

    let makeConfiguration: @Sendable () -> Configuration
    let log: Log
    let helperExecutable: String?
    let version: String
    let work = DispatchQueue(label: "\(Configuration.domain).work")
    private var lastSelfUpdate: Date?
    private let startedFrom: FileIdentity?

    public init(log: Log, helperExecutable: String?, version: String, makeConfiguration: @escaping @Sendable () -> Configuration) {
        self.log = log
        self.helperExecutable = helperExecutable
        self.version = version
        self.makeConfiguration = makeConfiguration
        startedFrom = helperExecutable.flatMap(FileIdentity.init(path:))
    }

    /// A package replaced the binary (a self-update, or one from the MDM): exit, and launchd
    /// starts the new one.
    func restartIfReplaced() {
        guard let startedFrom, let path = helperExecutable, FileIdentity(path: path) != startedFrom else { return }
        log.info("barkeep was replaced on disk; restarting")
        exit(0)
    }

    func makeBarkeeper() -> (Barkeeper, Configuration) {
        let config = makeConfiguration()
        return (Barkeeper(config: config, log: log, helperExecutable: helperExecutable), config)
    }

    /// One pass. Runs on `work`, so passes never overlap.
    @discardableResult
    func tick(checkFeeds: Bool = false, requested: Set<String> = [], forceRescan: Bool = false) -> State {
        let (barkeeper, _) = makeBarkeeper()
        _ = UpdateLease.live(cleanUp: true)
        let state = barkeeper.loadState()
        var options = CycleOptions()
        options.checkFeeds = checkFeeds
        options.requestedPaths = requested
        options.rescan = forceRescan || checkFeeds || state.apps.isEmpty
            || state.lastScan.map { Date().timeIntervalSince($0) >= Self.rescanInterval } ?? true
        let lock: UpdateLock
        do {
            lock = try UpdateLock(timeout: 5)
        } catch {
            log.debug("Skipping a pass: \(error)")
            return state
        }
        defer { lock.release() }
        return barkeeper.cycle(options)
    }

    func selfUpdateIfDue() {
        guard lastSelfUpdate.map({ Date().timeIntervalSince($0) >= Self.selfUpdateInterval }) ?? true else { return }
        lastSelfUpdate = Date()
        let updater = SelfUpdater(config: makeConfiguration(), log: log, currentVersion: version)
        updater.executablePath = helperExecutable
        let report = updater.run(checkOnly: false, mode: .automatic)
        if report.action == .updated {
            // launchd starts the new binary (KeepAlive).
            log.info("Restarting into barkeep \(report.availableVersion ?? "")")
            exit(0)
        }
    }

    /// Answers a request from `uid`. Someone who isn't an administrator hears nothing about the
    /// apps in other people's home folders: not even whether they exist.
    func handle(_ request: DaemonRequest, from uid: uid_t) -> DaemonReply {
        let config = makeConfiguration()
        switch request {
        case .ping:
            return DaemonReply(ok: true, message: "barkeep \(version)")
        case .checkNow:
            guard config.allowUserInitiatedUpdates else { return DaemonReply(ok: false, message: "Your administrator has turned off checking for updates from Barkeep") }
            log.info("A user (uid \(uid)) asked barkeep to check for updates")
            let state = work.sync { tick(checkFeeds: true) }
            let visibility = Visibility.local()
            let waiting = state.apps.filter { $0.available != nil && visibility.isVisible($0.app.path, to: uid) }.count
            return DaemonReply(ok: true, message: waiting == 0 ? "All apps are up to date" : "\(waiting) update\(waiting == 1 ? "" : "s") found")
        case .updateNow(let path):
            guard config.allowUserInitiatedUpdates else { return DaemonReply(ok: false, message: "Your administrator has turned off updating apps from Barkeep") }
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            let notManaged = DaemonReply(ok: false, message: "Barkeep does not manage \(standard)")
            guard Visibility.local().isVisible(standard, to: uid) else { return notManaged }
            log.info("A user (uid \(uid)) asked barkeep to update \(standard)")
            var state = work.sync { tick(requested: [standard]) }
            // An open app has been asked to quit (Barkeep.app does it); install as soon as it has.
            if state.record(forPath: standard)?.status == .closingSoon {
                let url = URL(fileURLWithPath: standard)
                for _ in 0..<Self.quitWaitSteps where !RunningProcesses.pids(inside: url).isEmpty {
                    Thread.sleep(forTimeInterval: 2)
                }
                if RunningProcesses.pids(inside: url).isEmpty { state = work.sync { tick() } }
            }
            guard let record = state.record(forPath: standard) else { return notManaged }
            return DaemonReply(ok: record.status != .failed, message: record.message, record: record)
        }
    }

    /// One client's connection: each request is answered off the connection's queue, since an
    /// update can take minutes.
    func accept(_ peer: xpc_connection_t) {
        xpc_connection_set_event_handler(peer) { [self] message in
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            // Who connected, as the kernel says: nothing in the message is trusted for this.
            let uid = xpc_connection_get_euid(peer)
            DispatchQueue.global().async { [self] in
                let reply: DaemonReply
                if let data = DaemonWire.data(message, DaemonWire.requestKey),
                   let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) {
                    reply = handle(request, from: uid)
                } else {
                    reply = DaemonReply(ok: false, message: "barkeep \(version) cannot read this request")
                }
                guard let response = xpc_dictionary_create_reply(message), let data = try? JSONEncoder().encode(reply) else { return }
                DaemonWire.set(data, DaemonWire.replyKey, in: response)
                xpc_connection_send_message(peer, response)
            }
        }
        xpc_connection_activate(peer)
    }

    public func run() throws -> Never {
        let listener = xpc_connection_create_mach_service(Self.label, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(listener) { [self] peer in
            if xpc_get_type(peer) == XPC_TYPE_CONNECTION { accept(peer) }
        }
        xpc_connection_activate(listener)
        log.info("barkeep \(version) daemon started")
        // Saved again at once, so an older version's State.json (readable by everyone) is
        // replaced and each user's view written, without waiting for something to change.
        work.async { [self] in
            let (barkeeper, _) = makeBarkeeper()
            var state = barkeeper.loadState()
            barkeeper.save(&state)
        }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 5, repeating: Self.tickInterval, leeway: .seconds(5))
        timer.setEventHandler { [self] in
            restartIfReplaced()
            tick()
            selfUpdateIfDue()
        }
        timer.resume()
        withExtendedLifetime((listener, timer)) { dispatchMain() }
    }
}

/// Which file is at a path: changes when the file is replaced or rewritten.
public struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let modified: Int

    public init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        device = st.st_dev
        inode = st.st_ino
        modified = st.st_mtimespec.tv_sec
    }
}
