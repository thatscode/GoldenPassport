# Installing GoldenPassport 0.2.x

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
> - Once 0.2.x works for you and you no longer need to roll back, **delete it with `cleanup.sh`**
>   (see [Cleaning up](#cleaning-up)).
> - `.secrets` and `.txt` exports also contain every secret unencrypted. Delete them when you are
>   done.

GoldenPassport 0.2.x is a ground-up rewrite for current macOS. It runs natively on Apple Silicon,
also runs on Intel, and needs macOS 13 or later. It keeps your accounts in your login Keychain
instead of a plaintext file. When you upgrade from 0.1.x or a beta, your accounts are moved there
automatically and the old data file is never modified, so you can roll back at any time.

## What's in this folder

| File | Purpose |
|---|---|
| `GoldenPassport.app` | The app |
| `install.sh` | Installs or upgrades, with a backup and a migration check |
| `rollback.sh` | Puts back the app you had before |
| `cleanup.sh` | Deletes the backups and the old data files once you no longer need to roll back |
| `INSTALL.md` / `安装说明.md` | These notes, in English and in Chinese |
| `LICENSE` | MIT license |

## Installing or upgrading

1. Open Terminal, type `bash ` (with a space after it), drag `install.sh` from this folder into
   the window and press Return.
2. The installer:
   1. checks the package and that your Mac and macOS version are supported;
   2. backs up the current app and data to `~/GoldenPassport-backups/<timestamp>/`;
   3. quits the running app and installs the new one to `/Applications`;
   4. moves your accounts into your login Keychain (from `gp.secrets` when upgrading from 0.1.x,
      from `accounts.json` when upgrading from a beta) and checks every entry against that file,
      printing account names only. **If anything doesn't match, it restores the previous app and
      data automatically**;
   5. starts GoldenPassport.

Use the same steps for a fresh install and for an upgrade from 0.1.x, from 0.2.0 or from a 0.2.0
beta.
Upgrading from a beta moves the accounts it has into the Keychain, so they stay as they are.

You can also copy `GoldenPassport.app` to `/Applications` yourself. Your data is then migrated on
first launch, but you get no backup and no migration check.

## Updating from within the app

From 0.2.3 on, most updates don't need this folder: when **Check for Updates…** finds a newer
release, click **Download and Install**. GoldenPassport checks the download's signature and that
the new version reads your accounts before it replaces anything, moves the previous version to the
Trash and opens the new one. If a check fails, nothing is changed. It points you back to
`install.sh` when a release changes the data format or needs an intermediate upgrade, when
GoldenPassport runs from a place it can't replace, or when your macOS account can't change it.

## After installing

- **Where your accounts are**: in your login Keychain, in an item named **GoldenPassport** that
  Keychain Access shows. It stays on this Mac and is not synced through iCloud. Apart from the old
  data files that `cleanup.sh` deletes (see [Cleaning up](#cleaning-up)), the data folder no longer
  holds any secrets. If macOS asks whether GoldenPassport may use your keychain, choose
  **Always Allow**, which asks for your login password. It asks once when you upgrade from 0.2.0,
  because 0.2.1 has a new bundle ID.
- **Launch at Login**: if you upgrade from 0.2.0 and had it on, turn it on again in the menu. If
  System Settings → General → Login Items still lists an old GoldenPassport entry, remove it.
- **Language**: the interface follows the system language. To pick one, choose it under
  **Language / 语言** in the menu, then click **Restart Now**.
- **Hotkeys** now default to ⌃⌥⌘0–9 (0.1.x used ⇧⌘0–9, whose 3/4/5 clash with the screenshot
  shortcuts). You can switch back under **Global Hotkeys** in the menu.
- **Typing the code for you** needs the Accessibility permission. You have to grant it again only
  when an upgrade changes the app's signing identity or bundle ID, as upgrading from 0.1.x, 0.2.0
  or a 0.2.0 beta does: System Settings → Privacy & Security → Accessibility. If GoldenPassport is
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
  accounts. Accounts you added or changed in 0.2.x are not visible to 0.1.x. To keep them, export
  a `.secrets` backup from 0.2.x first and import it into 0.1.x, then delete the export.
- **Back to a 0.2.0 beta**: betas keep the accounts in `accounts.json`, so the beta sees them as
  they were when 0.2.x moved them into the Keychain. To keep later changes, export a `.secrets`
  backup from 0.2.x first and import it into the beta. When you upgrade again, 0.2.x keeps using
  the Keychain; changes made in the beta are not carried over, and `cleanup.sh` lists them before
  it deletes `accounts.json`.
- **Further back**: without arguments, `rollback.sh` uses the newest backup, which is the version
  you had right before this install. To go back to 0.1.x after installing a beta and then this
  release, pass the oldest backup folder: type `bash `, drag `rollback.sh` into the window, type a
  space, drag the oldest folder from `~/GoldenPassport-backups/` into the window and press Return.
- `bash rollback.sh --restore-data` also resets the whole data folder to how it was before the
  install. Changes made since then are lost. The item in the Keychain is left as it is: installing
  0.2.x again migrates from the restored data and keeps the earlier item as
  `accounts.replaced-<time>`, which you can delete in Keychain Access.

Accounts you add or change in 0.1.x after rolling back are not lost when you upgrade again:
GoldenPassport lists what 0.1.x added, changed or deleted and lets you choose which accounts to
import. It never overwrites or deletes the accounts you already have; an account whose URL changed
in 0.1.x is imported next to the existing one as "name (0.1.x)".

## Cleaning up

Once 0.2.x works for you and you no longer need to roll back, type `bash ` in Terminal, drag
`cleanup.sh` into the window and press Return. It checks that your accounts read back from the
Keychain, lists what it will delete and deletes only after you type `yes`. After that you can no
longer roll back to 0.1.x or a beta; 0.2.x itself keeps working as before.

These places contain your secrets:

| Location | Contents | What to do |
|---|---|---|
| Login Keychain, item **GoldenPassport** | The accounts 0.2.x uses | Keep |
| `~/GoldenPassport-backups/` | The app and data as they were before each install, unencrypted | **Delete** (`cleanup.sh` does this) |
| `~/Library/Application Support/GoldenPassport/accounts.json` | A beta's data file, unencrypted, kept for rolling back to the beta. Changes you make in 0.2.x are not in it | Delete once you won't go back to a beta (`cleanup.sh` does this) |
| `~/Library/Application Support/GoldenPassport/gp.secrets` | The 0.1.x data file, kept for rolling back. Accounts you delete in 0.2.x **are still in it** | Delete once you won't go back to 0.1.x (`cleanup.sh` does this) |
| `.secrets` / `.txt` files you exported | Every secret, unencrypted | Delete when you are done |

`cleanup.sh` also deletes the 0.1.x `config.plist` and `legacy-baseline.json`, which records only
account names and URL fingerprints, no secrets. Before deleting anything, it warns you if 0.2.x
holds fewer accounts than `gp.secrets`, if accounts you changed in 0.1.x after a rollback haven't
been imported yet, or if `accounts.json` has accounts the Keychain doesn't: their secrets exist
only in the files it is about to delete.

0.2.x makes the data folder and the 0.1.x data files readable only by you (0.1.x left them
readable by every user on this Mac). Their contents are not changed.

## Getting help

- Full documentation: <https://github.com/thatscode/GoldenPassport>
- Problems and questions: [open an issue](https://github.com/thatscode/GoldenPassport/issues). The
  install, rollback and cleanup scripts print account names only, never secrets, so you can paste
  their output. **Never attach data files, backups or exports**: they contain your secrets.
- Security problems: please don't open a public issue. Use
  [Report a vulnerability](https://github.com/thatscode/GoldenPassport/security/advisories/new) to
  tell the maintainers privately.
