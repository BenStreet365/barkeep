# Development

The project requires Swift 6.4 and the macOS 27 SDK, targets macOS 27 and later, and builds for
arm64 only.

## Build

```bash
Scripts/build.sh                       # ad-hoc signed
Scripts/build.sh --sign "Developer ID Application: …" --pkg-sign "Developer ID Installer: …"
Scripts/build.sh --sign "…" --pkg-sign "…" --notarize <notarytool-keychain-profile>
swift test                             # unit tests
```

The build produces `.build/dist/barkeep`, `.build/dist/Barkeep.app` and two packages:

- `barkeep-full-<version>.pkg`: `/usr/local/bin/barkeep`, `/Applications/Barkeep.app`, the
  LaunchDaemon `/Library/LaunchDaemons/uk.street365.barkeep.daemon.plist` and the LaunchAgent
  `/Library/LaunchAgents/uk.street365.barkeep.agent.plist`.
- `barkeep-cli-<version>.pkg`: the binary and the daemon only.

Both have the package identifier `uk.street365.barkeep`. The bundle identifier and version live
in `Support/Info.plist`, embedded in the binary's `__TEXT,__info_plist` section.

The logo is a beer mat printed with a refresh mark. In `Design/logo/`:

- `AppIcon.icon` is the app icon, an Icon Composer document with light, dark and tinted layers.
  The build compiles it with `actool` into `Assets.car` and `AppIcon.icns`. Open it in Icon
  Composer (inside Xcode) to edit or preview it.
- `barkeep-app.svg` and `barkeep-app-dark.svg` are the whole icon, light and dark, for anywhere
  outside macOS. `barkeep-app-1024.png` is the light icon exported from Icon Composer.
- `barkeep-template.svg` is the menu bar image; `menubar/` holds its 18 and 36 px renders.
- `site/favicon.svg` is the same icon for the website and follows the visitor's light or dark setting.

`swift Scripts/render-logo.swift <in.svg> <out.png> <pixels>` renders an SVG with transparency (the
menu bar images). Export icon PNGs with Icon Composer's `ictool`, which draws the system's glass
and shadows.

## Unit tests

`swift test` covers configuration parsing and trust, version ordering, every feed format
(Sparkle, electron-builder, Squirrel, GitHub asset choice, JSON paths and patterns), dates,
EdDSA, archive detection, the timing policy, source detection order, and real updates of ad-hoc
signed fixture apps: the happy path, wrong bundle ID, a copy that doesn't satisfy the designated
requirement, ad-hoc refusal, downgrades, checksum and EdDSA failures, a running app, a whole pass
with cooling-off, leases, and who may see which apps (each user's view of the state, and the permissions of the state and leases). Fixtures are signed with an explicit designated requirement
(`identifier "<bundle ID>"`), so the requirement check works as it does for Developer ID apps.

Root-only paths aren't covered: helpers that drop to a user, installer packages, the daemon and
its XPC service, Barkeep.app. Test those in a VM.

## Testing in a VM

Never run barkeep on a Mac you use: it replaces apps. Use a macOS 27 VM (UTM works) with Remote
Login on, and copy the package across:

```bash
Scripts/build.sh
scp .build/dist/barkeep-full-0.1.0.pkg vm:/tmp/
ssh vm 'sudo installer -pkg /tmp/barkeep-full-0.1.0.pkg -target /'
```

Settings can go in `/Library/Managed Preferences/uk.street365.barkeep.plist` (root-owned, mode
644) in place of a profile, or be passed to one command with `--config <file>` as root.

What to check, with old versions of real apps (all public downloads):

| Scenario | How |
|---|---|
| Catalog JSON source, DMG | Firefox 150.0 from `download-installer.cdn.mozilla.net`; `barkeep run --check-feeds` |
| Squirrel API, zip, SHA-256 | VS Code from `update.code.visualstudio.com/1.100.0/darwin-arm64/stable` |
| Sparkle with EdDSA, `~/Applications`, helper as the user | Rectangle 2.0.1 DMG from its GitHub releases, copied into `~/Applications` |
| Installer package | Rectangle 2.0.1 `Rectangle.pkg`, then an `AppSources` GitHub entry with `AssetPattern` `\.pkg$` |
| Fake update | Copy an app, change its version, re-sign ad hoc, serve it through a `JSON` source with `AllowFileURLs`: refused (ad hoc), and with `AllowUnverifiedSignatures` still refused (team) |
| XPC | `barkeep update <id>` as the user |
| Other people's apps | Two standard users with an app each in `~/Applications`, and an admin: each standard user's Barkeep.app and `barkeep status` show only their own app and `/Applications`, `cat` of `State.json` and `ls` of `Users/` are refused, and `barkeep update` of the other's app says barkeep doesn't manage it. `log show` as a standard user is refused. The admin sees both. After an upgrade from a build that wrote `State.json` mode 644, it is 640 `root:admin` as soon as the daemon starts |
| Deadline, polite quit, reopen | `AppSettings` with `CoolingOffHours` 0 and `DeadlineDays` 0, and `DeadlineGraceMinutes` 2; open the app and watch `barkeep status` |
| Open at login | `OpenAtLogin` false in the profile: at the next login Barkeep.app starts and exits at once, and `launchctl print gui/$UID/uk.street365.barkeep.agent` shows it not running. Left out: the Settings toggle works and takes effect at the next login |
| Permissions profile | Deployed by MDM: updates of another developer's app succeed (not exit 44), no notification permission prompt, and barkeep can't be turned off in Login Items & Extensions |
| Launch guard | Write a lease for an app into `/Library/Application Support/uk.street365.barkeep/Leases` (root-owned, see `UpdateLease`), open the app: it closes, and reopens when the lease expires |
| Upgrades | Install a newer build over the old: the daemon restarts itself and the agent is reloaded |
| barkeep's own updates | Build a higher version (bump `Support/Info.plist`), write a `releases.json` (below), and run `barkeep self-update --feed … --allow-unsigned` as root: it installs, and the daemon restarts into it. A wrong `.sha256`, or a package published under another version's tag, is refused (exit 52) |

`barkeep self-update --feed <folder>/releases.json --allow-unsigned` (root) tests barkeep's own
updates without GitHub, as in decant: `releases.json` is in the format of GitHub's releases API,
with `file://` URLs to `barkeep-full-<version>.pkg` and its `.sha256` in the same folder.

## Website

`site/` is the static site for [barkeep.street365.uk](https://barkeep.street365.uk), hosted on
Cloudflare Pages: no build command, `site` as the output directory, and `barkeep.street365.uk`
as a custom domain. `site/_headers` sets the security headers. Preview with
`python3 -m http.server --directory site`.
