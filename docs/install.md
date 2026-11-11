# Installing GoldenPassport 0.2.0

> [!CAUTION]
> **⚠️ Installing leaves an unencrypted copy of your MFA secrets on disk**
>
> The installer backs up your current app and data to **`~/GoldenPassport-backups/`**. That
> folder holds **every one of your MFA secrets, unencrypted**: anyone who gets it can generate
> codes for all your accounts.
>
> - **Don't** copy, upload or send it to anyone, including the maintainers when you ask for help.
> - **Don't** keep it in iCloud Drive or another synced folder, or in a backup that goes to the
>   cloud.
> - Once 0.2.0 works for you and you no longer need to roll back, **delete it with `cleanup.sh`**
>   (see [Cleaning up](#cleaning-up)).
> - `.secrets` and `.txt` exports also contain every secret unencrypted. Delete them when you are
>   done.

GoldenPassport 0.2.0 is a ground-up rewrite for current macOS. It runs natively on Apple Silicon,
also runs on Intel, and needs macOS 13 or later. When you upgrade from 0.1.x, your accounts are
migrated automatically and the old data file is never modified, so you can roll back at any time.

## What's in this folder

| File | Purpose |
|---|---|
| `GoldenPassport.app` | The app |
| `install.sh` | Installs or upgrades, with a backup and a migration check |
| `rollback.sh` | Puts back the app you had before |
| `cleanup.sh` | Deletes the backups and the 0.1.x data files once you no longer need to roll back |
| `INSTALL.md` / `安装说明.md` | These notes, in English and in Chinese |
| `LICENSE` | MIT license |

## Installing or upgrading

1. Open Terminal, type `bash ` (with a space after it), drag `install.sh` from this folder into
   the window and press Return.
2. The installer:
   1. checks the package and that your Mac and macOS version are supported;
   2. backs up the current app and data to `~/GoldenPassport-backups/<timestamp>/`;
   3. quits the running app and installs the new one to `/Applications`;
   4. when upgrading from 0.1.x, migrates your accounts and checks every entry against
      `gp.secrets`, printing account names only. **If anything doesn't match, it restores the
      previous app and data automatically**;
   5. starts GoldenPassport.

Use the same steps for a fresh install, an upgrade from 0.1.x and an upgrade from a 0.2.0 beta.
Upgrading from a beta keeps your accounts as they are.

You can also copy `GoldenPassport.app` to `/Applications` yourself. Your data is then migrated on
first launch, but you get no backup and no migration check.

## After installing

- **Language**: the interface follows the system language. To pick one, choose it under
  **Language / 语言** in the menu, then click **Restart Now**.
- **Hotkeys** now default to ⌃⌥⌘0–9 (0.1.x used ⇧⌘0–9, whose 3/4/5 clash with the screenshot
  shortcuts). You can switch back under **Global Hotkeys** in the menu.
- **Typing the code for you** needs the Accessibility permission, and you have to grant it again
  after upgrading: System Settings → Privacy & Security → Accessibility. If GoldenPassport is
  already listed but typing doesn't work, remove it with "−" and pick a hotkey option in the menu
  again to get a fresh prompt. Without the permission, hotkeys copy the code to the clipboard.
- **The HTTP API is off on new installs.** It has no password, so while it runs anything running
  as you on this Mac can read every code. Upgrades from 0.1.x keep their previous setting. If you
  used a 0.2.0 beta older than beta.3 and never changed **Start HTTP Server at Launch** there, the
  server no longer starts with the app; turn it back on under **HTTP API** in the menu if you
  need it.
- **Network**: GoldenPassport goes online only to check for updates, and only when you choose
  **Check for Updates…** or turn on **Check for Updates Daily** (off by default).

## Rolling back

In Terminal, type `bash `, drag `rollback.sh` into the window and press Return. It puts back the
app that was installed before; your data stays as it is.

- **Back to 0.1.x**: your original `gp.secrets` was never modified, so 0.1.x finds all its
  accounts. Accounts you added or changed in 0.2.0 are not visible to 0.1.x. To keep them, export
  a `.secrets` backup from 0.2.0 first and import it into 0.1.x, then delete the export.
- **Back to a 0.2.0 beta**: it reads the same `accounts.json`, so all your accounts stay as they
  are.
- **Further back**: without arguments, `rollback.sh` uses the newest backup, which is the version
  you had right before this install. To go back to 0.1.x after installing a beta and then this
  release, pass the oldest backup folder: type `bash `, drag `rollback.sh` into the window, type a
  space, drag the oldest folder from `~/GoldenPassport-backups/` into the window and press Return.
- `bash rollback.sh --restore-data` also resets the whole data folder to how it was before the
  install. Changes made since then are lost.

Accounts you add or change in 0.1.x after rolling back are not lost when you upgrade again:
GoldenPassport lists what 0.1.x added, changed or deleted and lets you choose which accounts to
import. It never overwrites or deletes the accounts you already have; an account whose URL changed
in 0.1.x is imported next to the existing one as "name (0.1.x)".

## Cleaning up

Once 0.2.0 works for you and you no longer need to roll back, type `bash ` in Terminal, drag
`cleanup.sh` into the window and press Return. It checks that `accounts.json` reads back cleanly,
lists what it will delete and deletes only after you type `yes`. After that you can no longer roll
back to 0.1.x; 0.2.0 itself keeps working as before.

These files contain your secrets:

| Location | Contents | What to do |
|---|---|---|
| `~/GoldenPassport-backups/` | The app and data as they were before each install | **Delete** (`cleanup.sh` does this) |
| `~/Library/Application Support/GoldenPassport/accounts.json` | The data 0.2.0 uses | Keep |
| `~/Library/Application Support/GoldenPassport/gp.secrets` | The 0.1.x data file, kept for rolling back. Accounts you delete in 0.2.0 **are still in it** | Delete once you won't go back to 0.1.x (`cleanup.sh` does this) |
| `.secrets` / `.txt` files you exported | Every secret, unencrypted | Delete when you are done |

`cleanup.sh` also deletes the 0.1.x `config.plist` and `legacy-baseline.json`, which records only
account names and URL fingerprints, no secrets. Before deleting anything, it warns you if 0.2.0
holds fewer accounts than `gp.secrets`, or if accounts you changed in 0.1.x after a rollback
haven't been imported yet: their secrets exist only in the files it is about to delete.

0.2.0 makes the data folder and the 0.1.x data files readable only by you (0.1.x left them
readable by every user on this Mac). Their contents are not changed.

## Getting help

- Full documentation: <https://github.com/thatscode/GoldenPassport>
- Problems and questions: [open an issue](https://github.com/thatscode/GoldenPassport/issues). The
  install, rollback and cleanup scripts print account names only, never secrets, so you can paste
  their output. **Never attach data files, backups or exports**: they contain your secrets.
- Security problems: please don't open a public issue. Use
  [Report a vulnerability](https://github.com/thatscode/GoldenPassport/security/advisories/new) to
  tell the maintainers privately.
