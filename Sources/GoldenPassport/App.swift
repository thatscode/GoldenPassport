import AppKit
import GoldenPassportCore

@main
enum GoldenPassportApp {
    static func main() {
        if CommandLine.arguments.contains("--migrate-data") {
            exit(runMigrateData(Array(CommandLine.arguments.dropFirst())))
        }
        // Started by an update installed from the app: give the old copy up to 10 seconds to quit,
        // then the single-copy check runs as usual (docs/design/in-app-update.md, 5.5).
        let update = UpdateLaunchArguments(arguments: CommandLine.arguments)
        if let oldProcess = update.oldProcessID {
            _ = UpdateLaunchArguments.waitForExit(of: oldProcess)
        }
        // The language chosen in the menu and the menu bar icon's position live in the defaults of
        // the bundle id; carry them over from the old one (0.1.x, 0.2.0) before anything is
        // localized and before the status item is created.
        if let legacyID = legacyBundleIdentifier, let bundleID = Bundle.main.bundleIdentifier {
            LegacyPreferences.carryOver(from: legacyID, to: bundleID)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(updatedFrom: update.updatedFrom)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// `GoldenPassport --migrate-data [--data-dir PATH]`, used by scripts/install.sh.
    /// Exit codes: 0 consistent, 3 migrated data does not match gp.secrets, 2 error.
    private static func runMigrateData(_ arguments: [String]) -> Int32 {
        var environment = AppEnvironment.fromBundle()
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            environment.dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            environment.seedDirectory = nil
        }
        do {
            let check = try MigrationCheck.run(environment: environment)
            print("data_dir=\(environment.dataDirectory.path)\n\(check.report)")
            return check.isConsistent ? 0 : 3
        } catch {
            FileHandle.standardError.write(Data("error=\(error.localizedDescription)\n".utf8))
            return 2
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?
    /// The version an in-app update replaced, when this copy was started by it.
    private let updatedFrom: String?

    init(updatedFrom: String?) {
        self.updatedFrom = updatedFrom
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        // A second copy (say, one opened from the download folder while the installed one runs)
        // would add a second menu bar icon, fight over the hotkeys and the HTTP port, and save its
        // own account list over the other's. Stop before touching any data.
        if let other = otherRunningCopy() {
            // The same app started twice (say, by two login items) just stops; another copy says so.
            if other.bundleURL?.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
                showAlreadyRunning(other)
            }
            NSApp.terminate(nil)
            return
        }

        let environment = AppEnvironment.fromBundle()
        guard let store = openAccountStore(environment) else {
            NSApp.terminate(nil)
            return
        }
        let settings = SettingsStore(directory: environment.dataDirectory, defaults: environment.defaults)
        statusMenuController = StatusMenuController(
            store: store,
            settings: settings,
            dataDirectory: environment.dataDirectory,
            dataFormat: environment.dataFormat)

        // Whatever an update download left behind is no longer needed once a copy starts.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UpdateDownloader.clearCache(bundleIdentifier: bundleIdentifier)
        }
        if updatedFrom != nil, let version = AppVersion(bundleInfo: Bundle.main.infoDictionary ?? [:]) {
            let hotkeysEnabled = settings.hotkeysEnabled
            DispatchQueue.main.async {
                UpdateController.showUpdatedNotice(version: version.description, hotkeysEnabled: hotkeysEnabled)
            }
        }
    }

    /// Another running copy of this app, under this bundle id or the one 0.1.x and 0.2.0 used.
    private func otherRunningCopy() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return [Bundle.main.bundleIdentifier, legacyBundleIdentifier].compactMap { $0 }
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private func showAlreadyRunning(_ other: NSRunningApplication) {
        let alert = NSAlert()
        alert.messageText = String(localized: "GoldenPassport 已经在运行")
        var text = String(localized: "请使用菜单栏里正在运行的那一份。为了避免两份同时修改你的账号，这一份不会启动。如果想改用这一份，先在菜单栏里退出正在运行的那一份，再重新打开这一份。")
        // A copy opened straight from a download runs from a random AppTranslocation path,
        // which would only confuse.
        if let path = other.bundleURL?.path, !path.contains("/AppTranslocation/") {
            text += "\n\n" + String(localized: "正在运行的是：\(path)")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "好"))
        activateApp()
        alert.runModal()
    }

    /// Prepares the data directory and opens the accounts. When the Keychain can't be read,
    /// says why and lets the user retry or, if the item is gone, choose how to start again
    /// (docs/design/d3-keychain.md 5.5). nil means quit; no data was changed.
    private func openAccountStore(_ environment: AppEnvironment) -> AccountStore? {
        while true {
            do {
                try environment.prepareDataDirectory()
                return try environment.openAccountStore()
            } catch let error as KeychainError {
                switch askAfterKeychainFailure(error, environment: environment) {
                case .retry:
                    continue
                case .remigrate:
                    perform { try environment.remigrate() }
                case .startEmpty:
                    perform { try environment.startWithNoAccounts() }
                case .quit:
                    return nil
                }
            } catch {
                showStartupFailure(error, dataDirectory: environment.dataDirectory)
                return nil
            }
        }
    }

    /// Runs a recovery the user chose; if it fails, says so, and the next attempt to open
    /// the accounts shows where things stand.
    private func perform(_ recovery: () throws -> Void) {
        do {
            try recovery()
        } catch {
            showAlert(String(localized: "没有完成"), informative: error.localizedDescription, style: .warning)
        }
    }

    private enum KeychainRecovery {
        case retry, remigrate, startEmpty, quit
    }

    private func askAfterKeychainFailure(_ error: KeychainError, environment: AppEnvironment) -> KeychainRecovery {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "无法读取钥匙串里的账号")
        let unchanged = String(localized: "GoldenPassport 没有改动任何数据。")
        var actions: [KeychainRecovery] = []
        switch error {
        case .denied:
            alert.informativeText = error.localizedDescription + "\n\n"
                + String(localized: "点「重试」后，在系统的授权框里选择「始终允许」。") + "\n\n" + unchanged
            alert.addButton(withTitle: String(localized: "重试"))
            actions.append(.retry)
        case .locked:
            alert.informativeText = error.localizedDescription + "\n\n"
                + String(localized: "可以在「钥匙串访问」里解锁「登录」钥匙串，然后点「重试」。") + "\n\n" + unchanged
            alert.addButton(withTitle: String(localized: "重试"))
            actions.append(.retry)
        case .missing:
            alert.messageText = String(localized: "钥匙串里找不到账号数据")
            let explanation = String(localized: "数据目录里的 accounts-v2.json 表明账号存放在钥匙串里，但这个条目已经不在了：可能在「钥匙串访问」里被删除了，也可能只把数据目录拷到了这台 Mac。")
            if let source = environment.remigrationSource {
                alert.informativeText = explanation + "\n\n"
                    + String(localized: "可以从 \(source) 重新迁移。注意：那是迁移到钥匙串之前的数据，之后新增、修改或删除的账号都不在里面。如果你有更新的导出文件，迁移后可以再导入它。") + "\n\n" + unchanged
                alert.addButton(withTitle: String(localized: "从 \(source) 重新迁移"))
                actions.append(.remigrate)
            } else {
                alert.informativeText = explanation + "\n\n"
                    + String(localized: "数据目录里没有可以重新迁移的旧文件。可以从空列表开始，再导入你导出的 .secrets 文件；也可以先退出，从备份恢复钥匙串。") + "\n\n" + unchanged
                alert.addButton(withTitle: String(localized: "从空列表开始"))
                actions.append(.startEmpty)
            }
        case .unreadable, .newerFormat:
            alert.informativeText = error.localizedDescription + "\n\n" + unchanged
        case .notVerified, .failed:
            alert.informativeText = error.localizedDescription + "\n\n" + unchanged
            alert.addButton(withTitle: String(localized: "重试"))
            actions.append(.retry)
        }
        alert.addButton(withTitle: String(localized: "查看帮助"))
        alert.addButton(withTitle: String(localized: "退出"))
        activateApp()
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if response < actions.count { return actions[response] }
        if response == actions.count {
            NSWorkspace.shared.open(readmeURL(section: (english: "if-goldenpassport-cant-read-its-data",
                                                        chinese: "goldenpassport-无法读取数据时")))
        }
        return .quit
    }

    /// For an unreadable data file, says that the file was left untouched and points to the recovery steps.
    private func showStartupFailure(_ error: Error, dataDirectory: URL) {
        let unreadable = error as? UnreadableDataFileError
        let alert = NSAlert()
        alert.alertStyle = .critical
        if let unreadable {
            alert.messageText = String(localized: "无法读取 \(unreadable.file.lastPathComponent)")
            alert.informativeText = String(localized: "GoldenPassport 没有改动这个文件。读不到账号时它不会启动，以免覆盖或漏掉你的数据。\n\n文件可能已损坏或被手动改过，恢复方法见帮助。")
                + "\n\n\(unreadable.file.path)\n\(unreadable.underlying.localizedDescription)"
        } else {
            alert.messageText = String(localized: "无法读取数据目录")
            alert.informativeText = "\(dataDirectory.path)\n\n\(error.localizedDescription)"
        }
        alert.addButton(withTitle: String(localized: "查看帮助"))
        alert.addButton(withTitle: String(localized: "在 Finder 中显示"))
        alert.addButton(withTitle: String(localized: "退出"))
        activateApp()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(readmeURL(section: (english: "if-goldenpassport-cant-read-its-data",
                                                        chinese: "goldenpassport-无法读取数据时")))
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([unreadable?.file ?? dataDirectory])
        default:
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.shutdown()
    }

    /// Accessory apps have no visible menu bar, but text fields still need the
    /// Edit menu's key equivalents for ⌘C / ⌘V / ⌘A / ⌘Z to work.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

/// The bundle id 0.1.x and 0.2.0 used (Info.plist GPLegacyBundleIdentifier, scripts/build-app.sh).
let legacyBundleIdentifier = (Bundle.main.object(forInfoDictionaryKey: "GPLegacyBundleIdentifier") as? String)
    .flatMap { $0.isEmpty ? nil : $0 }

/// The README on GitHub in the language the UI is using, optionally at one of its sections.
func readmeURL(section: (english: String, chinese: String)? = nil) -> URL {
    let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
    var components = URLComponents(string: chinese
        ? "https://github.com/thatscode/GoldenPassport/blob/modernize/README.zh-CN.md"
        : "https://github.com/thatscode/GoldenPassport/blob/modernize/README.md")!
    // URLComponents percent-encodes the fragment; URL(string:) only does that from macOS 14 on.
    components.fragment = section.map { chinese ? $0.chinese : $0.english }
    return components.url!
}

func activateApp() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}

func showAlert(_ message: String, informative: String? = nil, style: NSAlert.Style = .informational) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = message
    if let informative { alert.informativeText = informative }
    activateApp()
    alert.runModal()
}
