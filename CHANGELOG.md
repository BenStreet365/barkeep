# Changelog

Release notes for barkeep. The release workflow publishes the section for each version as its
GitHub Release notes, so write them for admins.

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
