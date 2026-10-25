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
    ]

    public static func entry(for bundleID: String) -> AppSourceDefinition? {
        entries.first { $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
