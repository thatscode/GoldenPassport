# GoldenPassport

English | [简体中文](README.zh-CN.md)

A native Google Authenticator for the macOS menu bar: TOTP codes one click (or one hotkey) away.

> **This is a maintained fork of [stanzhai/GoldenPassport](https://github.com/stanzhai/GoldenPassport).**
> The original project has been inactive since 2022 and its Homebrew cask was disabled in
> September 2026. Version 0.2.0 here is a ground-up rewrite for current macOS and a drop-in
> upgrade for 0.1.x users: same app, same bundle id, your existing accounts are migrated
> automatically. All credit for the original idea and design goes to
> [StanZhai](https://github.com/stanzhai).

- Native Swift, **Apple Silicon native** (universal builds also run on Intel), macOS 13 or later
- No third-party dependencies
- English and Simplified Chinese interface: follows the system language, or pick one in the
  menu under 语言 / Language

# Screenshots

- [Menu bar menu](#menu-bar-menu)
- [Adding an account](#adding-an-account)
- [Managing accounts](#managing-accounts)
- [Hotkey settings](#hotkey-settings)
- [Local HTTP API](#local-http-api)

### Menu bar menu

Click the key icon in the menu bar. The top line counts down until the codes change. Each account
is listed as `name: code`; click a row to copy its code. The first ten accounts show their global
hotkey on the right. Below the list are account management, the local HTTP API, hotkey settings
and launch at login.

<img src="screenshot/menu.png" alt="Menu bar menu" width="380">

### Adding an account

Choose 添加... (⌘A) and paste an `otpauth://` URL, or pick a QR code image with
从二维码图片识别.... The name (标识) is filled in from the URL label; edit it before adding if you like.

<img src="screenshot/add-window.png" alt="Add an account" width="560">

### Managing accounts

管理（排序 / 重命名）... (⌘M) lists every account in menu order. Drag rows or use the arrow buttons
to reorder; the first ten rows show which hotkey they get. Double-click a row to rename it, or
right-click for 重命名 (rename), 修改 URL (edit URL) and 删除 (delete); the same actions are
available as buttons at the bottom.

<img src="screenshot/manage-window.png" alt="Manage accounts" width="560">

### Hotkey settings

The 全局快捷键 submenu sets the modifier keys used with 0–9: ⌃⌥⌘ (default), ⇧⌘ as in 0.1.x
(3/4/5 clash with the system screenshot shortcuts), ⌃⌥, or 关闭 (off). The checkmark shows the
current choice.

<img src="screenshot/hotkeys.png" alt="Global hotkeys" width="640">

### Local HTTP API

With the HTTP API turned on, `http://localhost:17304/` lists every account with its current code.
Each entry links to `/code/<name>`, which returns just the code as plain text for use in scripts.
Chinese account names display correctly.

<img src="screenshot/restful-api.png" alt="Local HTTP API in a browser" width="560">

# What's new in 0.2.0

Compared with the original 0.1.7 release.

### Rewritten from scratch

- Swift Package instead of an Xcode project with CocoaPods; the Objective-C one-time-password
  code, the bundled google-toolbox-for-mac sources and the Swifter HTTP server are all gone.
- TOTP is implemented with CryptoKit and honours `algorithm`, `digits` and `period` from the
  otpauth URL (SHA1 / SHA256 / SHA512, 6–8 digits), verified against the RFC 6238 test vectors.
- Accounts are stored as an ordered list (`accounts.json`) instead of a dictionary whose order
  changed on every launch.
- 41 unit tests cover TOTP, URL parsing, storage, migration and the HTTP API.

### New features

- **Manage window** (⌘M): drag or use the arrow buttons to reorder, double-click to rename,
  right-click to edit the URL or delete ([#12](https://github.com/stanzhai/GoldenPassport/issues/12), [#17](https://github.com/stanzhai/GoldenPassport/issues/17), [#29](https://github.com/stanzhai/GoldenPassport/issues/29)).
- **Configurable global hotkeys**: ⌃⌥⌘0–9 (new default), ⇧⌘0–9 (as in 0.1.x), ⌃⌥0–9, or off.
  Registered system-wide, so the keystroke no longer also reaches the frontmost app ([#4](https://github.com/stanzhai/GoldenPassport/issues/4), [#11](https://github.com/stanzhai/GoldenPassport/issues/11), [#18](https://github.com/stanzhai/GoldenPassport/issues/18)).
- **Export as an otpauth URL list** (`.txt`) that other authenticator apps can import; import
  accepts both this format and `.secrets` backups ([#10](https://github.com/stanzhai/GoldenPassport/issues/10), [#30](https://github.com/stanzhai/GoldenPassport/issues/30)).
- **Launch at login** toggle.
- The account name is suggested from the otpauth URL label, and pasted URLs are trimmed ([#26](https://github.com/stanzhai/GoldenPassport/issues/26)).

### Fixes

- Crashes when adding an account or reading a QR code image ([#1](https://github.com/stanzhai/GoldenPassport/issues/1), [#16](https://github.com/stanzhai/GoldenPassport/issues/16), [#21](https://github.com/stanzhai/GoldenPassport/issues/21), [#22](https://github.com/stanzhai/GoldenPassport/issues/22), [#25](https://github.com/stanzhai/GoldenPassport/issues/25), [#28](https://github.com/stanzhai/GoldenPassport/issues/28)).
  Please reopen with details if you still see one.
- ⌘V / ⌘C / ⌘A now work in text fields ([#9](https://github.com/stanzhai/GoldenPassport/issues/9)).
- The HTTP index page declares UTF-8, so Chinese account names display correctly ([#26](https://github.com/stanzhai/GoldenPassport/issues/26)).
- Duplicate names are rejected instead of silently overwriting an existing account.
- Deleting an account asks for confirmation.
- The menu bar icon is visible to menu bar managers such as Bartender.

### Security & privacy

- The HTTP API listens on 127.0.0.1 only and rejects requests with a foreign `Host` header
  ([#6](https://github.com/stanzhai/GoldenPassport/issues/6)), so web pages cannot read your codes through DNS rebinding.
- Data files are owner-only: the data directory is `0700` and files are `0600`. 0.1.x left them
  readable by every local user; 0.2.0 tightens the existing files without changing them.
- Both export formats warn that the file contains every secret unencrypted.
- See [Data & security](#data--security) for every place a copy of your secrets can exist.

### Behaviour changes to be aware of

| | 0.1.x | 0.2.0 |
|---|---|---|
| Minimum macOS | 10.10 | **13** |
| Default hotkeys | ⇧⌘0–9 (3/4/5 clash with screenshots) | **⌃⌥⌘0–9**; ⇧⌘ is still available in the menu |
| Typing the code into the frontmost app | Accessibility permission | Still needs it, and it must be **granted again** after upgrading |
| Data file | `gp.secrets` | `accounts.json` (migrated automatically on first launch; `gp.secrets` is kept but no longer updated) |
| Account order | Changed randomly between launches | Alphabetical after migration, then whatever order you set |

# Installation

> [!NOTE]
> Builds are **not yet notarized by Apple**, so macOS blocks them when opened from a download.
> The installer below handles this for you. Notarized releases and the Homebrew cask are on the
> [roadmap](#roadmap). `brew install --cask goldenpassport` installs the old 0.1.7 and is
> currently disabled by Homebrew.

### Upgrading from 0.1.x, or installing fresh (recommended)

1. Download `GoldenPassport-<version>.zip` from the [releases](https://github.com/thatscode/GoldenPassport/releases)
   page of this fork and unzip it.
2. In Terminal, run `bash `, drag `install.sh` from the unzipped folder into the window and
   press Return.

The installer:

1. checks the package and that your Mac and macOS version are supported;
2. backs up the current app and data to `~/GoldenPassport-backups/<timestamp>/`
   (⚠️ this contains your secrets unencrypted, see [Data & security](#data--security));
3. quits the running app and installs the new one to `/Applications`;
4. migrates your accounts and checks every entry against `gp.secrets`, printing account names
   only. **If anything does not match, it restores the previous app and data automatically**;
5. starts GoldenPassport.

<!-- SCREENSHOT install.png: Terminal after a successful install.sh run, showing the
     "已从旧版迁移 N 条记录…逐条一致" line and the warning box. Crop out your username/paths
     if you prefer. -->
<!-- ![Installer output](screenshot/install.png) -->

After upgrading, grant **Accessibility** again if you want hotkeys to type the code for you:
System Settings → Privacy & Security → Accessibility. If GoldenPassport is already listed but
typing doesn't work, remove it with "−" and pick a hotkey option in the menu again to get a
fresh prompt. Without the permission, hotkeys copy the code to the clipboard.

### Rolling back

Run `bash rollback.sh` from the same folder. It restores the app that was installed before; your
original `gp.secrets` was never modified, so 0.1.x finds all its accounts. Accounts you added
or changed in 0.2.0 are not visible to 0.1.x. To keep them, first export a `.secrets` backup
from 0.2.0 and import it into 0.1.x. `bash rollback.sh --restore-data` also resets the data
directory to its pre-install state.

### Cleaning up after the upgrade

Once 0.2.0 works for you and you no longer need to roll back, run `bash cleanup.sh` from the same
folder. It checks that `accounts.json` reads back cleanly, lists what it will delete (the installer
backups and the legacy `gp.secrets` / `config.plist`, all of which contain your secrets
unencrypted), warns if 0.2.0 holds fewer accounts than the legacy file, and deletes only after you
type `yes`. After that, rolling back to 0.1.x is no longer possible.

### Manual installation

Copy `GoldenPassport.app` to `/Applications`, then either run
`xattr -dr com.apple.quarantine /Applications/GoldenPassport.app` or open it once and choose
"Open Anyway" in System Settings → Privacy & Security. Your data is migrated on first launch,
but you get no backup and no migration check.

# Usage

Click the key icon in the menu bar. Each account shows its current code; click one to copy it.

| Menu item | What it does |
|---|---|
| 添加... (⌘A) | Add an account from an otpauth URL or a QR code image |
| 管理（排序 / 重命名）... (⌘M) | Reorder, rename, edit or delete accounts |
| 删除 (⌘D) | Delete an account (asks for confirmation) |
| 导入... (⌘I) | Import a `.secrets` backup or an otpauth URL list; existing names are skipped |
| 导出 → 备份文件 (.secrets) | Backup readable by both 0.1.x and 0.2.x |
| 导出 → otpauth URL 列表 (.txt) | One otpauth URL per account, for other authenticator apps |
| HTTP 接口 | Start or stop the local API, start it at launch, open it in the browser, change the port |
| 全局快捷键 | Choose the modifier keys for the hotkeys, or turn them off |
| 开机自动启动 | Launch GoldenPassport at login |
| 语言 / Language | Follow the system language, or always use 简体中文 or English (restarts the app) |
| 帮助 (⌘H) | Open the project page on GitHub |

### Global hotkeys

Modifier + **0** fills in the code of the **first** account in the list, modifier + **1** the
second, and so on up to **9** for the tenth. Reorder accounts in the manage window to choose which
ones get hotkeys.

### RESTful API

When enabled, GoldenPassport serves codes on `http://localhost:17304/` (the port can be changed
in the menu). It listens on 127.0.0.1 only.

| Endpoint | Response |
|---|---|
| `GET /` | HTML page listing your accounts, linking to their codes |
| `GET /code/<account name>` | The current code as plain text; `404` if no account has that name |

```sh
code=$(curl -s 'http://localhost:17304/code/test@stanzhai.site')
echo "$code"
```

# Data & security

> [!CAUTION]
> **Upgrading from 0.1.x leaves unencrypted copies of your MFA secrets on disk.**
>
> - **Installer backup**: `scripts/install.sh` copies the whole data directory to
>   `~/GoldenPassport-backups/<timestamp>/` so it can roll back. This is a plaintext copy of
>   every secret (owner-only permissions). Never share or sync it, and delete it once you no
>   longer need to roll back (`scripts/cleanup.sh`, see below).
> - **Legacy data file**: after migration, `gp.secrets` stays in the data directory so the
>   old app keeps working. It is never updated again, so **accounts you delete in 0.2.x
>   remain in it**. Delete it once you are sure you won't go back to 0.1.x (`scripts/cleanup.sh`).
> - **Exports**: both `.secrets` and `.txt` exports contain every secret unencrypted.
> - **Dev build**: `make dev` copies the release data into `GoldenPassport-Dev/` on first
>   launch; delete that directory when you are done developing.

All data lives in `~/Library/Application Support/GoldenPassport/` (`accounts.json`,
`settings.json`, plus the legacy `gp.secrets` / `config.plist`). Secrets are stored
unencrypted, protected only by file permissions: 0.2.x restricts the directory to `0700`
and its files to `0600` (0.1.x left them readable by every local user).

# Building

Requires Xcode 16+ (Swift 6 toolchain). No third-party dependencies.

```
make test      # unit tests (TOTP RFC 6238 vectors, URL parsing, storage, migration, HTTP API)
make dev       # isolated "GoldenPassport Dev.app": own bundle id, data dir, port 17305, hotkeys off
make run-dev   # build and launch the Dev app
make release   # "GoldenPassport.app", drop-in replacement for the installed app
make beta      # universal release + install.sh / rollback.sh / tester notes, zipped under dist/
```

Apps are written to `~/Library/Caches/GoldenPassport-build/<variant>/` (kept out of the
source tree because iCloud-synced folders break code signing). `ARCHS="arm64 x86_64"`
builds a universal binary. Builds are ad-hoc signed with the hardened runtime.

On first launch, data from 0.1.x (`gp.secrets`, `config.plist`) is migrated to
`accounts.json` / `settings.json` in the same directory; the legacy files are left in place
(see [Data & security](#data--security)). `GoldenPassport --migrate-data [--data-dir PATH]`
runs the same migration headlessly and verifies it; `scripts/install.sh` relies on it.
The Dev build copies the release data into `GoldenPassport-Dev/` instead and never writes
to the release data directory, so it can run next to the installed app.

`scripts/rollback.sh` restores the app replaced by `install.sh`. `scripts/cleanup.sh` deletes the
installer backups and the legacy `gp.secrets` / `config.plist` once you are done with 0.1.x; it
refuses to run unless 0.2.x is installed and `accounts.json` reads back cleanly. Tester instructions
(Chinese) are in [`docs/beta-testing.md`](docs/beta-testing.md).

# Roadmap

- Developer ID signing and notarization, so downloads open without workarounds
- Bring the Homebrew cask back
- Optionally store secrets in the Keychain

# Credits & license

GoldenPassport was created by [StanZhai](https://github.com/stanzhai) in 2017. This fork is
maintained by [thatscode](https://github.com/thatscode).

The original repository does not include a license. We have asked the author to add one in
[stanzhai/GoldenPassport#33](https://github.com/stanzhai/GoldenPassport/issues/33); this fork
will adopt it once it is available.

# Resources

- [RFC 6238: TOTP](https://www.rfc-editor.org/rfc/rfc6238)
- [Key URI format (otpauth://)](https://github.com/google/google-authenticator/wiki/Key-Uri-Format)
- [google-authenticator](https://github.com/google/google-authenticator)
