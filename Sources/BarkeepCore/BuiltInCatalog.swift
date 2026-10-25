import Foundation

/// Update sources for popular apps whose own files don't say where their updates come from (or
/// whose built-in updater barkeep cannot use). Each entry pins the vendor's Team ID. A profile's
/// `AppSources` entry for the same bundle ID replaces the one here.
///
/// Apps that ship a Sparkle feed, an electron-builder `app-update.yml` or a VS Code style
/// `product.json` need no entry: barkeep reads those from the app.
public enum BuiltInCatalog {
    public static let entries: [AppSourceDefinition] = [
        AppSourceDefinition(
            bundleIdentifier: "com.google.Chrome", kind: .json,
            feedURL: "https://versionhistory.googleapis.com/v1/chrome/platforms/mac_arm64/channels/stable/versions/all/releases?filter=endtime=none&order_by=version%20desc",
            versionPath: "releases.0.version", releaseDatePath: "releases.0.serving.startTime",
            downloadURL: "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
            expectedTeamIdentifier: "EQHXZ8M8AV", note: "Also updated by Google Software Update"),
        AppSourceDefinition(
            bundleIdentifier: "org.mozilla.firefox", kind: .json,
            feedURL: "https://product-details.mozilla.org/1.0/firefox_versions.json",
            versionPath: "LATEST_FIREFOX_VERSION",
            downloadURL: "https://download-installer.cdn.mozilla.net/pub/firefox/releases/{version}/mac/en-US/Firefox%20{version}.dmg",
            expectedTeamIdentifier: "43AQ936H96"),
        AppSourceDefinition(
            bundleIdentifier: "us.zoom.xos", kind: .json,
            feedURL: "https://zoom.us/rest/download?os=mac",
            versionPath: "result.downloadVO.zoomArm64.version",
            downloadURL: "https://zoom.us/client/{version}/zoomusInstallerFull.pkg?archType=arm64",
            expectedTeamIdentifier: "BJ4HAAB9B3"),
        AppSourceDefinition(
            bundleIdentifier: "com.tinyspeck.slackmacgap", kind: .json,
            feedURL: "https://slack.com/api/desktop.latestRelease?arch=arm64&variant=dmg",
            versionPath: "version",
            downloadURL: "https://downloads.slack-edge.com/desktop-releases/mac/arm64/{version}/Slack-{version}-macOS.dmg",
            expectedTeamIdentifier: "BQR82RBBHL"),
        AppSourceDefinition(
            bundleIdentifier: "com.hnc.Discord", kind: .json,
            feedURL: "https://discord.com/api/updates/stable?platform=osx",
            versionPath: "name", releaseDatePath: "pub_date",
            downloadURL: "https://stable.dl2.discordapp.net/apps/osx/{version}/Discord.zip",
            expectedTeamIdentifier: "53Q6R32WPB"),
        AppSourceDefinition(
            bundleIdentifier: "com.docker.docker", kind: .sparkle,
            feedURL: "https://desktop.docker.com/mac/main/arm64/appcast.xml",
            expectedTeamIdentifier: "9BNSXJN65R"),
        AppSourceDefinition(
            bundleIdentifier: "com.microsoft.VSCode", kind: .squirrel,
            feedURL: "https://update.code.visualstudio.com", expectedTeamIdentifier: "UBF8T346G9", channel: "stable"),
        // ChatGPT (the Codex-based app) sets its Sparkle feed at run time.
        AppSourceDefinition(
            bundleIdentifier: "com.openai.codex", kind: .sparkle,
            feedURL: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml",
            expectedTeamIdentifier: "2DC432GLL2"),
        // Squirrel.Mac's RELEASES.json: the zip's name carries a hash, so the URL is read from the feed.
        AppSourceDefinition(
            bundleIdentifier: "com.anthropic.claudefordesktop", kind: .json,
            feedURL: "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json",
            versionPath: "releases.0.updateTo.version", releaseDatePath: "releases.0.updateTo.pub_date",
            downloadPath: "releases.0.updateTo.url",
            expectedTeamIdentifier: "Q6L2SF6YDW"),
        // The standalone (not App Store) Tailscale sets its Sparkle feed at run time.
        AppSourceDefinition(
            bundleIdentifier: "io.tailscale.ipn.macsys", kind: .sparkle,
            feedURL: "https://pkgs.tailscale.com/stable/appcast.xml",
            expectedTeamIdentifier: "W5364U7YZB"),
        AppSourceDefinition(
            bundleIdentifier: "md.obsidian", kind: .gitHub,
            repository: "obsidianmd/obsidian-releases", assetPattern: "^Obsidian-[0-9.]+\\.dmg$",
            expectedTeamIdentifier: "6JSW4SJWN9"),
        AppSourceDefinition(
            bundleIdentifier: "com.utmapp.UTM", kind: .gitHub,
            repository: "utmapp/UTM", assetPattern: "^UTM\\.dmg$",
            expectedTeamIdentifier: "WDNLXAD4W8"),
        AppSourceDefinition(
            bundleIdentifier: "io.balena.etcher", kind: .gitHub,
            repository: "balena-io/etcher", assetPattern: "^balenaEtcher-.*-arm64\\.dmg$",
            expectedTeamIdentifier: "66H43P8FRG"),
        AppSourceDefinition(
            bundleIdentifier: "org.thonny.Thonny", kind: .gitHub,
            repository: "thonny/thonny", assetPattern: "^thonny-.*-arm64\\.pkg$",
            expectedTeamIdentifier: "2SA9D4CVU8"),
        AppSourceDefinition(
            bundleIdentifier: "com.bambulab.bambu-studio", kind: .gitHub,
            repository: "bambulab/BambuStudio", assetPattern: "^Bambu_Studio_mac-.*\\.dmg$",
            expectedTeamIdentifier: "T3UBR9Y3B2"),
        AppSourceDefinition(
            bundleIdentifier: "com.raspberrypi.rpi-imager", kind: .gitHub,
            repository: "raspberrypi/rpi-imager", assetPattern: "^rpi-imager-.*\\.dmg$",
            expectedTeamIdentifier: "8RDZTRXE62"),
        AppSourceDefinition(
            bundleIdentifier: "net.mullvad.mullvadbrowser", kind: .json,
            feedURL: "https://cdn.mullvad.net/browser/update_responses/update_1/release/download-macos.json",
            versionPath: "version", downloadPath: "binary",
            expectedTeamIdentifier: "MADPSAYN6T"),
        AppSourceDefinition(
            bundleIdentifier: "uk.street365.decant.app", kind: .gitHub,
            repository: "BenStreet365/decant", assetPattern: "^decant-full-.*\\.pkg$",
            expectedTeamIdentifier: "Y633696656"),
    ]

    public static func entry(for bundleID: String) -> AppSourceDefinition? {
        entries.first { $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
