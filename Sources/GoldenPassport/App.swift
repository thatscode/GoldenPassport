import AppKit
import GoldenPassportCore

@main
enum GoldenPassportApp {
    static func main() {
        if CommandLine.arguments.contains("--migrate-data") {
            exit(runMigrateData(Array(CommandLine.arguments.dropFirst())))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let environment = AppEnvironment.fromBundle()
        let store: AccountStore
        do {
            try environment.prepareDataDirectory()
            store = try environment.openAccountStore()
        } catch {
            showStartupFailure(error, dataDirectory: environment.dataDirectory)
            NSApp.terminate(nil)
            return
        }
        statusMenuController = StatusMenuController(
            store: store,
            settings: SettingsStore(directory: environment.dataDirectory, defaults: environment.defaults),
            dataDirectory: environment.dataDirectory,
            dataFormat: environment.dataFormat)
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
