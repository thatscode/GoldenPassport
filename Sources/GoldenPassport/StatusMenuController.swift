import AppKit
import GoldenPassportCore
import ServiceManagement
import UniformTypeIdentifiers

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AccountStore
    private let settings: SettingsStore
    private let dataDirectory: URL
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
    private var languageChoiceItems: [NSMenuItem] = []
    private let legacyItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private let noticeSeparator = NSMenuItem.separator()
    private var automaticUpdatesItem: NSMenuItem!

    private var refreshTimer: Timer?
    private var deleteMode = false
    private var httpServer: LocalHTTPServer?

    private let appVersion: String
    private let updateChecker: UpdateChecker
    private var availableUpdate: AvailableUpdate?
    private var lastUpdateCheck: Date?
    private var updateTimer: Timer?
    /// Changes made in 0.1.x after the migration that the user hasn't dealt with yet (I6).
    private var legacyChanges: LegacyChanges?

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
    private lazy var legacyWindow = LegacyChangesWindowController(changes: { [weak self] in
        self?.legacyChanges
    }, onImport: { [weak self] names in
        self?.importLegacyChanges(names)
    }, onAcknowledge: { [weak self] in
        self?.acknowledgeLegacyChanges()
    })

    init(store: AccountStore, settings: SettingsStore, dataDirectory: URL, dataFormat: Int) {
        self.store = store
        self.settings = settings
        self.dataDirectory = dataDirectory
        hotkeys = HotkeyMonitor(store: store)
        let version = AppVersion(bundleInfo: Bundle.main.infoDictionary ?? [:]) ?? AppVersion("0")!
        appVersion = version.description
        updateChecker = UpdateChecker(currentVersion: version, dataFormat: dataFormat,
                                      fetch: UpdateChecker.networkFetch(appVersion: appVersion))
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
        scheduleUpdateChecks(firstCheckIn: 60)
        checkLegacyChanges()
    }

    func shutdown() {
        hotkeys.stop()
        httpServer?.stop()
    }

    // MARK: - Menu construction

    private func buildStaticItems() {
        // Shown at the very top while changes made in 0.1.x await the user, and once a check
        // finds a newer release.
        legacyItem.target = self
        legacyItem.action = #selector(legacyItemClicked)
        legacyItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        legacyItem.isHidden = true
        updateItem.target = self
        updateItem.action = #selector(updateItemClicked)
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateItem.isHidden = true
        noticeSeparator.isHidden = true
        menu.addItem(legacyItem)
        menu.addItem(updateItem)
        menu.addItem(noticeSeparator)

        timerItem.isEnabled = false
        menu.addItem(timerItem)
        menu.addItem(.separator())
        // Account items are inserted between the separator above and this header.

        menu.addItem(.separator())
        menu.addItem(sectionHeader(String(localized: "认证管理")))
        menu.addItem(item(String(localized: "添加…"), #selector(addClicked), key: "a"))
        menu.addItem(item(String(localized: "管理（排序 / 重命名）…"), #selector(manageClicked), key: "m"))
        deleteItem = add(item(String(localized: "删除"), #selector(deleteClicked), key: "d"))
        menu.addItem(item(String(localized: "导入…"), #selector(importClicked), key: "i"))
        let exportItem = add(NSMenuItem(title: String(localized: "导出"), action: nil, keyEquivalent: ""))
        let exportMenu = NSMenu()
        exportMenu.addItem(item(String(localized: "备份文件（.secrets，可导入新旧版本）…"), #selector(exportClicked), key: "e"))
        exportMenu.addItem(item(String(localized: "otpauth URL 列表（.txt，可导入其他验证器）…"), #selector(exportURLListClicked)))
        exportItem.submenu = exportMenu

        menu.addItem(.separator())
        menu.addItem(sectionHeader(String(localized: "HTTP 接口")))
        httpSwitchItem = add(item(String(localized: "开启 HTTP 服务"), #selector(httpSwitchClicked)))
        httpAutoStartItem = add(item(String(localized: "启动时同时开启 HTTP 服务"), #selector(httpAutoStartClicked)))
        httpURLItem = add(item("", #selector(httpURLClicked)))
        httpNoticeItem = add(NSMenuItem(title: String(localized: "⚠️ 运行中：本机任何程序都能读取验证码，不用时请关闭"), action: nil, keyEquivalent: ""))
        httpNoticeItem.isEnabled = false
        menu.addItem(item(String(localized: "修改端口…"), #selector(portClicked)))

        menu.addItem(.separator())
        hotkeysItem = add(NSMenuItem(title: String(localized: "全局快捷键（自动填入第 1–10 条）"), action: nil, keyEquivalent: ""))
        let hotkeyMenu = NSMenu()
        let off = item(String(localized: "关闭"), #selector(hotkeyChoiceClicked(_:)))
        hotkeyMenu.addItem(off)
        hotkeyMenu.addItem(.separator())
        hotkeyChoiceItems = [off]
        for modifiers in HotkeyModifiers.allCases {
            var title = "\(modifiers.symbols) + 0–9"
            if modifiers == .shiftCommand { title += String(localized: "（旧版方式；3/4/5 与系统截图冲突）") }
            let choice = item(title, #selector(hotkeyChoiceClicked(_:)))
            choice.representedObject = modifiers.rawValue
            hotkeyMenu.addItem(choice)
            hotkeyChoiceItems.append(choice)
        }
        hotkeysItem.submenu = hotkeyMenu
        launchAtLoginItem = add(item(String(localized: "开机自动启动"), #selector(launchAtLoginClicked)))
        // Bilingual title so the item can be found whatever language the menu is in.
        let languageItem = add(NSMenuItem(title: String(localized: "语言 / Language"), action: nil, keyEquivalent: ""))
        let languageMenu = NSMenu()
        languageChoiceItems = [("", String(localized: "跟随系统")), ("zh-Hans", "简体中文"), ("en", "English")].map { code, title in
            let choice = item(title, #selector(languageChoiceClicked(_:)))
            choice.representedObject = code
            languageMenu.addItem(choice)
            return choice
        }
        languageMenu.insertItem(.separator(), at: 1)
        languageItem.submenu = languageMenu

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "检查更新…"), #selector(checkForUpdatesClicked)))
        automaticUpdatesItem = add(item(String(localized: "每天自动检查更新"), #selector(automaticUpdatesClicked)))
        automaticUpdatesItem.toolTip = String(localized: "每天向 GitHub 查询一次最新版本。请求里只有 App 的版本号，不含账号信息。")
        menu.addItem(item(String(localized: "帮助"), #selector(helpClicked), key: "h"))
        menu.addItem(item(String(localized: "退出"), #selector(quitClicked), key: "q"))
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
            let empty = NSMenuItem(title: String(localized: "暂无记录，点击「添加…」"), action: nil, keyEquivalent: "")
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
        timerItem.title = String(localized: "\(remaining) 秒后过期")
        for (item, code) in zip(accountItems, codes) {
            item.title = "\(code.account.name): \(code.displayCode)"
        }
    }

    private func applyDeleteMode() {
        deleteItem.title = deleteMode ? String(localized: "完成删除") : String(localized: "删除")
        for item in accountItems where item.representedObject != nil {
            item.toolTip = deleteMode ? String(localized: "点击删除认证记录") : String(localized: "点击复制验证码")
            item.image = NSImage(systemSymbolName: deleteMode ? "trash" : "doc.on.doc", accessibilityDescription: nil)
        }
    }

    private func refreshHTTPItems() {
        let running = httpServer?.state == .running
        httpSwitchItem.title = running ? String(localized: "停止 HTTP 服务") : String(localized: "开启 HTTP 服务")
        httpAutoStartItem.state = settings.httpServerAutoStart ? .on : .off
        httpURLItem.title = String(localized: "浏览器访问 http://localhost:\(String(settings.httpServerPort))")
        httpURLItem.isHidden = !running
        httpNoticeItem.isHidden = !running
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let language = Self.languageOverride ?? ""
        for choice in languageChoiceItems {
            choice.state = (choice.representedObject as? String) == language ? .on : .off
        }
        for choice in hotkeyChoiceItems {
            let modifiers = (choice.representedObject as? String).flatMap(HotkeyModifiers.init(rawValue:))
            let selected = settings.hotkeysEnabled ? modifiers == settings.hotkeyModifiers : modifiers == nil
            choice.state = selected ? .on : .off
        }
    }

    private func refreshNoticeItems() {
        automaticUpdatesItem.state = settings.automaticUpdateChecks ? .on : .off
        legacyItem.isHidden = legacyChanges == nil
        if let legacyChanges {
            legacyItem.title = String(localized: "处理旧版本的改动（\(legacyChanges.imports.count + legacyChanges.removed.count)）…")
        }
        updateItem.isHidden = availableUpdate == nil
        if let availableUpdate {
            updateItem.title = String(localized: "新版本 \(availableUpdate.version) 可用…")
        }
        noticeSeparator.isHidden = legacyItem.isHidden && updateItem.isHidden
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refreshHTTPItems()
        refreshNoticeItems()
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
            alert.messageText = String(localized: "删除「\(account.name)」？")
            alert.informativeText = String(localized: "删除后无法恢复，建议先导出备份。")
            alert.addButton(withTitle: String(localized: "删除"))
            alert.addButton(withTitle: String(localized: "取消"))
            activateApp()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try store.remove(id: id)
            } catch {
                showAlert(String(localized: "删除失败"), informative: error.localizedDescription, style: .warning)
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
            showAlert(String(localized: "已进入删除模式"), informative: String(localized: "请到状态栏菜单中点击要删除的记录。\n完成后点击「完成删除」退出删除模式。"))
        }
    }

    @objc private func importClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "secrets") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "选择 .secrets 备份文件，或每行一个 otpauth:// URL 的文本文件")
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
                // One line and several lines are separate strings, so English gets the plural right.
                if parsed.invalidLines.count == 1 {
                    notes.append(String(localized: "第 \(parsed.invalidLines[0]) 行不是有效的 otpauth URL，已忽略。"))
                } else if !parsed.invalidLines.isEmpty {
                    let lines = parsed.invalidLines.map(String.init).joined(separator: String(localized: "、"))
                    notes.append(String(localized: "第 \(lines) 行不是有效的 otpauth URL，已忽略。"))
                }
            }
            let added = try store.importAccounts(entries)
            if added < entries.count {
                notes.insert(String(localized: "\(entries.count - added) 条因标识已存在而跳过。"), at: 0)
            }
            rebuildMenu()
            showAlert(String(localized: "成功导入 \(added) 条记录"), informative: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        } catch {
            showAlert(String(localized: "导入失败"), informative: error.localizedDescription, style: .warning)
        }
    }

    @objc private func exportClicked() {
        guard confirmPlaintextExport() else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "导出认证信息")
        panel.nameFieldStringValue = "GoldenPassport.secrets"
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dictionary = Dictionary(store.accounts.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
        do {
            try LegacyData.writeDictionary(dictionary, to: url)
        } catch {
            showAlert(String(localized: "导出失败"), informative: error.localizedDescription, style: .warning)
        }
    }

    /// Both export formats hold every secret unencrypted (.secrets is a binary plist).
    private func confirmPlaintextExport() -> Bool {
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = String(localized: "导出明文密钥？")
        warning.informativeText = String(localized: "文件中包含所有账号的 MFA 密钥，没有加密，任何拿到文件的人都能生成验证码。请勿通过聊天工具或邮件发送，也不要放进云同步目录，用完请删除。")
        warning.addButton(withTitle: String(localized: "继续导出"))
        warning.addButton(withTitle: String(localized: "取消"))
        activateApp()
        return warning.runModal() == .alertFirstButtonReturn
    }

    @objc private func exportURLListClicked() {
        guard confirmPlaintextExport() else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "导出 otpauth URL 列表")
        panel.nameFieldStringValue = "GoldenPassport-otpauth.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OTPAuthList.render(store.accounts).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            showAlert(String(localized: "导出失败"), informative: error.localizedDescription, style: .warning)
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
            showAlert(String(localized: "设置开机启动失败"), informative: error.localizedDescription, style: .warning)
        }
        if service.status == .requiresApproval {
            showAlert(String(localized: "需要在系统设置中允许"), informative: String(localized: "请在 系统设置 → 通用 → 登录项 中允许本 App。"))
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
        alert.messageText = String(localized: "HTTP 服务已开启")
        alert.informativeText = String(localized: """
            现在可以通过 http://localhost:\(String(settings.httpServerPort)) 获取验证码。

            • 服务只监听本机，局域网和外网无法访问。
            • 但没有访问密码：这台 Mac 上以你的身份运行的任何程序（脚本、命令行工具、浏览器扩展等）都能读取全部验证码。
            • 不用时建议关闭；如果不需要，也可以取消「启动时同时开启 HTTP 服务」。
            """)
        alert.addButton(withTitle: String(localized: "知道了"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "不再提示")
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
                showAlert(String(localized: "需要「辅助功能」权限才能自动填入"),
                          informative: String(localized: "请在系统设置中允许本 App 控制电脑。未授权前，按快捷键只会把验证码复制到剪贴板。"))
            }
        } else {
            settings.hotkeysEnabled = false
        }
        applyHotkeySettings()
        if settings.hotkeysEnabled, !hotkeys.failedDigits.isEmpty {
            let keys = hotkeys.failedDigits.map { "\(settings.hotkeyModifiers.symbols)\($0)" }.joined(separator: String(localized: "、"))
            showAlert(String(localized: "部分快捷键注册失败"), informative: String(localized: "\(keys) 已被其他程序占用，可换一组修饰键。"))
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
        NSWorkspace.shared.open(readmeURL())
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    /// The per-app language, stored as AppleLanguages in the app's own defaults domain:
    /// the same setting System Settings → Language & Region → Applications writes.
    private static var languageOverride: String? {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first
            .map { $0.hasPrefix("zh") ? "zh-Hans" : "en" }
    }

    @objc private func languageChoiceClicked(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String ?? ""
        guard code != (Self.languageOverride ?? "") else { return }
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "重新启动 GoldenPassport 后生效")
        alert.addButton(withTitle: String(localized: "立即重启"))
        alert.addButton(withTitle: String(localized: "稍后"))
        activateApp()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Start the new instance only after this one has quit, so the global hotkeys
        // and the HTTP port are free again.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: - Updates

    /// Ticks hourly and checks once the last successful check is about a day old, so a check
    /// that failed (say, offline right after login) is retried an hour later.
    private func scheduleUpdateChecks(firstCheckIn delay: TimeInterval) {
        updateTimer?.invalidate()
        updateTimer = nil
        guard settings.automaticUpdateChecks else { return }
        let timer = Timer(fireAt: Date().addingTimeInterval(delay), interval: 3600, target: self,
                          selector: #selector(updateTimerFired), userInfo: nil, repeats: true)
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    @objc private func updateTimerFired() {
        if let lastUpdateCheck, Date().timeIntervalSince(lastUpdateCheck) < 23 * 3600 { return }
        Task { @MainActor in await self.checkForUpdates(userInitiated: false) }
    }

    @objc private func checkForUpdatesClicked() {
        Task { @MainActor in await self.checkForUpdates(userInitiated: true) }
    }

    @objc private func automaticUpdatesClicked() {
        settings.automaticUpdateChecks.toggle()
        scheduleUpdateChecks(firstCheckIn: 0)
    }

    @objc private func updateItemClicked() {
        if let availableUpdate { presentUpdate(availableUpdate) }
    }

    /// Automatic checks stay quiet: a newer release only shows up as an item at the top of the menu.
    @MainActor
    private func checkForUpdates(userInitiated: Bool) async {
        do {
            let result = try await updateChecker.check()
            lastUpdateCheck = Date()
            switch result {
            case .upToDate:
                availableUpdate = nil
                if userInitiated {
                    showAlert(String(localized: "已是最新版本"),
                              informative: String(localized: "GoldenPassport \(appVersion) 是目前最新的版本。"))
                }
            case .available(let update):
                availableUpdate = update
                if userInitiated { presentUpdate(update) }
            }
        } catch {
            if userInitiated {
                showAlert(String(localized: "检查更新失败"), informative: error.localizedDescription, style: .warning)
            }
        }
    }

    /// Only points to the release page: installing goes through install.sh, which backs up first.
    private func presentUpdate(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = String(localized: "GoldenPassport \(update.version) 已发布")
        var paragraphs = [String(localized: "你现在使用的是 \(appVersion)。")]
        var page = update.releasePage
        var pageButton = String(localized: "查看发布页面")
        for notice in update.notices {
            switch notice {
            case .dataFormatChange:
                alert.alertStyle = .warning
                paragraphs.append(String(localized: "⚠️ 这个版本会把账号数据转换为新格式，升级后在新版本里所做的修改，旧版本看不到。请先导出备份，再用安装包里的 install.sh 安装，它会先备份数据。"))
            case .upgradeFirst(let version, let releasePage):
                alert.alertStyle = .warning
                paragraphs.append(String(localized: "⚠️ 不能从当前版本直接升级到 \(update.version)，请先升级到 \(version)。"))
                page = releasePage
                pageButton = String(localized: "查看 \(version) 的发布页面")
            case .compatibilityUnknown:
                paragraphs.append(String(localized: "无法确认这个版本的兼容性，升级前请先阅读发布说明。"))
            }
        }
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: pageButton)
        alert.addButton(withTitle: String(localized: "稍后"))
        activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: - Changes made in 0.1.x (I6)

    /// After rollback.sh, accounts may have been added or changed in 0.1.x, which 0.2.x never
    /// picks up on its own. The window opens at launch; "later" leaves an item in the menu.
    private func checkLegacyChanges() {
        guard let changes = LegacyChanges.detect(in: dataDirectory, accounts: store.accounts) else { return }
        if changes.isEmpty {
            // gp.secrets changed, but this version already has everything worth asking about.
            try? changes.acknowledge(in: dataDirectory)
        } else {
            legacyChanges = changes
            DispatchQueue.main.async { self.legacyWindow.present() }
        }
    }

    @objc private func legacyItemClicked() {
        legacyWindow.present()
    }

    private func importLegacyChanges(_ names: Set<String>) {
        guard let changes = legacyChanges else { return }
        do {
            let added = try changes.importAccounts(named: names, into: store, directory: dataDirectory)
            legacyChanges = nil
            rebuildMenu()
            showAlert(String(localized: "成功导入 \(added) 条记录"))
        } catch {
            rebuildMenu()
            showAlert(String(localized: "导入失败"), informative: error.localizedDescription, style: .warning)
        }
    }

    private func acknowledgeLegacyChanges() {
        guard let changes = legacyChanges else { return }
        do {
            try changes.acknowledge(in: dataDirectory)
            legacyChanges = nil
        } catch {
            showAlert(String(localized: "出错了"), informative: error.localizedDescription, style: .warning)
        }
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
                showAlert(String(localized: "HTTP 服务启动失败"), informative: message, style: .warning)
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
