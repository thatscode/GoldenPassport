import AppKit
import GoldenPassportCore

/// The update dialog and, when section 3 of docs/design/in-app-update.md allows it, downloading,
/// checking and installing the release, then handing over to the new copy.
final class UpdateController {
    private let appVersion: String
    private let hasOpenWindows: () -> Bool
    private let onBusyChange: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var panel: UpdateProgressPanel?

    init(appVersion: String, hasOpenWindows: @escaping () -> Bool, onBusyChange: @escaping (Bool) -> Void) {
        self.appVersion = appVersion
        self.hasOpenWindows = hasOpenWindows
        self.onBusyChange = onBusyChange
    }

    // MARK: - Dialog

    func present(_ update: AvailableUpdate) {
        let app = RunningApp.inspect(bundleURL: Bundle.main.bundleURL, teamIdentifier: CodeSignature.teamIdentifierOfRunningApp())
        let action = update.action(for: app)

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
        if case .releasePageOnly(let blocker) = action, let explanation = Self.explanation(of: blocker) {
            paragraphs.append(explanation)
        }
        alert.informativeText = paragraphs.joined(separator: "\n\n")

        var package: UpdatePackage?
        if case .install(let offered) = action {
            package = offered
            alert.addButton(withTitle: String(localized: "下载并安装"))
        }
        alert.addButton(withTitle: pageButton)
        alert.addButton(withTitle: String(localized: "稍后"))
        activateApp()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if let package, index == 0 {
            install(update, package: package, target: app.bundleURL)
        } else if index == (package == nil ? 0 : 1) {
            NSWorkspace.shared.open(page)
        }
    }

    private static func explanation(of blocker: InstallBlocker) -> String? {
        switch blocker {
        case .releaseNeedsInstaller:
            return String(localized: "这个版本不能在 App 里直接安装，请用安装包里的 install.sh 安装，它会先备份。")
        case .noPackage:
            return nil
        case .notReleaseBuild:
            return String(localized: "这一份不是正式发布的版本，不能自动更新。")
        case .translocated:
            return String(localized: "GoldenPassport 现在的位置不能直接替换。请把它移到「应用程序」文件夹，或者用安装包里的 install.sh 安装。")
        case .notWritable(let path):
            return String(localized: "当前账号不能修改 \(path)，请用管理员账号运行 install.sh。")
        }
    }

    // MARK: - Installing

    private func install(_ update: AvailableUpdate, package: UpdatePackage, target: URL) {
        guard !hasOpenWindows() else {
            showAlert(String(localized: "请先关闭 GoldenPassport 打开的窗口，再安装更新。"))
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let team = CodeSignature.teamIdentifierOfRunningApp(),
              let version = AppVersion(update.version),
              let current = AppVersion(bundleInfo: info) else { return }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let keychainService = (info["GPKeychainService"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expectations = UpdatePackageCheck.Expectations(
            bundleIdentifier: bundleIdentifier, version: version, current: current,
            dataDirectoryName: info["GPDataDirectoryName"] as? String, keychainService: keychainService,
            systemVersion: AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)") ?? current,
            architecture: UpdatePackageCheck.currentArchitecture)
        let requirement = UpdatePackageCheck.requirement(bundleIdentifier: bundleIdentifier, teamIdentifier: team)
        let expectedStorage = keychainService == nil ? "file" : "keychain"
        let hasOpenWindows = self.hasOpenWindows
        let operations = FileSystemInstallOperations(
            verify: { app in
                try CodeSignature.verify(bundleAt: app, requirement: requirement)
                // Not Bundle(url:): it caches by path, and a second attempt would read the first one's plist.
                let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
                let executable = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
                    .appendingPathComponent(plist["CFBundleExecutable"] as? String ?? "")
                try UpdatePackageCheck.checkInfo(plist, architectures: UpdatePackageCheck.architectures(ofExecutableAt: executable),
                                                 expectations: expectations)
            },
            checkData: { app in try DataCheck.run(app: app, expectedStorage: expectedStorage) },
            readyToQuit: {
                if DispatchQueue.main.sync(execute: hasOpenWindows) { throw UpdateError.windowsOpen }
            },
            launch: Self.launch)
        // Background callbacks reach this controller only on the main thread, through a weak reference.
        let controller = MainThreadReference(self)
        let installer = UpdateInstaller(
            target: target, launchArguments: UpdateLaunchArguments(oldProcessID: getpid(), updatedFrom: appVersion),
            operations: operations,
            progress: { step in DispatchQueue.main.async { controller.value?.show(step) } })

        onBusyChange(true)
        let panel = UpdateProgressPanel { [weak self] in self?.task?.cancel() }
        self.panel = panel
        panel.show(String(localized: "正在下载 \(update.version)…"), cancellable: true)

        task = Task {
            do {
                let directory = try UpdateDownloader.prepareDirectory(bundleIdentifier: bundleIdentifier, version: update.version)
                let zip = try await UpdateDownloader(appVersion: current.description).download(package, into: directory) { received, expected in
                    DispatchQueue.main.async { controller.value?.panel?.showDownloaded(received, of: expected ?? package.size.map(Int64.init)) }
                }
                try Task.checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    try UpdatePackageCheck.verifyDownload(at: zip, package: package)
                    let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
                    try Ditto.unzip(zip, into: unpacked)
                    try installer.install(from: UpdatePackageCheck.findApp(inUnpacked: unpacked, version: version))
                }.value
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run { controller.value?.finish(after: error, bundleIdentifier: bundleIdentifier, releasePage: update.releasePage) }
            }
        }
    }

    private func show(_ step: InstallStep) {
        switch step {
        case .stage, .verify: panel?.show(String(localized: "正在校验…"), cancellable: false)
        case .checkData: panel?.show(String(localized: "正在核对数据（可能会请求访问钥匙串）…"), cancellable: false)
        case .trashOld, .moveNew, .launch: panel?.show(String(localized: "正在安装…"), cancellable: false)
        }
    }

    /// Cleans up after a failed or cancelled attempt and, unless the user cancelled, says what happened.
    private func finish(after error: Error, bundleIdentifier: String, releasePage: URL) {
        UpdateDownloader.clearCache(bundleIdentifier: bundleIdentifier)
        panel?.close()
        panel = nil
        task = nil
        onBusyChange(false)
        if error is CancellationError { return }

        let failure = error as? InstallFailure
        let cause = failure?.underlying ?? error
        var paragraphs = [cause.localizedDescription]
        if let failure, !failure.restored, let previous = failure.previousAppInTrash {
            paragraphs.append(String(localized: "旧版本在废纸篓里：\(previous.path)。可以把它拖回原来的位置。"))
        } else {
            paragraphs.append(String(localized: "GoldenPassport 没有做任何改动，你仍在使用 \(appVersion)。"))
        }
        if (cause as? UpdateError)?.isNetworkProblem == true {
            paragraphs.append(String(localized: "可以在发布页面用浏览器下载，然后运行 install.sh 安装。"))
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "更新没有完成")
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "查看发布页面"))
        alert.addButton(withTitle: String(localized: "好"))
        activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasePage)
        }
    }

    /// Opens the new copy as a second instance (the old one still runs) and waits for the answer.
    private static func launch(_ app: URL, arguments: [String]) throws {
        let done = DispatchSemaphore(value: 0)
        let outcome = LaunchOutcome()
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                outcome.error = error
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + 30) == .success else { throw UpdateError.launchFailed("timeout") }
        if let error = outcome.error { throw UpdateError.launchFailed(error.localizedDescription) }
    }

    // MARK: - After relaunching

    /// Shown once by the new copy (`--updated-from`), so the user sees the update went through. If
    /// hotkeys are on but the Accessibility permission didn't carry over, says so (design 5.5).
    static func showUpdatedNotice(version: String, hotkeysEnabled: Bool) {
        let alert = NSAlert()
        alert.messageText = String(localized: "已更新到 GoldenPassport \(version)")
        let needsAccessibility = hotkeysEnabled && !AXIsProcessTrusted()
        if needsAccessibility {
            alert.informativeText = String(localized: "快捷键现在只能复制验证码：自动填入需要「辅助功能」授权，更新后可能需要重新授权。")
        }
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "查看更新内容"))
        if needsAccessibility { alert.addButton(withTitle: String(localized: "打开辅助功能设置")) }
        activateApp()
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/thatscode/GoldenPassport/releases/tag/v\(version)")!)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        default:
            break
        }
    }
}

/// A weak reference handed to background work and dereferenced only on the main thread.
private final class MainThreadReference<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}

/// Written by the completion handler before the semaphore is signalled, read after the wait.
private final class LaunchOutcome: @unchecked Sendable {
    var error: Error?
}

/// A small floating window with a status line, a progress bar and a Cancel button that works only
/// while downloading. It has no close button: the update runs to the end or fails on its own.
final class UpdateProgressPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: String(localized: "取消"), target: nil, action: nil)
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init()
        panel.title = String(localized: "正在更新 GoldenPassport")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // Panels hide when their app is inactive, which a menu bar app nearly always is: the
        // progress and the Cancel button would be gone as soon as the user clicks elsewhere.
        panel.hidesOnDeactivate = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        detail.textColor = .secondaryLabelColor
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let buttons = NSStackView(views: [NSView(), cancelButton])
        let stack = NSStackView(views: [label, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            content.widthAnchor.constraint(equalToConstant: 380),
        ])
        panel.contentView = content
    }

    func show(_ status: String, cancellable: Bool) {
        label.stringValue = status
        cancelButton.isEnabled = cancellable
        if !cancellable {
            detail.stringValue = ""
            bar.isIndeterminate = true
        }
        bar.startAnimation(nil)
        if !panel.isVisible {
            panel.center()
            activateApp()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func showDownloaded(_ received: Int64, of expected: Int64?) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let expected, expected > 0 {
            bar.isIndeterminate = false
            bar.doubleValue = min(1, Double(received) / Double(expected))
            detail.stringValue = formatter.string(fromByteCount: received) + " / " + formatter.string(fromByteCount: expected)
        } else {
            detail.stringValue = formatter.string(fromByteCount: received)
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    @objc private func cancelClicked() {
        cancelButton.isEnabled = false
        onCancel()
    }
}
