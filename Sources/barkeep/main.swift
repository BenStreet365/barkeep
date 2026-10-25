import BarkeepCore
import Foundation

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

let usage = """
barkeep \(version) - keeps the apps on a Mac up to date, quietly

USAGE:
  barkeep status [--json]                 What the daemon last found, app by app
  barkeep scan [--json]                   Apps found and how each one updates (no network)
  barkeep check [--app <id|path>] [--json]
                                          Ask each app's update feed what's newest; installs nothing
  barkeep inspect <path.app> [--json]     Everything barkeep knows about one app: signature,
                                          update source and the newest version it offers
  barkeep update <id|path> [--json]       Update one app now (asks it to quit if it is open)
  barkeep run [--app <id|path>] [--check-feeds] [--json]
                                          One full pass, installing what policy allows (root)
  barkeep show-config [--json]            Effective settings and where they came from
  barkeep self-update [--check] [--latest] [--json]
                                          Update barkeep itself from GitHub releases
  barkeep uninstall [--dry-run]           Remove barkeep, Barkeep.app, its daemons and data (root)
  barkeep daemon                          Run as the LaunchDaemon (launchd starts this)
  barkeep version

  The daemon (uk.street365.barkeep.daemon) runs as root. Updates install while apps are
  closed, once they are CoolingOffHours old. An app still open DeadlineDays after its update
  was released (or found, with DeadlineBasis Discovered) is asked to quit, after a warning, DeadlineGraceMinutes beforehand.
  Every update must be signed by the same developer as the installed copy and satisfy its
  designated requirement, match any checksum or EdDSA signature in its feed, pass Gatekeeper
  and be newer.

  Configuration is read from managed preferences (PayloadType \(Configuration.domain)).
  Root may also pass --config <file.plist> for testing.

EXIT CODES:
   0 success (or nothing to do)
   1 unexpected internal error
  10 not authorised (root-only command or option)
  11 app not found
  12 app excluded by the profile
  13 barkeep does not know how this app updates; add it to AppSources
  20 update feed could not be read
  21 download could not be opened or does not hold the app
  22 invalid or missing code signature
  23 rejected by Gatekeeper
  24 signed by another developer, or not the same app (designated requirement)
  25 bundle ID does not match
  26 download does not match its checksum or EdDSA signature
  27 download is not newer
  40 app is open; the update waits until it quits
  41 update held back by the cooling-off period
  42 destination occupied by something else
  43 another barkeep run is busy (retry later)
  44 App Management blocked the update; deploy the App Management profile
  50 install failed
  52 barkeep could not update itself
  53 the daemon could not be reached
  64 usage error
"""

struct Arguments {
    var positional: [String] = []
    var configFile: String?
    var app: String?
    var uid: uid_t?
    var json = false
    var verbose = false
    var quiet = false
    var dryRun = false
    var deep = false
    var checkOnly = false
    var latest = false
    var checkFeeds = false
    var feed: String?
    var allowUnsigned = false

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        func value(_ name: String) throws -> String {
            guard let v = it.next(), !v.isEmpty else { throw BarkeepError(.usage, "\(name) needs a value") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--config": configFile = try value(arg)
            case "--app": app = try value(arg)
            case "--uid":
                guard let n = uid_t(try value(arg)) else { throw BarkeepError(.usage, "--uid needs a number") }
                uid = n
            case "--feed": feed = try value(arg)
            case "--json": json = true
            case "--verbose", "-v": verbose = true
            case "--quiet", "-q": quiet = true
            case "--dry-run", "-n": dryRun = true
            case "--deep": deep = true
            case "--check": checkOnly = true
            case "--latest": latest = true
            case "--check-feeds": checkFeeds = true
            case "--allow-unsigned": allowUnsigned = true
            case "--help", "-h": throw BarkeepError(.success, usage)
            default:
                if arg.hasPrefix("-") { throw BarkeepError(.usage, "Unknown option \(arg)") }
                positional.append(arg)
            }
        }
    }
}

func emitJSON<T: Encodable>(_ value: T) {
    if let data = try? State.encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

func loadConfiguration(_ args: Arguments, log: Log) throws -> Configuration {
    // A config file could switch off signature or Gatekeeper checks, so only root may use one.
    if args.configFile != nil, geteuid() != 0 {
        throw BarkeepError(.notAuthorized, "--config may only be used by root")
    }
    let (config, warnings) = ConfigurationLoader().load(overrideFile: args.configFile)
    warnings.forEach { log.warning($0) }
    return config
}

func format(_ date: Date?) -> String {
    date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-"
}

func describe(_ source: ResolvedSource?) -> String {
    guard let source else { return "-" }
    let d = source.definition
    let target = d.feedURL ?? d.repository ?? d.note ?? ""
    return "\(d.kind.rawValue) (\(source.origin.rawValue.lowercased()): \(source.evidence))\(target.isEmpty ? "" : " \(target)")"
}

func printRecords(_ records: [AppRecord]) {
    for record in records {
        let available = record.available.map { " → \($0.displayVersion)" } ?? ""
        print("\(record.app.name) \(record.app.displayVersion)\(available) [\(record.status.rawValue)] \(record.message.escapingControlCharacters)")
        print("    \(record.app.path)  \(record.app.bundleIdentifier)  source: \(describe(record.source))")
        if record.available != nil {
            print("    released \(format(record.available?.releaseDate)), installable after \(format(record.installableAfter)), deadline \(format(record.deadline))")
        }
    }
}

/// An app given by path, or by bundle ID among the apps in the scan folders.
func findApp(_ spec: String, scanner: AppScanner) throws -> URL {
    if spec.hasSuffix(".app") || spec.contains("/") {
        let url = URL(fileURLWithPath: spec).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw BarkeepError(.appNotFound, "\(url.path) does not exist") }
        return url
    }
    let matches = scanner.scan().filter { $0.bundleIdentifier.caseInsensitiveCompare(spec) == .orderedSame }
    guard let first = matches.first else { throw BarkeepError(.appNotFound, "No app with bundle ID \(spec) in the scan folders") }
    if matches.count > 1 { FileHandle.standardError.write(Data("WARN \(spec) is installed \(matches.count) times; using \(first.path)\n".utf8)) }
    return first.url
}

/// The hidden commands root uses to read or delete a user's files as that user.
func runHelper(_ command: String, _ args: Arguments) throws -> Int32 {
    guard args.positional.count == 1, let uid = args.uid else { throw BarkeepError(.usage, "\(command) needs a path and --uid") }
    try TargetUser.dropPrivileges(to: uid)
    let url = URL(fileURLWithPath: args.positional[0])
    if command == "_inspect" {
        emitJSON(try InstalledApp.inspect(url, deep: args.deep))
    } else {
        try FileManager.default.removeItem(at: url)
    }
    return ExitStatus.success.rawValue
}

func run() -> Int32 {
    let log = Log()
    let raw = CommandLine.arguments.dropFirst()
    guard let command = raw.first else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return ExitStatus.usage.rawValue
    }
    HTTPClient.userAgent = "barkeep/\(version)"
    let isRoot = geteuid() == 0

    do {
        let args = try Arguments(raw.dropFirst())
        log.verbose = args.verbose
        log.quiet = args.quiet

        // Root runs this binary from the daemon. If a user can replace it, or a folder above it
        // (a user-owned /usr/local/bin, say), they can run code as root.
        if isRoot, !["version", "--version", "help", "--help", "-h"].contains(command) {
            guard let executable = Bundle.main.executablePath else { throw BarkeepError(.failure, "Cannot find the barkeep executable") }
            if let problem = PathSafety.problem(with: executable) {
                throw BarkeepError(.failure, "Refusing to run as root: \(problem), so a non-root user could replace \(executable)")
            }
        }
        let helper = Bundle.main.executablePath

        switch command {
        case "_inspect", "_remove":
            return try runHelper(command, args)

        case "status":
            guard let state = State.loadForCurrentUser() else { throw BarkeepError(.daemonUnavailable, "The daemon has not saved a state yet (\(State.path))") }
            if args.json { emitJSON(state) } else {
                print("Last scan \(format(state.lastScan)), last check \(format(state.lastCheck))")
                printRecords(state.apps)
            }
            return ExitStatus.success.rawValue

        case "scan":
            let config = try loadConfiguration(args, log: log)
            var scanner = AppScanner(config: config, log: log)
            scanner.helperExecutable = helper
            let apps = scanner.scan()
            struct Row: Encodable { let app: InstalledApp; let source: ResolvedSource?; let problem: String?; let excluded: Bool }
            let rows = apps.map { app -> Row in
                let (source, problem) = SourceResolver.resolve(app, config: config)
                return Row(app: app, source: source, problem: problem, excluded: config.isExcluded(app.bundleIdentifier))
            }
            if args.json { emitJSON(rows) } else {
                for row in rows {
                    let note = row.excluded ? "excluded" : row.app.isApple ? "Apple" : row.source.map(describe) ?? "no source: \(row.problem ?? "")"
                    print("\(row.app.name) \(row.app.displayVersion)  \(row.app.bundleIdentifier)  team \(row.app.teamID ?? "none")\n    \(row.app.path)\n    \(note)")
                }
                print("\(rows.count) apps in \(scanner.folders().map(\.path).joined(separator: ", "))")
            }
            return ExitStatus.success.rawValue

        case "inspect":
            guard args.positional.count == 1 else { throw BarkeepError(.usage, "inspect needs one app path") }
            let config = try loadConfiguration(args, log: log)
            var scanner = AppScanner(config: config, log: log)
            scanner.helperExecutable = helper
            let app = try scanner.inspect(URL(fileURLWithPath: args.positional[0]).standardizedFileURL, deep: true)
            let (source, problem) = SourceResolver.resolve(app, config: config)
            var latest: AvailableUpdate?
            var feedError: String?
            if let source {
                do { latest = try UpdateFinder(config: config, log: log).latest(for: app, source: source.definition) } catch { feedError = "\(error)" }
            }
            struct Inspection: Encodable {
                let app: InstalledApp; let source: ResolvedSource?; let sourceProblem: String?
                let latest: AvailableUpdate?; let feedError: String?; let updateAvailable: Bool; let excluded: Bool
            }
            let result = Inspection(app: app, source: source, sourceProblem: problem, latest: latest, feedError: feedError,
                                    updateAvailable: latest?.isNewer(than: app) ?? false, excluded: config.isExcluded(app.bundleIdentifier))
            if args.json { emitJSON(result) } else {
                let s = app.signing
                print("""
                App:            \(app.path)
                Bundle ID:      \(app.bundleIdentifier)
                Version:        \(app.displayVersion)
                Owner:          uid \(app.ownerUID)
                Team ID:        \(s?.teamID ?? s?.unverifiedTeamID.map { "\($0) (not verified by Apple)" } ?? "none")
                Signature:      \(s.map { $0.isAdHoc ? "ad-hoc" : $0.states.map(\.rawValue).sorted().joined(separator: ", ") } ?? "invalid: \(app.signatureProblem ?? "?")")
                Requirement:    \(app.designatedRequirement ?? "none")
                Architectures:  \(app.metadata.architectures.joined(separator: ", "))
                Sparkle:        \(app.metadata.sparkleFeedURL ?? (app.metadata.hasSparkleFramework ? "framework present, feed set at run time" : "no"))\(app.metadata.sparklePublicEDKey != nil ? " (EdDSA key)" : "")
                Electron:       \(app.metadata.electronUpdate.map { $0.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ") } ?? "no")
                product.json:   \(app.metadata.productUpdateURL ?? "no")
                App Store:      \(app.metadata.hasAppStoreReceipt ? "yes" : "no")
                Excluded:       \(result.excluded ? "yes" : "no")
                Update source:  \(source.map(describe) ?? "none: \(problem ?? "")")
                Newest:         \(latest.map { "\($0.displayVersion), released \(format($0.releaseDate))" } ?? feedError ?? "-")
                Download:       \(latest?.downloadURL ?? "-")
                Checksums:      \(checksums(latest))
                Update?:        \(result.updateAvailable ? "yes" : "no")
                """)
            }
            return ExitStatus.success.rawValue

        case "check", "run":
            let config = try loadConfiguration(args, log: log)
            if command == "run" {
                guard isRoot else { throw BarkeepError(.notAuthorized, "run may only be used by root; use check to look for updates") }
                log.attachFile(at: config.effectiveLogFilePath())
            }
            let barkeeper = Barkeeper(config: config, log: log, helperExecutable: helper)
            var options = CycleOptions()
            options.install = command == "run"
            options.checkFeeds = command == "check" || args.checkFeeds
            if let spec = args.app {
                let url = try findApp(spec, scanner: barkeeper.scanner)
                options.only = [url.path]
            }
            let lock = command == "run" ? try? UpdateLock(timeout: 60) : nil
            if command == "run", lock == nil { throw BarkeepError(.busy, "The daemon is busy; try again shortly") }
            defer { lock?.release() }
            let state = barkeeper.cycle(options)
            let shown = options.only.map { only in state.apps.filter { only.contains($0.app.path) } } ?? state.apps
            if args.json { emitJSON(shown) } else { printRecords(shown) }
            return shown.contains { $0.status == .failed } ? ExitStatus.failure.rawValue : ExitStatus.success.rawValue

        case "update":
            guard args.positional.count == 1 else { throw BarkeepError(.usage, "update needs a bundle ID or app path") }
            let config = try loadConfiguration(args, log: log)
            let barkeeper = Barkeeper(config: config, log: log, helperExecutable: helper)
            let url = try findApp(args.positional[0], scanner: barkeeper.scanner)
            if config.isExcluded((try? AppBundle(url: url))?.bundleIdentifier ?? "") {
                throw BarkeepError(.appExcluded, "\(url.lastPathComponent) is excluded by the profile")
            }
            let record: AppRecord?
            let message: String
            if isRoot {
                log.attachFile(at: config.effectiveLogFilePath())
                guard let lock = try? UpdateLock(timeout: 60) else { throw BarkeepError(.busy, "The daemon is busy; try again shortly") }
                defer { lock.release() }
                var options = CycleOptions()
                options.only = [url.path]
                options.requestedPaths = [url.path]
                let state = barkeeper.cycle(options)
                record = state.record(forPath: url.path)
                message = record?.message ?? "Not managed"
            } else {
                let reply = try DaemonClient.send(.updateNow(path: url.path))
                record = reply.record
                message = reply.message
            }
            if args.json { emitJSON(record) } else { print("RESULT \(record?.status.rawValue ?? "unknown"): \(message.escapingControlCharacters)") }
            switch record?.status {
            case .failed?: return ExitStatus.installFailed.rawValue
            case .coolingOff?: return ExitStatus.deferred.rawValue
            case .waitingForQuit?, .closingSoon?: return ExitStatus.appRunning.rawValue
            case .noSource?: return ExitStatus.noUpdateSource.rawValue
            case nil: return ExitStatus.appNotFound.rawValue
            default: return ExitStatus.success.rawValue
            }

        case "show-config":
            let config = try loadConfiguration(args, log: log)
            if args.json { emitJSON(config) } else {
                let mirror = Mirror(reflecting: config)
                print("Domain: \(Configuration.domain)")
                for child in mirror.children {
                    guard let label = child.label else { continue }
                    let key = label.prefix(1).uppercased() + label.dropFirst()
                    print("\(key): \(String(describing: child.value).replacingOccurrences(of: "Optional(", with: "").replacingOccurrences(of: ")", with: ""))")
                }
                print("LogFile: \(config.effectiveLogFilePath())")
            }
            return ExitStatus.success.rawValue

        case "daemon":
            guard isRoot else { throw BarkeepError(.notAuthorized, "daemon may only be used by root") }
            let (initial, _) = ConfigurationLoader().load(overrideFile: args.configFile)
            log.quiet = true
            log.attachFile(at: initial.effectiveLogFilePath())
            let configFile = args.configFile
            let daemonLog = log
            let daemon = Daemon(log: log, helperExecutable: helper, version: version) {
                let (config, warnings) = ConfigurationLoader().load(overrideFile: configFile)
                warnings.forEach { daemonLog.debug($0) }
                return config
            }
            try daemon.run()

        case "self-update":
            if args.feed != nil || args.allowUnsigned {
                guard isRoot else { throw BarkeepError(.notAuthorized, "--feed and --allow-unsigned may only be used by root") }
                guard args.feed != nil else { throw BarkeepError(.usage, "--allow-unsigned needs --feed") }
            }
            let config = try loadConfiguration(args, log: log)
            if !args.checkOnly { log.attachFile(at: config.effectiveLogFilePath()) }
            guard isRoot || args.checkOnly else { throw BarkeepError(.notAuthorized, "self-update may only be used by root; use --check") }
            let updater = SelfUpdater(config: config, log: log, currentVersion: version)
            updater.executablePath = helper
            updater.testFeed = args.feed.map { URL(fileURLWithPath: $0).standardizedFileURL }
            updater.allowUnsigned = args.allowUnsigned
            let report = updater.run(checkOnly: args.checkOnly, mode: args.latest ? .latest : .automatic)
            if args.json { emitJSON(report) } else if !args.quiet {
                print("RESULT \(report.action.rawValue) exit=\(report.exitCode): \(report.message.escapingControlCharacters)")
            }
            return report.exitCode

        case "uninstall":
            guard isRoot else { throw BarkeepError(.notAuthorized, "uninstall may only be used by root") }
            let report = Uninstaller.uninstall(dryRun: args.dryRun)
            let verb = args.dryRun ? "Would remove" : "Removed"
            report.removed.forEach { print("\(verb) \($0)") }
            report.problems.forEach { print("Not removed: \($0)") }
            return report.problems.isEmpty ? ExitStatus.success.rawValue : ExitStatus.failure.rawValue

        case "version", "--version":
            print(version)
            return ExitStatus.success.rawValue

        case "help", "--help", "-h":
            print(usage)
            return ExitStatus.success.rawValue

        default:
            throw BarkeepError(.usage, "Unknown command \(command)\n\n\(usage)")
        }
    } catch let error as BarkeepError {
        if error.status == .success { print(error.message) } else { log.error(error.message) }
        return error.status.rawValue
    } catch {
        log.error(error.localizedDescription)
        return ExitStatus.failure.rawValue
    }
}

func checksums(_ update: AvailableUpdate?) -> String {
    guard let update else { return "-" }
    var names: [String] = []
    if update.sha256 != nil { names.append("SHA-256") }
    if update.sha512 != nil { names.append("SHA-512") }
    if update.edSignature != nil { names.append("EdDSA") }
    return names.isEmpty ? "none in the feed" : names.joined(separator: ", ")
}

extension String {
    func nilIfEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

exit(run())
