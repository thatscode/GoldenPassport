# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

Notable changes in each release of this fork. Versions 0.1.0 to 0.1.7 were released by the
original project; see [its releases](https://github.com/stanzhai/GoldenPassport/releases).

## 0.2.0 (unreleased)

A ground-up rewrite for current macOS and a drop-in upgrade for 0.1.x: same app, same bundle id,
and your existing accounts are migrated automatically. The changes below are relative to 0.1.7,
the last release of the original project. To upgrade, run `install.sh` from the release package;
see [Installation](README.md#installation).

### Rewritten from scratch

- Swift Package instead of an Xcode project with CocoaPods; the Objective-C one-time-password
  code, the bundled google-toolbox-for-mac sources and the Swifter HTTP server are all gone.
- TOTP is implemented with CryptoKit and honours `algorithm`, `digits` and `period` from the
  otpauth URL (SHA1 / SHA256 / SHA512, 6–8 digits), verified against the RFC 6238 test vectors.
- Accounts are stored as an ordered list (`accounts.json`) instead of a dictionary whose order
  changed on every launch.
- Unit tests cover TOTP, URL parsing, storage, migration, the HTTP API, the update check and the
  translations.

### New features

- **English interface**: 0.1.x menus were in Chinese only. The interface follows the system
  language, or pick one in the menu under **Language / 语言**.
- **Manage window** (⌘M): drag or use the arrow buttons to reorder, double-click to rename,
  right-click to edit the URL or delete ([#12](https://github.com/stanzhai/GoldenPassport/issues/12), [#17](https://github.com/stanzhai/GoldenPassport/issues/17), [#29](https://github.com/stanzhai/GoldenPassport/issues/29)).
- **Configurable global hotkeys**: ⌃⌥⌘0–9 (new default), ⇧⌘0–9 (as in 0.1.x), ⌃⌥0–9, or off.
  Registered system-wide, so the keystroke no longer also reaches the frontmost app ([#4](https://github.com/stanzhai/GoldenPassport/issues/4), [#11](https://github.com/stanzhai/GoldenPassport/issues/11), [#18](https://github.com/stanzhai/GoldenPassport/issues/18)).
- **Export as an otpauth URL list** (`.txt`) that other authenticator apps can import; import
  accepts both this format and `.secrets` backups ([#10](https://github.com/stanzhai/GoldenPassport/issues/10), [#30](https://github.com/stanzhai/GoldenPassport/issues/30)).
- **Launch at login** toggle.
- **Update check**: **Check for Updates…** asks GitHub whether a newer release is out, and
  **Check for Updates Daily** does so once a day (off by default). If a release changes the data
  format or needs an intermediate upgrade first, the prompt says so before you install anything.
- The account name is suggested from the otpauth URL label, and pasted URLs are trimmed ([#26](https://github.com/stanzhai/GoldenPassport/issues/26)).
- **Installer with a safety net**: `install.sh` backs up the app and data, checks every migrated
  account and restores the previous app and data automatically if a check fails. `rollback.sh`
  puts back the previous app, and `cleanup.sh` deletes the unencrypted leftovers once you no
  longer need to roll back. Their messages follow the app's language.
- **Rolling back is a round trip**: accounts you add or change in 0.1.x after rolling back are
  listed when you upgrade again, and you choose which ones to import.

### Fixes

- Crashes when adding an account or reading a QR code image ([#1](https://github.com/stanzhai/GoldenPassport/issues/1), [#16](https://github.com/stanzhai/GoldenPassport/issues/16), [#21](https://github.com/stanzhai/GoldenPassport/issues/21), [#22](https://github.com/stanzhai/GoldenPassport/issues/22), [#25](https://github.com/stanzhai/GoldenPassport/issues/25), [#28](https://github.com/stanzhai/GoldenPassport/issues/28)).
- ⌘V / ⌘C / ⌘A now work in text fields ([#9](https://github.com/stanzhai/GoldenPassport/issues/9)).
- The HTTP index page declares UTF-8, so Chinese account names display correctly ([#26](https://github.com/stanzhai/GoldenPassport/issues/26)).
- Duplicate names are rejected instead of silently overwriting an existing account.
- Deleting an account asks for confirmation.
- The menu bar icon is visible to menu bar managers such as Bartender.

### Security & privacy

- The HTTP API is off on new installs. It has no password, so while it runs anything running as
  you on this Mac can read every code. Upgrades from 0.1.x keep their previous setting.
- GoldenPassport goes online only to check for updates, and only when you ask it to: choose
  **Check for Updates…**, or turn on **Check for Updates Daily** (off by default). The check asks
  GitHub's API for the latest release and, if it is newer, downloads that release's small
  `compat.json`. Requests identify themselves only as `GoldenPassport/<version>` and carry no
  cookies or account information. Nothing is downloaded or installed automatically.
- The HTTP API listens on 127.0.0.1 only and rejects requests with a foreign `Host` header
  ([#6](https://github.com/stanzhai/GoldenPassport/issues/6)), so web pages cannot read your codes through DNS rebinding.
- Data files are owner-only: the data directory is `0700` and files are `0600`. 0.1.x left them
  readable by every local user; 0.2.0 tightens the existing files without changing them.
- Both export formats warn that the file contains every secret unencrypted.
- See [Data & security](README.md#data--security) for every place a copy of your secrets can
  exist.

### Behaviour changes to be aware of

| | 0.1.x | 0.2.0 |
|---|---|---|
| Minimum macOS | 10.10 | **13** |
| Default hotkeys | ⇧⌘0–9 (3/4/5 clash with screenshots) | **⌃⌥⌘0–9**; ⇧⌘ is still available in the menu |
| Typing the code into the frontmost app | Accessibility permission | Still needs it, and it must be **granted again** after upgrading |
| HTTP API at launch | On unless you turned it off | **Off on new installs**; upgrades keep the 0.1.x setting |
| Data file | `gp.secrets` | `accounts.json` (migrated automatically on first launch; `gp.secrets` is kept but no longer updated) |
| Account order | Changed randomly between launches | Alphabetical after migration, then whatever order you set |
