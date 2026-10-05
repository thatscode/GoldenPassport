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
        do {
            try environment.prepareDataDirectory()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "无法读取数据目录")
            alert.informativeText = "\(environment.dataDirectory.path)\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        statusMenuController = StatusMenuController(
            store: AccountStore(directory: environment.dataDirectory),
            settings: SettingsStore(directory: environment.dataDirectory, defaults: environment.defaults))
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
