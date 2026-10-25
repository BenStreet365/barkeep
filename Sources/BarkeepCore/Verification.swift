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
    /// Gatekeeper sources that mean Apple vouched for the code: notarised Developer ID, Apple's
    /// own code or the Mac App Store.
    static let trustedSources: Set<String> = ["Notarized Developer ID", "Apple System", "Mac App Store"]

    /// Throws unless Gatekeeper accepts `url` (an app, or with `type` "install" a package) as
    /// notarised.
    public static func assess(_ url: URL, type: String = "execute") throws {
        let result = try Command.run("/usr/sbin/spctl", ["--assess", "--type", type, "-vv", url.path], timeout: 300)
        let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { throw BarkeepError(.gatekeeperRejected, "Gatekeeper took too long to assess \(url.lastPathComponent)") }
        if let reason = rejection(status: result.status, output: detail) {
            throw BarkeepError(.gatekeeperRejected, "Gatekeeper rejected \(url.lastPathComponent): \(reason)")
        }
    }

    /// Why `spctl --assess` output is not proof of notarisation, or nil if it is. A zero exit
    /// status is not enough: with Gatekeeper disabled on the Mac, or a local `spctl --add` rule,
    /// spctl accepts anything ("override=security disabled", or the rule's label as source).
    static func rejection(status: Int32, output: String) -> String? {
        let flat = output.replacingOccurrences(of: "\n", with: "; ")
        guard status == 0 else { return flat }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let override = lines.first(where: { $0.hasPrefix("override=") }) {
            return "assessment was not performed (\(override)); set RequireGatekeeperAssessment to false to update without it"
        }
        let source = lines.first(where: { $0.hasPrefix("source=") }).map { String($0.dropFirst("source=".count)) }
        guard let source, trustedSources.contains(source) else {
            return "source \(source ?? "unknown") is not notarised by Apple (\(flat))"
        }
        return nil
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
