import Foundation
import Security

extension CodeSignature {
    /// The designated requirement of the code at `url`: the rule that says what counts as "the
    /// same app" (normally its identifier plus its developer's certificate). An update must
    /// satisfy the requirement of the copy it replaces, which is how Sparkle and macOS itself
    /// decide that new code is a genuine successor.
    public static func designatedRequirement(of url: URL) throws -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw BarkeepError(.invalidSignature, "Cannot read code signature of \(url.path)")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw BarkeepError(.invalidSignature, "\(url.lastPathComponent) has no designated requirement")
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw BarkeepError(.invalidSignature, "Cannot read the designated requirement of \(url.lastPathComponent)")
        }
        return text as String
    }

    /// What a signature says about itself, without checking that it holds: fast enough for every
    /// app on every scan. Never trusted for anything but display.
    public static func claimedIdentity(of url: URL) -> (teamID: String?, designatedRequirement: String?) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return (nil, nil) }
        var infoRef: CFDictionary?
        let team = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess
            ? (infoRef as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String : nil
        return (team, try? designatedRequirement(of: url))
    }

    /// Whether the code at `url` is validly signed (strictly, with all nested code) and satisfies
    /// `requirement`.
    public static func satisfies(_ url: URL, requirement text: String) -> Bool {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// Gatekeeper and installer package checks, shared by app updates and barkeep's own updates.
public enum Gatekeeper {
    /// Whether Gatekeeper is assessing code on this Mac. An administrator or a profile can turn it off.
    public enum Mode: String, Codable, Sendable {
        case enabled, disabled, unknown
    }

    /// What `spctl --assess` said about some code.
    enum Assessment: Equatable {
        /// Gatekeeper looked, and Apple vouches for the code.
        case notarised
        /// Gatekeeper is turned off on this Mac, so it accepted the code without looking.
        case notPerformed
        case rejected(String)
    }

    /// Gatekeeper sources that mean Apple vouched for the code: notarised Developer ID, Apple's
    /// own code or the Mac App Store.
    static let trustedSources: Set<String> = ["Notarized Developer ID", "Apple System", "Mac App Store"]

    /// The same three, as code requirements, for a Mac where Gatekeeper is off and cannot be asked.
    /// `notarized` holds only if Apple's notary service issued a ticket for exactly this code.
    static let notarisedRequirements = [
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate 1[field.1.2.840.113635.100.6.2.6] exists and notarized",
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists",
        "anchor apple",
    ]

    /// The Mac's Gatekeeper setting, from `spctl --status`.
    public static func mode() -> Mode {
        guard let result = try? Command.run("/usr/sbin/spctl", ["--status"], timeout: 30), !result.timedOut else { return .unknown }
        return mode(fromStatus: result.stdoutString + result.stderrString)
    }

    static func mode(fromStatus output: String) -> Mode {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return .enabled }
        if text.contains("assessments disabled") { return .disabled }
        return .unknown
    }

    /// Throws unless Apple vouches for `url` (an app, or with `type` "install" a package) as
    /// notarised. Gatekeeper is asked first. Where it is turned off it accepts everything without
    /// looking, which proves nothing, so barkeep then checks the notarisation itself: Apple's
    /// notarisation is required either way, and a Mac without Gatekeeper still gets its updates.
    public static func assess(_ url: URL, type: String = "execute", log: Log? = nil) throws {
        let result = try Command.run("/usr/sbin/spctl", ["--assess", "--type", type, "-vv", url.path], timeout: 300)
        let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { throw BarkeepError(.gatekeeperRejected, "Gatekeeper took too long to assess \(url.lastPathComponent)") }
        switch assessment(status: result.status, output: detail) {
        case .notarised:
            return
        case .rejected(let reason):
            throw BarkeepError(.gatekeeperRejected, "Gatekeeper rejected \(url.lastPathComponent): \(reason)")
        case .notPerformed:
            guard try isNotarised(url, package: type == "install") else {
                throw BarkeepError(.gatekeeperRejected,
                                   "\(url.lastPathComponent) is not notarised by Apple (Gatekeeper is turned off on this Mac, so barkeep checked for itself); set RequireGatekeeperAssessment to false to update without it")
            }
            log?.info("Gatekeeper is turned off on this Mac; barkeep checked for itself that \(url.lastPathComponent) is notarised")
        }
    }

    /// Whether Apple notarised `url`, found without Gatekeeper: for code, from its signature and
    /// notarisation ticket; for a package, from `pkgutil`.
    static func isNotarised(_ url: URL, package: Bool) throws -> Bool {
        if package {
            let result = try Command.run("/usr/sbin/pkgutil", ["--check-signature", url.path], timeout: 120)
            return result.status == 0 && !result.timedOut && packageIsNotarised(fromCheckSignature: result.stdoutString)
        }
        return notarisedRequirements.contains { CodeSignature.satisfies(url, requirement: $0) }
    }

    /// Whether `pkgutil --check-signature` output says Apple's notary service trusts the package.
    static func packageIsNotarised(fromCheckSignature output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("Notarization:") && text.contains("trusted by the Apple notary service")
        }
    }

    /// What `spctl --assess` output proves. A zero exit status is not enough: with Gatekeeper
    /// turned off spctl accepts anything ("override=security disabled"), and with a local
    /// `spctl --add` rule it gives the rule's label as the source.
    static func assessment(status: Int32, output: String) -> Assessment {
        let flat = output.replacingOccurrences(of: "\n", with: "; ")
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let override = lines.first(where: { $0.hasPrefix("override=") }) {
            if status == 0, override == "override=security disabled" { return .notPerformed }
            return .rejected("assessment was not performed (\(override))")
        }
        guard status == 0 else { return .rejected(flat) }
        let source = lines.first(where: { $0.hasPrefix("source=") }).map { String($0.dropFirst("source=".count)) }
        guard let source, trustedSources.contains(source) else {
            return .rejected("source \(source ?? "unknown") is not notarised by Apple (\(flat))")
        }
        return .notarised
    }

    /// The Team ID of the Developer ID Installer certificate that signed a flat package, if it
    /// chains to Apple.
    public static func packageTeamID(_ package: URL) throws -> String? {
        let result = try Command.run("/usr/sbin/pkgutil", ["--check-signature", package.path], timeout: 120)
        guard result.status == 0 else { return nil }
        return installerTeamID(fromCheckSignature: result.stdoutString)
    }

    /// The Team ID in the leaf certificate of `pkgutil --check-signature` output, if the package
    /// is signed with a Developer ID Installer certificate that chains to Apple.
    static func installerTeamID(fromCheckSignature output: String) -> String? {
        guard output.contains("Status: signed by a developer certificate issued by Apple for distribution") else { return nil }
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("1. ") else { continue }
            guard text.hasPrefix("1. Developer ID Installer: "), text.hasSuffix(")"),
                  let open = text.lastIndex(of: "(") else { return nil }
            let team = text[text.index(after: open)..<text.index(before: text.endIndex)]
            return team.isEmpty ? nil : String(team)
        }
        return nil
    }
}
