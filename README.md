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

# Building

Requires Xcode 16+ (Swift 6 toolchain). No third-party dependencies.

```
make test      # unit tests (TOTP RFC 6238 vectors, URL parsing, storage, migration, HTTP API)
make dev       # isolated "GoldenPassport Dev.app": own bundle id, data dir, port 17305, hotkeys off
make run-dev   # build and launch the Dev app
make release   # "GoldenPassport.app", drop-in replacement for the installed app
```

Apps are written to `~/Library/Caches/GoldenPassport-build/<variant>/` (kept out of the
source tree because iCloud-synced folders break code signing). `ARCHS="arm64 x86_64"`
builds a universal binary.

On first launch, data from 0.1.x (`gp.secrets`, `config.plist`) is migrated to
`accounts.json` / `settings.json` in the same directory; the legacy files are left in place.
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
