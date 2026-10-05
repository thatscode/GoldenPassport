# GoldenPassport

A native implementation of Google Authenticator for Mac, written in Swift (Apple Silicon native, macOS 13+).

# Screenshot

![main](screenshot/main.png)

![add](screenshot/add-window.png)

![restful-api](screenshot/restful-api.png)

# Features

- Recognize OTPAuth URL from a QRCode image
- Authentication code management: reorder, rename, edit, delete
- Honours `algorithm` / `digits` / `period` from the otpauth URL (SHA1/SHA256/SHA512, 6–8 digits)
- Support RESTful API to obtain the verification code (bound to 127.0.0.1 only)
- Global hot keys (`⌃⌥⌘0`–`⌃⌥⌘9` by default, or `⇧⌘` as in 0.1.x) type the code of the first ten accounts into the frontmost app
- Click an auth-menu to copy the verification code to the `PasteBoard`
- Export/Import: `.secrets` backup (compatible with 0.1.x) or a plain-text otpauth URL list
- Launch at login

# How to use

1. Download the latest version of GoldenPassport from the [releases](https://github.com/stanzhai/GoldenPassport/releases) page.
2. Unzip `GoldenPassport.zip` and put `GoldenPassport.app` to your `Application` folder then start it. 
3. Add an auth URL from the status menu.

Or you can install if from brew cask

```
brew install --cask goldenpassport
```

Now, you can get the verification code by:

- From the status menu, copy the verification by clicking an auth-menu 
- Use a global hot key (`⌃⌥⌘0`–`⌃⌥⌘9` by default, configurable in the menu) to fill in the verification code; typing it for you requires the Accessibility permission

You can also use the RESTful API if you want to get the verification code from a shell script by the following way:

```
# you can get the url from `http://localhost:17304/`
code=$(curl 'http://localhost:17304/code/test@stanzhai.site')
# ues the verification code
echo $code
```

# Data & security

> [!CAUTION]
> **Upgrading from 0.1.x leaves unencrypted copies of your MFA secrets on disk.**
>
> - **Installer backup** — `scripts/install.sh` copies the whole data directory to
>   `~/GoldenPassport-backups/<timestamp>/` so it can roll back. This is a plaintext copy of
>   every secret (owner-only permissions). Never share or sync it, and delete it once you no
>   longer need to roll back: `rm -rf ~/GoldenPassport-backups`.
> - **Legacy data file** — after migration, `gp.secrets` stays in the data directory so the
>   old app keeps working. It is never updated again, so **accounts you delete in 0.2.x
>   remain in it**. Delete it once you are sure you won't go back to 0.1.x.
> - **Exports** — both `.secrets` and `.txt` exports contain every secret unencrypted.
> - **Dev build** — `make dev` copies the release data into `GoldenPassport-Dev/` on first
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

`scripts/install.sh` upgrades an existing installation safely: it backs up the app and
data directory to `~/GoldenPassport-backups/<timestamp>/`, replaces the app, runs
`GoldenPassport --migrate-data` to migrate and verify every legacy entry (names only are
printed), and restores the previous state automatically if verification fails.
`scripts/rollback.sh` puts the previous app back. Tester instructions (Chinese) are in
`docs/beta-testing.md`.

Apps are written to `~/Library/Caches/GoldenPassport-build/<variant>/` (kept out of the
source tree because iCloud-synced folders break code signing). `ARCHS="arm64 x86_64"`
builds a universal binary.

On first launch, data from 0.1.x (`gp.secrets`, `config.plist`) is migrated to
`accounts.json` / `settings.json` in the same directory; the legacy files are left in place
(see [Data & security](#data--security)).
The Dev build copies the release data into `GoldenPassport-Dev/` instead and never writes
to the release data directory.

# Todo

- English localization
- Optionally store secrets in the Keychain

# Resources

- [Swift Resources](https://developer.apple.com/swift/resources/)
- [macOS Development Tutorials](https://www.raywenderlich.com/category/macos)
- [google-authenticator](https://github.com/google/google-authenticator)
- [WeatherBar](http://footle.org/WeatherBar/)
- [swifter](https://github.com/httpswift/swifter)
