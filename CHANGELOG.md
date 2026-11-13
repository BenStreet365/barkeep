# Changelog

Release notes for barkeep. The release workflow publishes the section for each version as its
GitHub Release notes, so write them for admins.

## 0.3.0

### Added

- Apps that release often are now updated. An app that released more often than `CoolingOffHours`
  never had a newest release old enough to install. barkeep now remembers each release it sees
  and installs the newest one that has cooled off, then the next: an app that releases daily is
  kept `CoolingOffHours` behind, and no further. `barkeep status` and Barkeep.app show which
  release is next. Nothing to configure.
- What barkeep remembers (releases, and when it first saw them) is sealed. The daemon throws away
  a `State.json` that was changed by anything else and starts again, which can only delay an
  update. See "What barkeep remembers" in docs/SECURITY.md.
- Macs with Gatekeeper turned off get updates. barkeep used to refuse every update there, because
  Gatekeeper can't say whether one is notarised. It now checks the notarisation itself on those
  Macs. Updates that aren't notarised are still refused unless `RequireGatekeeperAssessment` is
  false. The Settings window says which applies.
- Barkeep.app stays running. Command-Q and Quit in the Dock close its windows and leave it in the
  menu bar. A right click on the menu bar icon gives Check for Updates, Open Barkeep, Settings,
  About Barkeep and Quit, which is the one way to quit it (until the next login).
- The daemon restarts itself if a pass makes no progress for three hours.
- Barkeep.app's window follows the macOS 27 design: the status is the window's subtitle, the
  selected app's details are in an inspector (its update source and identity under More Info),
  and the menus are the standard ones.

### Changed

- Feeds are checked several at a time, so a check is quicker on a Mac with many apps.
- A feed that can't be read is asked again after 15 minutes (then 30, and so on) rather than
  after `CheckIntervalMinutes`, and an update barkeep already knows about installs meanwhile.
- Installing barkeep's package turns the daemon and the agent back on if `launchctl disable` had
  turned them off.

### Fixed

- "Last checked" in Barkeep.app only moved on Check for Updates, not on barkeep's own checks.
- Barkeep.app didn't notice the daemon's first report if it was opened before the daemon had run.

## 0.2.0

### Added

- A Filter menu in Barkeep.app's window chooses which apps to show by status, and whether to
  show the Source and Location columns. By default it hides apps with an unknown source and
  apps updated elsewhere, and the Source and Location columns. Each user's choices, including
  All Apps or Updates and the table's column order and widths, are remembered.

## 0.1.1

### Added

- The Settings window shows every setting. Settings the configuration profile sets are locked;
  an administrator can change the rest for the Mac, with their name and password. They are saved
  in `/Library/Application Support/uk.street365.barkeep/Settings.plist`, and the profile always
  wins over them.
- Catalog sources for ChatGPT, Claude, Tailscale, Obsidian, UTM, balenaEtcher, Thonny,
  Bambu Studio, Raspberry Pi Imager, Mullvad Browser and Decant.
- `DownloadPath` for `JSON` sources: a dot path to the download URL in the feed, for downloads
  whose names can't be worked out from the version.

### Fixed

- The Settings window opened empty.
- Sparkle feeds whose download links are relative to the feed (Tailscale's) now work.
- Versions that start with "v" (Raspberry Pi Imager's `v2.0.12`) now compare correctly, so their
  updates are found.

## 0.1.0

### Added

- First release. barkeep finds the apps in `/Applications` and every user's `~/Applications`,
  works out how each one updates (Sparkle, electron-builder, Squirrel/VS Code, GitHub, any JSON
  or web page, a built-in catalog, or `AppSources` in the profile), and installs updates while
  apps are closed, after a cooling-off period, with deadlines for apps that stay open.
- Every update must match its feed's checksum or EdDSA signature, be signed by the installed
  copy's team, satisfy its designated requirement, pass Gatekeeper and be newer.
- Barkeep.app: menu bar status, a window listing every app, Update Now, the launch guard,
  notifications before an app is closed, and reopening afterwards.
- Configuration profile for every setting, example profiles for common setups, and a
  permissions profile (App Management, notifications and managed login items).
- Defaults: a 7-day cooling-off period, and a 14-day deadline counted from the vendor's release.
- Standard users see only their own apps and the shared ones, in Barkeep.app and the `barkeep`
  command; apps in other people's home folders are still updated, and administrators see them all.
- `OpenAtLogin` and `ShowInMenuBar` can be left to users or set by the profile;
  `AllowUserInitiatedUpdates` stops users starting updates.
