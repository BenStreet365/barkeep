# barkeep

barkeep keeps the apps on Macs up to date, quietly. It runs in the background, works out how each
app gets its updates, checks every update is genuinely from the same developer, and installs it
while the app is closed. It only interrupts someone when an update has waited past a deadline you
set, and even then it asks the app to quit, the way the user would.

Like a good barkeep, it keeps the bar in order without anyone noticing. Here, the Mac is the bar.

It needs macOS 27 or later on Apple silicon, and works with any MDM (Intune, Jamf, Kandji and
others).

- [Getting started](#getting-started)
- [How barkeep finds updates](#how-barkeep-finds-updates)
- [How barkeep stops fake updates](#how-barkeep-stops-fake-updates)
- [When updates install](#when-updates-install)
- [Settings](#settings)
- [Example configurations](#example-configurations)
- [Permissions](#permissions)
- [Barkeep.app](#barkeepapp)
- [The barkeep command](#the-barkeep-command)
- [Updates to barkeep](#updates-to-barkeep)
- [Troubleshooting](#troubleshooting)
- [Exit codes](#exit-codes)
- [Things to know](#things-to-know)
- [Removing barkeep](#removing-barkeep)
- [Licence](#licence)

## Getting started

Download the latest packages from [Releases](https://github.com/BenStreet365/barkeep/releases).
There are two:

| Package | Installs |
|---|---|
| `barkeep-full-<version>.pkg` | The `barkeep` command and daemon, Barkeep.app and its LaunchAgent |
| `barkeep-cli-<version>.pkg` | The `barkeep` command and daemon, without Barkeep.app |

Without Barkeep.app there is no menu bar icon, no notifications, no launch guard, and nothing to
ask apps to quit politely at a deadline, so the full package is recommended.

Then set it up in three steps. The examples use Intune; other MDMs have the same options under
different names.

1. **Deploy the package.** In Intune: Apps → macOS → line-of-business app. The daemon starts
   straight away and finds the apps within a minute.
2. **Deploy the settings profile.** Edit
   [`Profiles/uk.street365.barkeep.mobileconfig`](Profiles/uk.street365.barkeep.mobileconfig) to
   suit (see [Settings](#settings)), then upload it. In Intune: Devices → Configuration → Templates
   → Custom. It spells out the defaults, so you can deploy it unchanged.
3. **Deploy the App Management profile.**
   [`Profiles/uk.street365.barkeep.app-management.mobileconfig`](Profiles/uk.street365.barkeep.app-management.mobileconfig)
   grants everything barkeep needs from macOS (see [Permissions](#permissions)): App Management
   for the daemon, notifications for Barkeep.app, and managed login items so users can't switch
   barkeep off. It is ready to deploy for official releases (Team ID `Y633696656`). It must come
   from your MDM: a privacy profile installed by hand is ignored.

Check on a Mac with `barkeep status`, or open Barkeep.app.

## How barkeep finds updates

There is no single way Mac apps update, so barkeep looks for the one each app already uses, in
this order:

| Source | Found from | What barkeep reads |
|---|---|---|
| **Your profile** | `AppSources` | Whatever you tell it (any type below). Always wins. |
| **Mac App Store** | `Contents/_MASReceipt` | The App Store's version, for reporting. The App Store (or your MDM's VPP) installs it. |
| **barkeep's catalog** | Bundle ID | Built-in sources for Chrome, Firefox, Zoom, Slack, Discord, Docker Desktop, VS Code, ChatGPT, Claude, Tailscale, Obsidian, UTM, balenaEtcher, Thonny, Bambu Studio, Raspberry Pi Imager, Mullvad Browser and Decant, each pinned to the vendor's Team ID. |
| **Sparkle** | `SUFeedURL` in Info.plist | The appcast, with the EdDSA signature the app's `SUPublicEDKey` expects. Skips beta channels, informational items, deltas and items for newer macOS. |
| **Squirrel (VS Code style)** | `updateUrl` in `Resources/app/product.json` | `<updateUrl>/api/update/darwin-arm64/<quality>/latest`, with its SHA-256. Covers VS Code and its relatives. |
| **electron-builder** | `Resources/app-update.yml` | `latest-mac.yml` from GitHub, a generic URL or S3, with its SHA-512 and release date. |
| **The vendor's updater** | Bundle ID | Microsoft AutoUpdate and Adobe Creative Cloud apps are reported, not updated: their updaters are made for this and fighting them helps nobody. Exclude them, or replace with an `AppSources` entry. |
| **Apple** | `com.apple.*` | Left to Software Update and the App Store. |

Anything else shows as **Unknown source**. Many Sparkle apps set their feed in code rather than
in Info.plist; barkeep can see Sparkle is there and says so. To cover such an app, add it to
`AppSources`. Start with:

```bash
barkeep inspect /Applications/Example.app
```

which shows the app's signature, Team ID, what update metadata it carries, the source barkeep
would use and the newest version that source offers.

### AppSources

Each entry needs `BundleIdentifier` and `Type`, and should have `ExpectedTeamIdentifier`.

| Type | Needs | Notes |
|---|---|---|
| `Sparkle` | `FeedURL` | An appcast URL. |
| `ElectronBuilder` | `FeedURL` or `Repository` | The folder holding `latest-mac.yml`, or a GitHub `owner/repo`. `Channel` picks `<channel>-mac.yml`. |
| `Squirrel` | `FeedURL` | The update server; `Channel` is the quality (default `stable`). |
| `GitHub` | `Repository` | The newest non-prerelease release. `AssetPattern` (a regular expression) picks the file; otherwise barkeep prefers arm64, then universal, Mac `.dmg`/`.zip`/`.pkg` files. GitHub's published asset digest is checked. |
| `JSON` | `FeedURL`, `DownloadURL` or `DownloadPath`, and `VersionPath` or `VersionPattern` | Any URL that says what's newest. `VersionPath` is a dot path into JSON (`releases.0.version`); `VersionPattern` a regular expression whose first group is the version, for HTML or XML. `ReleaseDatePath` is optional. `{version}` in `DownloadURL` is replaced. When the download's name can't be worked out from the version, use `DownloadPath` instead: a dot path to the download URL in the same JSON (`releases.0.updateTo.url`). Use one or the other, not both. |
| `AppStore` | — | Report only. |
| `Vendor` | — | Report only; `Note` says which updater. |
| `None` | — | Leave the app alone. |

Downloads can be zip, tar, disk image or installer package; barkeep works out which from the file
itself, not its name.

## How barkeep stops fake updates

A feed can be hijacked, or a vendor's site compromised. barkeep treats every download as
untrusted until it proves it is the next version of the app that's installed:

1. **HTTPS only**, redirects included, and no larger than `MaximumDownloadSizeMB`.
2. **The feed's own checks.** A SHA-256 (Squirrel, GitHub) or SHA-512 (electron-builder) must
   match. An app with a Sparkle `SUPublicEDKey` only accepts a download carrying a valid EdDSA
   signature from that key, as Sparkle itself does.
3. **Exactly the app expected.** The download must hold one app with the installed copy's bundle
   ID.
4. **Checked in place.** That app is copied into a root-owned folder beside the installed one, and
   every check below runs on that copy, which is what gets installed.
5. **Same developer.** A valid, strict code signature (nested code included), from a certificate
   Apple issued, with the installed copy's Team ID. The source's `ExpectedTeamIdentifier` and
   `AllowedTeamIdentifiers` must also agree.
6. **Same app.** It must satisfy the installed copy's *designated requirement*: the rule in the
   installed signature that says what counts as the same app, which macOS uses for Keychain and
   privacy permissions too.
7. **Notarised.** Gatekeeper must accept it as notarised, and an assessment Gatekeeper didn't
   actually perform (because it's switched off) doesn't count.
8. **Newer, and runnable.** A higher version, never a downgrade, for this Mac's macOS, and built
   for Apple silicon if the installed copy is.
9. **Installer packages** must be signed by the app's own team with a Developer ID Installer
   certificate and be notarised. They run the vendor's scripts as root, so once one has run, the
   app it left is checked again for the same signature and a newer version. Packages only update
   apps in `/Applications`, and `AllowPackageInstallers` can turn them off.

An installed copy whose own signature is broken can't vouch for anything, so barkeep only updates
it from a source with an `ExpectedTeamIdentifier` (the catalog has one for each app).

## When updates install

1. **Cooling-off.** An update waits until it has been out for `CoolingOffHours` (default 168,
   7 days), counted from the release date in the feed, or from when barkeep first saw it if the feed has no
   date. A date in the future counts as the day barkeep saw it.
2. **Quietly, while closed.** Once cooled off, it installs the next time the app isn't running.
   The daemon goes over the apps every minute, so that's usually within a minute of the user
   quitting.
3. **Deadline.** If the app is still open `DeadlineDays` (default 14) after the update was
   released (or found by barkeep, with `DeadlineBasis` Discovered), the user is told it will close for its update after
   `DeadlineGraceMinutes`. Then Barkeep.app asks it to quit, as if the user had chosen Quit, so it
   can ask to save. It reopens once updated. An app that won't quit (an unsaved document dialog)
   is asked again every 30 minutes, unless `ForceQuitAtDeadline` says to terminate it.

The deadline clock starts when the vendor released the first update the app is still missing,
or when barkeep first saw it if that was earlier or the feed has no date. With `DeadlineBasis`
Discovered it starts when barkeep first found the app out of date. Either way, a newer release
that arrives while one is waiting doesn't restart it, so an app that releases every week still
gets updated. The deadline is never before the cooling-off period ends. Users are told `NotifyBeforeDeadlineHours` before a deadline if the app is open, and
whenever an app will close. That's all: nobody gets a notification for an update that installs
on its own.

**While an app is being swapped,** barkeep holds a short *lease* on it. If someone opens the app
in that moment, Barkeep.app closes it at once, says it's being updated, and opens it again when
it's done. A lease is a file in barkeep's own folder, never a change to the app, and it expires
on its own after 15 minutes or as soon as the daemon holding it stops, so a failed update can't
keep anyone out of an app. The swap itself is a single atomic rename, so an app is never
half-updated.

**After a failure** barkeep waits before trying the same update again: 15 minutes, then 30,
doubling up to a day.

## Settings

Settings come from a configuration profile with PayloadType `uk.street365.barkeep`, which users
can't change. Every key is optional. barkeep reads the device profile only; it acts for the whole
Mac.

On a Mac without a profile, or for keys the profile leaves out, an administrator can change
settings in Barkeep.app (Settings…, then Unlock with an administrator's name and password). The
daemon saves them in `/Library/Application Support/uk.street365.barkeep/Settings.plist`. The
profile always wins: a key it sets is locked in the window and ignored in that file. `AppSources`,
`AppSettings`, `LogFilePath`, `AllowUnverifiedSignatures` and `AllowFileURLs` can only come from a
profile. `barkeep show-config` lists where each value came from.

### Which apps

| Key | Type | Default | Meaning |
|---|---|---|---|
| `ExcludedBundleIdentifiers` | array | none | Bundle IDs never touched. A trailing `*` matches a prefix (`com.adobe.*`). Case-insensitive. |
| `IncludedBundleIdentifiers` | array | all | If set, only these are managed. |
| `ScanPaths` | array | `/Applications`, `~/Applications` | Folders searched, plus one level of subfolders. `~` means every local user's home folder. Symlinks are never followed. Replaces the defaults, so list every folder you want. |
| `AllowedTeamIdentifiers` | array | any | Only apps signed by these teams are updated. |
| `AppSources` | array | none | Update sources; see [AppSources](#appsources). |
| `AppSettings` | dictionary | none | Per-app overrides, keyed by bundle ID: `Excluded`, `CoolingOffHours`, `DeadlineDays`, `DeadlineBasis`, `EnforceDeadline`, `ForceQuitAtDeadline`. |

### When

| Key | Type | Default | Meaning |
|---|---|---|---|
| `CoolingOffHours` | integer | 168 (7 days) | Hours an update must have been out (0–8760). |
| `DeadlineDays` | integer | 14 | Days before an open app is closed for its update (0–365). Never before cooling-off ends. |
| `DeadlineBasis` | string | `Released` | Count the deadline from when the vendor released the update (`Released`) or barkeep found it (`Discovered`). Released falls back to Discovered when the feed has no date. |
| `EnforceDeadlines` | boolean | true | Off: updates only ever install while apps are closed. |
| `DeadlineGraceMinutes` | integer | 60 | Warning before an app is closed (0–1440). |
| `ForceQuitAtDeadline` | boolean | false | Terminate an app that won't quit two minutes after being asked. Unsaved work may be lost. |
| `RelaunchAfterUpdate` | boolean | true | Reopen an app barkeep closed. |
| `CheckIntervalMinutes` | integer | 240 | How often each feed is checked (15–10080). |

### Protection

| Key | Type | Default | Meaning |
|---|---|---|---|
| `RequireGatekeeperAssessment` | boolean | true | Gatekeeper must accept updates as notarised. |
| `AllowPackageInstallers` | boolean | true | Accept updates delivered as `.pkg` (signed by the app's own team). |
| `MaximumDownloadSizeMB` | integer | 2048 | Largest download. |
| `AllowUnverifiedSignatures` | boolean | false | **Testing only.** Accept signatures Apple didn't issue (ad hoc, self-signed). The designated requirement and bundle ID must still match. |
| `AllowFileURLs` | boolean | false | **Testing only.** Accept `file://` feeds and downloads. |

### Users

| Key | Type | Default | Meaning |
|---|---|---|---|
| `NotifyUsers` | boolean | true | Tell users before an open app is closed for its update. |
| `NotifyBeforeDeadlineHours` | integer | 24 | When to first mention a waiting update to someone using the app. |
| `AllowUserInitiatedUpdates` | boolean | true | Let users start updates: Update Now and Check for Updates in Barkeep.app and its notifications, and `barkeep update` without sudo. Cooling-off still applies. Off: updates install only on barkeep's own schedule. |
| `ShowInMenuBar` | boolean | user's choice | Show Barkeep in the menu bar. Leave out to let users choose (on by default). |
| `OpenAtLogin` | boolean | user's choice | Start Barkeep.app when a user logs in. Leave out to let users choose (on by default). While it isn't running there is no launch guard, no notifications and nothing to ask apps to quit politely at a deadline, so only turn it off with `EnforceDeadlines` off. |

### barkeep itself

| Key | Type | Default | Meaning |
|---|---|---|---|
| `AutomaticSelfUpdates` | boolean | true | Install new barkeep releases from GitHub. |
| `SelfUpdateDeferralDays` | integer | 7 | Days a barkeep release must be out first (0–30). |
| `LogFilePath` | string | `/Library/Logs/barkeep.log` | Log file. |

`barkeep show-config` prints what a Mac ended up with and any problems with the profile.

## Example configurations

[`Profiles/uk.street365.barkeep.mobileconfig`](Profiles/uk.street365.barkeep.mobileconfig) lists
every key with its default. [`Profiles/Examples`](Profiles/Examples) has complete profiles for
common setups, ready to edit and upload. They set only what differs from the defaults. Deploy one
barkeep settings profile per Mac.

| Profile | For |
|---|---|
| [`locked-down`](Profiles/Examples/locked-down.mobileconfig) | Users can't start updates or turn Barkeep off; barkeep itself is shipped by the MDM. |
| [`fast-patching`](Profiles/Examples/fast-patching.mobileconfig) | Shorter waits for everything, browsers within days, and apps terminated at the deadline. |
| [`never-interrupt`](Profiles/Examples/never-interrupt.mobileconfig) | Updates only while apps are closed; no menu bar icon. |
| [`selected-apps`](Profiles/Examples/selected-apps.mobileconfig) | Only named apps from named developers in `/Applications`, plus one custom update source. |

The keys inside `PayloadContent` are what matter. Stopping users from starting updates, for
example:

```xml
<key>AllowUserInitiatedUpdates</key>
<false/>
<key>OpenAtLogin</key>
<true/>
<key>ShowInMenuBar</key>
<true/>
```

Rushing one app through while the rest keep the defaults:

```xml
<key>AppSettings</key>
<dict>
    <key>com.google.Chrome</key>
    <dict>
        <key>CoolingOffHours</key>
        <integer>0</integer>
        <key>DeadlineDays</key>
        <integer>2</integer>
    </dict>
</dict>
```

Scanning another folder as well as the defaults (the list replaces them, so repeat them):

```xml
<key>ScanPaths</key>
<array>
    <string>/Applications</string>
    <string>~/Applications</string>
    <string>/Users/Shared/Applications</string>
</array>
```

## Permissions

barkeep supports macOS 27 and later, and needs the same permissions on every version. All of
them are in
[`Profiles/uk.street365.barkeep.app-management.mobileconfig`](Profiles/uk.street365.barkeep.app-management.mobileconfig),
which must be deployed by your MDM: macOS ignores privacy settings in a profile installed by hand.

| Permission | Payload | For | Without it |
|---|---|---|---|
| App Management | Privacy Preferences Policy Control (`com.apple.TCC.configuration-profile-policy`), service `SystemPolicyAppBundles`, for `/usr/local/bin/barkeep` with its code requirement | The daemon replacing apps from other developers, even as root | Updates fail with exit 44 |
| Notifications | Notifications (`com.apple.notificationsettings`) for `uk.street365.barkeep.app` | Telling users an app will close for its update | Each user is asked to allow them; if they don't, apps still close at deadlines without warning |
| Managed login items | Service Management (`com.apple.servicemanagement`), rule `TeamIdentifier` `Y633696656` | Keeping the daemon and Barkeep.app's LaunchAgent switched on | Users can turn barkeep off in System Settings → General → Login Items & Extensions, and see a "Background Items Added" notification |

barkeep needs nothing else:

- **No Full Disk Access.** `/Applications` and `~/Applications` aren't protected folders. If you
  add a protected folder (Desktop, Documents, Downloads, a network or removable volume) to
  `ScanPaths`, barkeep can't see the apps in it unless you also grant the daemon Full Disk Access
  (`SystemPolicyAllFiles`, with the same identifier and code requirement); better to leave apps
  out of those folders.
- **No Automation or Accessibility.** Barkeep.app asks apps to quit and reopens them through
  ordinary macOS calls, which need no permission.
- **No system or kernel extensions**, and no approval in Privacy & Security.

If you build barkeep yourself and sign it with your own Developer ID, replace `Y633696656` in
the code requirement and the login items rule with your Team ID
(`codesign -dv /usr/local/bin/barkeep 2>&1 | grep TeamIdentifier`).

## Barkeep.app

Barkeep.app is started in every user's session at login by a LaunchAgent, unless `OpenAtLogin`
(or, when the profile leaves it out, the user's own setting) is off. It:

- shows a menu bar icon (unless `ShowInMenuBar` is off), with a dot when updates are waiting and an
  orange dot when an app is about to close;
- opens a window listing the apps, how each updates, where its update stands, and why (a
  standard user sees the apps outside home folders and those in their own; administrators see
  every user's);
- lets users update an app now, or check for updates, if `AllowUserInitiatedUpdates` allows;
- shows every setting in its Settings window, and lets an administrator change the ones the
  profile doesn't set (see [Settings](#settings));
- runs the launch guard, asks apps to quit at their deadline, reopens them afterwards and posts the
  notifications.

It never installs anything itself and has no privileges: it reads the daemon's state from
`/Library/Application Support/uk.street365.barkeep/State.json` (administrators) or the user's own
copy of it in `Users/<uid>.json` beside it, and sends requests to the daemon.
A user who quits it gets it back at their next login.

## The barkeep command

```
barkeep status [--json]                 What the daemon last found, app by app
barkeep scan [--json]                   Apps found and how each one updates (no network)
barkeep check [--app <id|path>] [--json]  Ask the feeds what's newest; installs nothing
barkeep inspect <path.app> [--json]     Everything barkeep knows about one app
barkeep update <id|path> [--json]       Update one app now (asks it to quit if it is open)
barkeep run [--app <id|path>] [--check-feeds]  One full pass, installing what policy allows (root)
barkeep show-config [--json]            Effective settings
barkeep self-update [--check] [--latest]  Update barkeep itself
barkeep uninstall [--dry-run]           Remove barkeep (root)
barkeep daemon                          What launchd runs
```

`update` run without root goes through the daemon, with the same checks as Barkeep.app's Update
Now. Like Barkeep.app, `status` shows a standard user only their own apps and the shared ones, and
`update` treats an app in someone else's home folder as one barkeep doesn't manage. Root may pass `--config <file.plist>` to try settings without a profile.

## Updates to barkeep

The daemon checks GitHub once a day and installs the newest barkeep release once it has been out
for `SelfUpdateDeferralDays` and the Mac has been idle for ten minutes. The package must match its
published checksum, be signed by the same Developer ID team as the running barkeep and be
notarised, and its version must be newer. A Mac with Barkeep.app gets the full package; one
without gets the command-line package. The daemon and Barkeep.app restart into the new version
on their own. Turn `AutomaticSelfUpdates` off to ship barkeep through your MDM instead.

## Troubleshooting

- **`barkeep status`** shows each app's status and the reason in plain words.
- **The log** is `/Library/Logs/barkeep.log`, readable by administrators; it is kept under 10 MB. The unified log has the
  same, under subsystem `uk.street365.barkeep`:
  `log show --predicate 'subsystem == "uk.street365.barkeep"' --info --last 1h`.
- **Unknown source:** run `barkeep inspect` on the app and add an `AppSources` entry.
- **Exit 44 / "macOS blocked replacing":** deploy the App Management profile.
- **An update keeps failing:** the status says why. A fake or mismatched download (exit 22–27)
  will keep failing until the feed is fixed; that is the point.
- **Is the daemon running?** `sudo launchctl print system/uk.street365.barkeep.daemon`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to do |
| 1 | Unexpected error |
| 10 | Not authorised (a root-only command or option) |
| 11 | App not found |
| 12 | App excluded by the profile |
| 13 | barkeep doesn't know how this app updates; add it to `AppSources` |
| 20 | The update feed couldn't be read |
| 21 | The download couldn't be opened, or doesn't hold the app |
| 22 | Invalid or missing code signature, or ad hoc |
| 23 | Rejected by Gatekeeper |
| 24 | Signed by another developer, or not the same app (designated requirement) |
| 25 | Bundle ID doesn't match |
| 26 | Download doesn't match its checksum or EdDSA signature |
| 27 | Download isn't newer |
| 40 | The app is open; the update waits until it quits |
| 41 | Held back by the cooling-off period |
| 42 | Something else is in the way at the destination |
| 43 | Another barkeep run is busy; try again |
| 44 | App Management blocked the update; deploy the App Management profile |
| 50 | Install failed |
| 52 | barkeep couldn't update itself |
| 53 | The daemon couldn't be reached |
| 64 | Usage error |

## Things to know

- **Ownership is kept.** An updated app keeps the owner and group of the copy it replaced, so an
  app in a user's `~/Applications` stays theirs. As root, barkeep reads and deletes things in a
  user's folder as that user, never as root.
- **It doesn't fight other updaters.** If an app updates itself first, barkeep notices on its
  next pass and has nothing to do.
- **Not every app can be updated by replacing it.** Apps with system extensions or privileged
  helpers usually update themselves through their own installer; if the vendor publishes a signed
  package, barkeep can use that.
- **App Store apps** are reported, not installed: that needs the user's Apple Account or your
  MDM's volume purchasing.
- **Quitting is polite by default.** An app with unsaved work will ask the user, and barkeep waits.
  Only `ForceQuitAtDeadline` changes that.
- **Feeds are checked from each Mac.** Every Mac asks each vendor directly, every
  `CheckIntervalMinutes`. GitHub's API allows 60 unauthenticated requests an hour per address,
  which a large office behind one address can reach; GitHub-based sources are then retried later.

## Removing barkeep

```bash
sudo barkeep uninstall
```

removes the command, Barkeep.app, the daemon and agent, the state folder (with any settings
changed on the Mac), the log, the settings authorization right and the package receipt. `--dry-run` lists what would go. Apps barkeep updated stay as they are.

## Licence

barkeep is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for the
attribution and the trademark terms for the Barkeep name and logo.
