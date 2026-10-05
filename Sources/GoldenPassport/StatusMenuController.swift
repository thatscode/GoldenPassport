import AppKit
import GoldenPassportCore
import ServiceManagement
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
    private var httpNoticeItem: NSMenuItem!
    private var hotkeysItem: NSMenuItem!
    private var hotkeyChoiceItems: [NSMenuItem] = []
    private var launchAtLoginItem: NSMenuItem!

    private var refreshTimer: Timer?
    private var deleteMode = false
    private var httpServer: LocalHTTPServer?

    private lazy var addWindow = AddAccountWindowController(store: store) { [weak self] in
        self?.rebuildMenu()
    }
    private lazy var manageWindow = ManageAccountsWindowController(store: store, hotkeyLabel: { [weak self] index in
        self?.hotkeyLabel(forAccountAt: index)
    }) { [weak self] in
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
        applyHotkeySettings()
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
        menu.addItem(item("管理（排序 / 重命名）...", #selector(manageClicked), key: "m"))
        deleteItem = add(item("删除", #selector(deleteClicked), key: "d"))
        menu.addItem(item("导入...", #selector(importClicked), key: "i"))
        let exportItem = add(NSMenuItem(title: "导出", action: nil, keyEquivalent: ""))
        let exportMenu = NSMenu()
        exportMenu.addItem(item("备份文件（.secrets，可导入新旧版本）...", #selector(exportClicked), key: "e"))
        exportMenu.addItem(item("otpauth URL 列表（.txt，可导入其他验证器）...", #selector(exportURLListClicked)))
        exportItem.submenu = exportMenu

        menu.addItem(.separator())
        menu.addItem(sectionHeader("HTTP 接口"))
        httpSwitchItem = add(item("开启 HTTP 服务", #selector(httpSwitchClicked)))
        httpAutoStartItem = add(item("启动时同时开启 HTTP 服务", #selector(httpAutoStartClicked)))
        httpURLItem = add(item("", #selector(httpURLClicked)))
        httpNoticeItem = add(NSMenuItem(title: "⚠️ 运行中：本机任何程序都能读取验证码，不用时请关闭", action: nil, keyEquivalent: ""))
        httpNoticeItem.isEnabled = false
        menu.addItem(item("修改端口...", #selector(portClicked)))

        menu.addItem(.separator())
        hotkeysItem = add(NSMenuItem(title: "全局快捷键（自动填入第 1–10 条）", action: nil, keyEquivalent: ""))
        let hotkeyMenu = NSMenu()
        let off = item("关闭", #selector(hotkeyChoiceClicked(_:)))
        hotkeyMenu.addItem(off)
        hotkeyMenu.addItem(.separator())
        hotkeyChoiceItems = [off]
        for modifiers in HotkeyModifiers.allCases {
            var title = "\(modifiers.symbols) + 0–9"
            if modifiers == .shiftCommand { title += "（旧版方式；3/4/5 与系统截图冲突）" }
            let choice = item(title, #selector(hotkeyChoiceClicked(_:)))
            choice.representedObject = modifiers.rawValue
            hotkeyMenu.addItem(choice)
            hotkeyChoiceItems.append(choice)
        }
        hotkeysItem.submenu = hotkeyMenu
        launchAtLoginItem = add(item("开机自动启动", #selector(launchAtLoginClicked)))
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
            if settings.hotkeysEnabled, let digit = HotkeyModifiers.digit(forAccountAt: index) {
                item.keyEquivalent = "\(digit)"
                item.keyEquivalentModifierMask = HotkeyMonitor.keyEquivalentModifierMask(settings.hotkeyModifiers)
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
        httpNoticeItem.isHidden = !running
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for choice in hotkeyChoiceItems {
            let modifiers = (choice.representedObject as? String).flatMap(HotkeyModifiers.init(rawValue:))
            let selected = settings.hotkeysEnabled ? modifiers == settings.hotkeyModifiers : modifiers == nil
            choice.state = selected ? .on : .off
        }
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

    @objc private func manageClicked() {
        manageWindow.present()
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
        panel.allowedContentTypes = [UTType(filenameExtension: "secrets") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "选择 .secrets 备份文件，或每行一个 otpauth:// URL 的文本文件"
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries: [(name: String, url: String)]
            var notes: [String] = []
            if url.pathExtension.lowercased() == "secrets" {
                let legacy = try LegacyData.readDictionary(at: url)
                entries = LegacyData.accounts(from: legacy).map { (name: $0.name, url: $0.url) }
            } else {
                let parsed = OTPAuthList.parse(try String(contentsOf: url, encoding: .utf8))
                entries = parsed.entries
                if !parsed.invalidLines.isEmpty {
                    notes.append("第 \(parsed.invalidLines.map(String.init).joined(separator: "、")) 行不是有效的 otpauth URL，已忽略。")
                }
            }
            let added = try store.importAccounts(entries)
            if added < entries.count {
                notes.insert("\(entries.count - added) 条因标识已存在而跳过。", at: 0)
            }
            rebuildMenu()
            showAlert("成功导入 \(added) 条记录", informative: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        } catch {
            showAlert("导入失败", informative: error.localizedDescription, style: .warning)
        }
    }

    @objc private func exportClicked() {
        guard confirmPlaintextExport() else { return }
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

    /// Both export formats hold every secret unencrypted (.secrets is a binary plist).
    private func confirmPlaintextExport() -> Bool {
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "导出明文密钥？"
        warning.informativeText = "文件中包含所有账号的 MFA 密钥，没有加密，任何拿到文件的人都能生成验证码。请勿通过聊天工具或邮件发送，也不要放进云同步目录，用完请删除。"
        warning.addButton(withTitle: "继续导出")
        warning.addButton(withTitle: "取消")
        activateApp()
        return warning.runModal() == .alertFirstButtonReturn
    }

    @objc private func exportURLListClicked() {
        guard confirmPlaintextExport() else { return }
        let panel = NSSavePanel()
        panel.title = "导出 otpauth URL 列表"
        panel.nameFieldStringValue = "GoldenPassport-otpauth.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OTPAuthList.render(store.accounts).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            showAlert("导出失败", informative: error.localizedDescription, style: .warning)
        }
    }

    @objc private func launchAtLoginClicked() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert("设置开机启动失败", informative: error.localizedDescription, style: .warning)
        }
        if service.status == .requiresApproval {
            showAlert("需要在系统设置中允许", informative: "请在 系统设置 → 通用 → 登录项 中允许本 App。")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func httpSwitchClicked() {
        if httpServer?.state == .running {
            stopHTTPServer()
        } else {
            startHTTPServer()
            showHTTPNoticeIfNeeded()
        }
    }

    /// The API has no authentication: anything running as this user can read every code.
    private func showHTTPNoticeIfNeeded() {
        guard !settings.httpNoticeSuppressed else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "HTTP 服务已开启"
        alert.informativeText = """
            现在可以通过 http://localhost:\(settings.httpServerPort) 获取验证码。

            • 服务只监听本机，局域网和外网无法访问。
            • 但没有访问密码：这台 Mac 上以你的身份运行的任何程序（脚本、命令行工具、浏览器扩展等）都能读取全部验证码。
            • 不用时建议关闭；如果不需要，也可以取消「启动时同时开启 HTTP 服务」。
            """
        alert.addButton(withTitle: "知道了")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示"
        activateApp()
        alert.runModal()
        if alert.suppressionButton?.state == .on {
            settings.httpNoticeSuppressed = true
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

    @objc private func hotkeyChoiceClicked(_ sender: NSMenuItem) {
        if let modifiers = (sender.representedObject as? String).flatMap(HotkeyModifiers.init(rawValue:)) {
            settings.hotkeyModifiers = modifiers
            settings.hotkeysEnabled = true
            if !HotkeyMonitor.requestAccessibilityIfNeeded() {
                showAlert("需要「辅助功能」权限才能自动填入",
                          informative: "请在系统设置中允许本 App 控制电脑。未授权前，按快捷键只会把验证码复制到剪贴板。")
            }
        } else {
            settings.hotkeysEnabled = false
        }
        applyHotkeySettings()
        if settings.hotkeysEnabled, !hotkeys.failedDigits.isEmpty {
            let keys = hotkeys.failedDigits.map { "\(settings.hotkeyModifiers.symbols)\($0)" }.joined(separator: "、")
            showAlert("部分快捷键注册失败", informative: "\(keys) 已被其他程序占用，可换一组修饰键。")
        }
    }

    private func applyHotkeySettings() {
        if settings.hotkeysEnabled {
            hotkeys.start(modifiers: settings.hotkeyModifiers)
        } else {
            hotkeys.stop()
        }
    }

    private func hotkeyLabel(forAccountAt index: Int) -> String? {
        guard settings.hotkeysEnabled, let digit = HotkeyModifiers.digit(forAccountAt: index) else { return nil }
        return "\(settings.hotkeyModifiers.symbols)\(digit)"
    }

    @objc private func helpClicked() {
        if let url = URL(string: "https://github.com/thatscode/GoldenPassport") {
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
