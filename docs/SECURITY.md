# Security model

barkeep runs as root and replaces apps that people use every day, with code downloaded from the
internet. This is how it keeps that from becoming a way in.

## What barkeep trusts

| Input | Trusted? | Why |
|---|---|---|
| The configuration profile | Yes | Only read from `/Library/Managed Preferences`, and only if the file is owned by root and writable by nobody else. |
| Settings changed on the Mac | Yes, below the profile | `Settings.plist` in barkeep's state folder, read only if owned by root and writable by nobody else. Only the daemon writes it, and only for an administrator's password (below). Keys that relax testing-only checks can't be set there. |
| The installed app's signature | As far as Apple vouches for it | Its Team ID counts only if an Apple-issued certificate backs it. Its designated requirement is what every update must satisfy. |
| The installed app's update metadata (`SUFeedURL`, `app-update.yml`, `product.json`) | No | Only used to find a feed. Whatever the feed offers must still be signed like the installed copy. |
| Feeds and downloads | No | Checked as below. |
| Anything in a user's folder | No | Read by a helper running as that user, with a time limit. |
| Barkeep.app's requests | No | A request can only ask for something policy already allows, sooner: "update now" still needs a verified update that has cooled off. |

## Fake updates

An attacker who controls a feed, a vendor's download server, the network or DNS can offer any file
they like. To be installed it must:

1. arrive over HTTPS (redirects too), within `MaximumDownloadSizeMB`;
2. match the checksum in the feed, and for an app with `SUPublicEDKey`, carry a valid EdDSA
   signature from that key (a feed attacker can change the checksum, but not sign with the
   vendor's key);
3. contain exactly one app with the installed app's bundle ID;
4. be validly signed (strict, all architectures, nested code), not ad hoc, by a certificate Apple
   issued, with the installed copy's Team ID and any expected or allowed Team IDs;
5. satisfy the installed copy's designated requirement;
6. be notarised by Apple. Gatekeeper is asked, and a local `spctl --add` rule doesn't count. If
   Gatekeeper is turned off on the Mac it accepts everything without looking
   (`override=security disabled`), so barkeep doesn't take its word: it checks the notarisation
   itself, with the code requirement `notarized` on a Developer ID signature (or an Apple or Mac
   App Store signature), and for a package with `pkgutil --check-signature`. The requirement is
   the same whichever way it is checked;
7. be newer than the installed copy, so a genuinely signed old version with known bugs can't be
   used to roll a Mac back.

Steps 4 to 7 run on a copy in a root-owned staging folder on the same volume, and that copy is
what is swapped in, so the file can't be changed between check and install. Installer packages
are checked for a Developer ID Installer signature from the app's team and notarisation before
they run, and the app they leave behind is checked again.

What this can't stop: the vendor itself shipping something bad, correctly signed and notarised.
The cooling-off period gives others time to find out first, and `AppSettings` can hold back
particular apps for longer.

## Running as root in users' folders

Apps in `~/Applications` belong to their users, who could plant symlinks, FIFOs or hard links to
trick root.

- Root never follows a symlink inside an app bundle, never reads a file that isn't a regular file
  of reasonable size, and reads other users' bundles in a helper process that has permanently
  dropped to that user (`barkeep _inspect`), with a time limit.
- The swap uses folder descriptors opened with `O_NOFOLLOW` and an atomic `renameatx_np`, so a
  symlink swapped in at the last moment can't redirect the write. The old copy is deleted by a
  helper running as its owner.
- The new copy is given the old copy's owner and group, with nothing writable by others and no
  setuid or setgid bits.
- Root refuses to run a `barkeep` binary that a non-root user could replace (or any folder above it).

## Locks that can't trap anyone

The launch guard works with a lease: a file in `/Library/Application Support/uk.street365.barkeep/Leases`
(root-owned), held only while the new copy is being swapped in. It expires after 15 minutes, or
as soon as the process that took it has gone, whichever comes first, and Barkeep.app ignores
leases that aren't root-owned. Nothing about the app itself is changed to "lock" it.

## State, and other people's apps

barkeep updates the apps in every user's `~/Applications`, but a standard user only ever sees
their own, and the apps outside home folders (`/Applications`). An app inside someone's home
folder is theirs; administrators and root see everything.

- `State.json` (every app) is written by root and readable only by root and the `admin` group.
- Each account gets its own copy without other people's apps, `Users/<uid>.json`, readable only
  by root and that account (an ACL). The `Users` folder can't be listed. Barkeep.app and
  `barkeep status` read `State.json` if they can and their own copy otherwise.
- Both are written to a new file with their final permissions and then renamed into place, so
  neither is ever readable by more people than it should be, even for a moment.
- The daemon learns who is asking from the kernel (the XPC connection's effective UID). Update
  Now for an app in someone else's home folder gets the same answer as for an app that doesn't
  exist, and Check Now counts only the asker's apps.
- Leases are named by a hash of the app's path, and a lease on an app in a home folder is
  readable only by root and that user.
- `/Library/Logs/barkeep.log` names every app, so it is readable only by root and `admin`. So is
  the unified log, which only administrators can read.

Barkeep.app ignores state and leases unless they are root-owned and writable only by root. They
contain app names, versions, paths and update sources, nothing secret.

## What barkeep remembers

An app that releases often is updated to the newest release that has cooled off, so barkeep has
to remember releases: each one's version, download address, checksum or signature, release date,
and when barkeep first saw it. Those dates decide when an update installs, so they are protected:

- They are in `State.json`, which only root can write. The daemon never reads the copies it
  makes for users, and Barkeep.app only displays the state.
- Every state the daemon saves is sealed: an HMAC-SHA256 of the file, in `State.seal`, under a
  random key in `Seal.key` (both mode 600, root). The daemon only acts on a state that matches
  its seal. One that doesn't (edited by hand, restored from somewhere else, damaged) is thrown
  away with a warning in the log, and barkeep starts again from what the feeds say now. That
  can only make an update wait longer, never install sooner.
- A remembered release is only a place to look. The download still has to pass every check
  above, and must hold the release that was chosen: if its address now serves a newer release
  that hasn't cooled off, it is refused.
- A feed can't use this to go backwards: only releases newer than the installed copy are kept,
  and one the feed has withdrawn is dropped.

The seal protects against everyone but root. Root can read the key, as it can replace barkeep
itself.

## Changing settings on the Mac

The Settings window in Barkeep.app has no privileges. To change a setting it asks for an
administrator's name and password (the authorization right `uk.street365.barkeep.settings`, which
the daemon defines: an administrator, remembered for five minutes by that window only, not shared
with other apps), and sends the authorization with each change. The daemon checks the
authorization itself, without asking anyone, so a process that merely runs as an administrator
can't change root's policy without the password. It refuses keys the profile sets and keys that
can only come from a profile (`AppSources`, `AppSettings`, `LogFilePath`,
`AllowUnverifiedSignatures`, `AllowFileURLs`), checks the value as it would a profile's, and
writes the file atomically.

## barkeep's own updates

From decant: the daemon only installs a barkeep package that matches its published SHA-256, is
signed by the same Developer ID team as the running barkeep, is notarised, and contains a newer
version. A copy that isn't Developer ID signed (a local build) never updates itself.

## Reporting a vulnerability

Please report security problems privately through GitHub's "Report a vulnerability" on the
repository, not in a public issue.
