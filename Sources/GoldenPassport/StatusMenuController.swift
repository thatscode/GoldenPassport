import AppKit
import GoldenPassportCore
import UniformTypeIdentifiers

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AccountStore
    private let settings: SettingsStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let hotkeys: HotkeyMonitor

    private let timerItem = NSMenuItem()
    private var accountItems: [NSMenuItem] = []
    private var deleteItem: NSMenuItem!
    private var httpSwitchItem: NSMenuItem!
    private var httpAutoStartItem: NSMenuItem!
    private var httpURLItem: NSMenuItem!
    private var hotkeysItem: NSMenuItem!

    private var refreshTimer: Timer?
    private var deleteMode = false
    private var httpServer: LocalHTTPServer?

    private lazy var addWindow = AddAccountWindowController(store: store) { [weak self] in
        self?.rebuildMenu()
    }
    private lazy var portWindow = PortConfigWindowController(currentPort: { [weak self] in
        self?.settings.httpServerPort ?? 0
    }) { [weak self] port in
        self?.changeHTTPPort(port)
    }

    init(store: AccountStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        hotkeys = HotkeyMonitor(store: store)
        super.init()

        if let button = statusItem.button {
            let icon = NSImage(named: "statusIcon") ?? NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
            icon?.size = NSSize(width: 20, height: 20)
            icon?.isTemplate = true
            // Menu bar managers (e.g. Bartender's search) and VoiceOver identify the item by this label.
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "GoldenPassport"
            icon?.accessibilityDescription = appName
            button.image = icon
            button.setAccessibilityTitle(appName)
            button.toolTip = appName
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        buildStaticItems()
        rebuildMenu()

        if settings.httpServerAutoStart { startHTTPServer() }
        if settings.hotkeysEnabled { hotkeys.start(promptForPermission: false) }
    }

    func shutdown() {
        hotkeys.stop()
        httpServer?.stop()
    }

    // MARK: - Menu construction

    private func buildStaticItems() {
        timerItem.isEnabled = false
        menu.addItem(timerItem)
        menu.addItem(.separator())
        // Account items are inserted between the separator above and this header.

        menu.addItem(.separator())
        menu.addItem(sectionHeader("认证管理"))
        menu.addItem(item("添加...", #selector(addClicked), key: "a"))
        deleteItem = add(item("删除", #selector(deleteClicked), key: "d"))
        menu.addItem(item("导入...", #selector(importClicked), key: "i"))
        menu.addItem(item("导出...", #selector(exportClicked), key: "e"))

        menu.addItem(.separator())
        menu.addItem(sectionHeader("HTTP 接口"))
        httpSwitchItem = add(item("开启 HTTP 服务", #selector(httpSwitchClicked)))
        httpAutoStartItem = add(item("启动时同时开启 HTTP 服务", #selector(httpAutoStartClicked)))
        httpURLItem = add(item("", #selector(httpURLClicked)))
        menu.addItem(item("修改端口...", #selector(portClicked)))

        menu.addItem(.separator())
        hotkeysItem = add(item("全局快捷键 ⇧⌘0–9 自动填入", #selector(hotkeysClicked)))
        menu.addItem(item("帮助", #selector(helpClicked), key: "h"))
        menu.addItem(item("退出", #selector(quitClicked), key: "q"))
    }

    private func add(_ item: NSMenuItem) -> NSMenuItem {
        menu.addItem(item)
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuildMenu() {
        accountItems.forEach { menu.removeItem($0) }
        accountItems = []

        let codes = store.codes()
        let insertAt = menu.index(of: timerItem) + 2
        for (index, code) in codes.enumerated() {
            let item = NSMenuItem(title: "", action: #selector(accountClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code.account.id
            if index < 10 {
                item.keyEquivalent = "\(index)"
                item.keyEquivalentModifierMask = [.command, .shift]
            }
            menu.insertItem(item, at: insertAt + index)
            accountItems.append(item)
        }
        if codes.isEmpty {
            let empty = NSMenuItem(title: "暂无记录，点击「添加...」", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.insertItem(empty, at: insertAt)
            accountItems.append(empty)
        }
        applyDeleteMode()
        refreshCodes()
    }

    @objc private func refreshCodes() {
        let codes = store.codes()
        let remaining = codes.compactMap(\.secondsRemaining).first ?? TOTP(secret: Data([0])).secondsRemaining()
        timerItem.title = "过期时间: \(remaining)s"
        for (item, code) in zip(accountItems, codes) {
            item.title = "\(code.account.name): \(code.displayCode)"
        }
    }

    private func applyDeleteMode() {
        deleteItem.title = deleteMode ? "完成删除" : "删除"
        for item in accountItems where item.representedObject != nil {
            item.toolTip = deleteMode ? "点击删除认证记录" : "点击复制验证码"
            item.image = NSImage(systemSymbolName: deleteMode ? "trash" : "doc.on.doc", accessibilityDescription: nil)
        }
    }

    private func refreshHTTPItems() {
        let running = httpServer?.state == .running
        httpSwitchItem.title = running ? "停止 HTTP 服务" : "开启 HTTP 服务"
        httpAutoStartItem.state = settings.httpServerAutoStart ? .on : .off
        httpURLItem.title = "浏览器访问 http://localhost:\(settings.httpServerPort)"
        httpURLItem.isHidden = !running
        hotkeysItem.state = settings.hotkeysEnabled ? .on : .off
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refreshHTTPItems()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(refreshCodes), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    @objc private func accountClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let account = store.accounts.first(where: { $0.id == id }) else { return }
        if deleteMode {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "删除「\(account.name)」？"
            alert.informativeText = "删除后无法恢复，建议先导出备份。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            activateApp()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try store.remove(id: id)
            } catch {
                showAlert("删除失败", informative: error.localizedDescription, style: .warning)
            }
            rebuildMenu()
        } else {
            let code = AccountStore.code(for: account, at: Date())
            guard case .success(let value) = code.result else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    @objc private func addClicked() {
        addWindow.present()
    }

    @objc private func deleteClicked() {
        deleteMode.toggle()
        applyDeleteMode()
        if deleteMode {
            showAlert("已进入删除模式", informative: "请到状态栏菜单中点击要删除的记录。\n完成后点击「完成删除」退出删除模式。")
        }
    }

    @objc private func importClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "secrets") ?? .data]
        panel.allowsMultipleSelection = false
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let legacy = try LegacyData.readDictionary(at: url)
            let entries = LegacyData.accounts(from: legacy).map { (name: $0.name, url: $0.url) }
            let added = try store.importAccounts(entries)
            rebuildMenu()
            showAlert("成功导入 \(added) 条记录", informative: added < entries.count ? "\(entries.count - added) 条因标识已存在而跳过。" : nil)
        } catch {
            showAlert("导入失败", informative: error.localizedDescription, style: .warning)
        }
    }

    @objc private func exportClicked() {
        let panel = NSSavePanel()
        panel.title = "导出认证信息"
        panel.nameFieldStringValue = "GoldenPassport.secrets"
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dictionary = Dictionary(store.accounts.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
        do {
            try LegacyData.writeDictionary(dictionary, to: url)
        } catch {
            showAlert("导出失败", informative: error.localizedDescription, style: .warning)
        }
    }

    @objc private func httpSwitchClicked() {
        if httpServer?.state == .running {
            stopHTTPServer()
        } else {
            startHTTPServer()
        }
    }

    @objc private func httpAutoStartClicked() {
        settings.httpServerAutoStart.toggle()
    }

    @objc private func httpURLClicked() {
        if let url = URL(string: "http://localhost:\(settings.httpServerPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func portClicked() {
        portWindow.present()
    }

    @objc private func hotkeysClicked() {
        settings.hotkeysEnabled.toggle()
        if settings.hotkeysEnabled {
            hotkeys.start(promptForPermission: true)
        } else {
            hotkeys.stop()
        }
    }

    @objc private func helpClicked() {
        if let url = URL(string: "https://github.com/stanzhai/GoldenPassport") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - HTTP server

    private func startHTTPServer() {
        stopHTTPServer()
        let store = self.store
        let server = LocalHTTPServer(port: UInt16(clamping: settings.httpServerPort)) { request in
            CodeAPI.handle(request, store: store)
        }
        server.onStateChange = { state in
            if case .failed(let message) = state {
                showAlert("HTTP 服务启动失败", informative: message, style: .warning)
            }
        }
        httpServer = server
        server.start()
    }

    private func stopHTTPServer() {
        httpServer?.onStateChange = nil
        httpServer?.stop()
        httpServer = nil
    }

    private func changeHTTPPort(_ port: Int) {
        guard port != settings.httpServerPort else { return }
        settings.httpServerPort = port
        if httpServer != nil { startHTTPServer() }
    }
}
