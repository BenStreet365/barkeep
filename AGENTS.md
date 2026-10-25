# AGENTS.md

barkeep is a Swift daemon, command-line tool and menu bar app (Barkeep.app) that keeps the apps on
managed Macs up to date. [README.md](README.md) is the admin guide; [docs/SECURITY.md](docs/SECURITY.md)
has the security model and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers building and testing.

## Layout

- `Sources/BarkeepCore/`: everything that decides or does anything.
  - `AppScanner`, `InstalledApp`: finding apps and reading their update metadata.
  - `UpdateSource` (detection), `Providers` (reading feeds), `SparkleAppcast`, `BuiltInCatalog`.
  - `Policy`: cooling-off and deadlines, a pure function.
  - `AppUpdater`, `Archive`, `Verification`, `UpdateLease`: download, verify, swap.
  - `Barkeeper`: one pass over the apps; `Daemon`: the LaunchDaemon and its XPC service.
  - `SelfUpdater`: barkeep's own updates (from decant).
  - `Configuration`, `State`, `ExitStatus`.
- `Sources/barkeep/main.swift`: the command line.
- `Sources/BarkeepApp/`: Barkeep.app (AppKit lifecycle, SwiftUI views). The SwiftPM product is
  `BarkeepApp`, since `Barkeep` would clash with `barkeep` on a case-insensitive disk. It has no
  privileges and installs nothing; logic belongs in BarkeepCore.
- `Tests/BarkeepCoreTests/`: unit tests, including real updates of ad-hoc signed fixture apps.
- `Support/Info.plist`: bundle identifier and version, embedded in the binary. This is the only
  place the version is set. `Support/App-Info.plist` is Barkeep.app's; the build copies the version in.
- `Support/uk.street365.barkeep.daemon.plist`, `Support/uk.street365.barkeep.agent.plist` and
  `Support/scripts/postinstall`: the LaunchDaemon, the LaunchAgent and the script that loads them.
- `Scripts/build.sh`: the binary, Barkeep.app and both packages. The app icon is
  `Design/logo/AppIcon.icon` (Icon Composer, light/dark/tinted), compiled by `actool`;
  `Scripts/render-logo.swift` renders the menu bar images from `Design/logo/barkeep-template.svg`.
- `Profiles/`: the settings profile (every key, with defaults) and the App Management profile.
- `site/`: static website for barkeep.street365.uk (Cloudflare Pages, no build step).
- `CHANGELOG.md`: add a `## <version>` section with each version bump; the release workflow
  publishes it and fails without it.

## Commands

```bash
swift build
swift test
Scripts/build.sh   # ad-hoc signed app and packages in .build/dist/
```

The project requires Swift 6.4 and the macOS 27 SDK, targets macOS 27 and later, and builds for
arm64 only.

## Conventions

- Run `swift test` before finishing a change. Root-only paths (helpers that drop to a user,
  installer packages, the daemon, XPC) and Barkeep.app are not covered by unit tests; test them in
  a VM (docs/DEVELOPMENT.md) and say so when a change touches them. Never test on a Mac you use.
- Exit codes and configuration keys are part of the public interface used by MDM scripts. Do not
  renumber or rename them. Document new ones in the README tables, in plain language for admins.
- Security checks fail closed. Do not relax signature, requirement, Gatekeeper or checksum checks
  without an explicit configuration option.
- Never modify an installed app in place: stage, verify, swap. Never hold a lock that can outlive
  the process holding it.
- Never commit signing material (`.p12`, `.p8`, certificates). Releases are signed only in CI
  by `.github/workflows/release.yml`.
