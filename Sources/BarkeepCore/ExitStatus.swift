import Foundation

/// Process exit codes. These are stable so that MDM scripts and reporting can act on them.
public enum ExitStatus: Int32, Sendable, Codable {
    case success = 0
    case failure = 1
    case usage = 64

    /// A non-root user tried a root-only command or option.
    case notAuthorized = 10
    /// The app is not installed, or no app matches the bundle ID or path given.
    case appNotFound = 11
    /// The app is excluded by `ExcludedBundleIdentifiers`, or not in `IncludedBundleIdentifiers`.
    case appExcluded = 12
    /// Barkeep does not know how this app updates. Add it to `AppSources` in the profile.
    case noUpdateSource = 13

    /// The update feed could not be downloaded or read.
    case feedError = 20
    /// The downloaded archive could not be opened, or does not contain exactly the expected app.
    case archiveError = 21
    /// The new copy has a missing or invalid code signature, or is ad-hoc signed.
    case invalidSignature = 22
    case gatekeeperRejected = 23
    /// The new copy is signed by another team, or does not satisfy the installed copy's
    /// designated requirement, or its Team ID is not in `AllowedTeamIdentifiers`.
    case teamMismatch = 24
    /// The new copy's bundle ID is not the installed copy's.
    case bundleIDMismatch = 25
    /// The download does not match the checksum or EdDSA signature published in the feed.
    case checksumMismatch = 26
    /// The download is not newer than what is installed.
    case notNewer = 27

    /// The app is running, and the update waits until it quits (or its deadline).
    case appRunning = 40
    /// The update was found but policy holds it back (cooling-off period).
    case deferred = 41
    /// Something unrelated (or unsafe) occupies the destination path.
    case destinationConflict = 42
    /// Another barkeep update held the lock for too long. Retry later.
    case busy = 43
    /// macOS App Management blocked replacing the app. Deploy the App Management profile.
    case appManagementDenied = 44

    case installFailed = 50
    /// `self-update` could not check for, download or install a new release of barkeep.
    case selfUpdateFailed = 52
    /// The daemon could not be reached.
    case daemonUnavailable = 53
}

public struct BarkeepError: Error, CustomStringConvertible, Sendable {
    public let status: ExitStatus
    public let message: String

    public init(_ status: ExitStatus, _ message: String) {
        self.status = status
        self.message = message
    }

    public var description: String { message }
}
