import AppKit
import GoldenPassportCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

/// "Import from Another Authenticator…": QR code images and pasted links into a preview, then into
/// the account list (docs/design/authenticator-import.md).
final class AuthenticatorImportWindowController: HostedWindowController {
    private let store: AccountStore
    private let onImported: () -> Void
    private var model: AuthenticatorImportModel?

    init(store: AccountStore, onImported: @escaping () -> Void) {
        self.store = store
        self.onImported = onImported
    }

    override var title: String { String(localized: "从其他验证器导入") }
    override var resizable: Bool { true }

    override func makeContent(close: @escaping () -> Void) -> AnyView {
        let model = AuthenticatorImportModel(store: store)
        self.model = model
        return AnyView(AuthenticatorImportView(model: model, onImport: { [weak self, weak model] in
            guard let self, let model, let outcome = model.importSelected() else { return }
            close()
            self.onImported()
            var notes: [String] = []
            if outcome.skipped > 0 {
                notes.append(String(localized: "\(outcome.skipped) 条因标识已存在而跳过。"))
            }
            if outcome.readFiles {
                notes.append(String(localized: "导入用的图片里含有密钥，用完请删除。"))
            }
            showAlert(String(localized: "成功导入 \(outcome.added) 条记录"), informative: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        }, onCancel: close))
    }

    /// Opens the window with these QR code payloads already read (from the add window).
    func present(with payloads: [String]) {
        present()
        model?.add(payloads: payloads)
    }

    /// ⌘V from the Edit menu reaches the window's delegate when no text field has focus.
    @objc func paste(_ sender: Any?) {
        model?.paste()
    }
}

// MARK: - Model

final class AuthenticatorImportModel: ObservableObject {
    struct Outcome {
        let added: Int
        let skipped: Int
        let readFiles: Bool
    }

    @Published private(set) var importer: AuthenticatorImport
    /// What the last image, file or paste gave.
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    private let store: AccountStore
    /// The pasteboard's change count when secrets were last read from it; it is cleared after the
    /// import if nothing was copied since.
    private var clipboardChangeCount: Int?
    private var readFiles = false

    init(store: AccountStore) {
        self.store = store
        importer = AuthenticatorImport(existing: store.accounts)
    }

    func setName(_ name: String, for id: Int) {
        importer.setName(name, for: id)
    }

    func setSelected(_ selected: Bool, for id: Int) {
        importer.setSelected(selected, for: id)
    }

    func add(payloads: [String]) {
        report(payloads.map { importer.add(payload: $0) })
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "选择 Google Authenticator 导出的二维码图片，或含有 otpauth:// 二维码的图片")
        guard panel.runModal() == .OK else { return }
        addImages(at: panel.urls)
    }

    func addImages(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        readFiles = true
        let payloads = urls.flatMap { QRCodeScanner.payloads(inImageAt: $0) }
        guard !payloads.isEmpty else { return show(String(localized: "图片里没有找到二维码。"), error: true) }
        add(payloads: payloads)
    }

    func addImageData(_ data: Data) {
        let payloads = QRCodeScanner.payloads(inImageData: data)
        guard !payloads.isEmpty else { return show(String(localized: "图片里没有找到二维码。"), error: true) }
        add(payloads: payloads)
    }

    /// Image files copied in Finder, then an image, then text.
    func paste() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addImages(at: urls)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            clipboardChangeCount = changeCount
            addImageData(data)
        } else if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clipboardChangeCount = changeCount
            report(importer.add(text: text))
        } else {
            show(String(localized: "剪贴板里没有图片或链接。"), error: true)
        }
    }

    /// Finder files and screenshot thumbnails come as file URLs; images dragged from other apps as data.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { self.addImages(at: [url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { self.addImageData(data) }
                }
            }
        }
        return handled
    }

    /// Adds the selected rows; nil (with the reason shown) if saving failed.
    func importSelected() -> Outcome? {
        let entries = importer.entries
        do {
            let added = try store.importAccounts(entries)
            let pasteboard = NSPasteboard.general
            if let clipboardChangeCount, pasteboard.changeCount == clipboardChangeCount {
                pasteboard.clearContents()
            }
            return Outcome(added: added, skipped: entries.count - added, readFiles: readFiles)
        } catch {
            show(error.localizedDescription, error: true)
            return nil
        }
    }

    private func report(_ results: [ImportAddResult]) {
        var added = 0
        var problems: [String] = []
        var repeated = false
        for result in results {
            switch result {
            case .added(let count): added += count
            case .alreadyRead: repeated = true
            case .notAnAccount: problems.append(String(localized: "这不是验证器账号的二维码或链接。"))
            case .invalid(let reason): problems.append(reason)
            }
        }
        var lines: [String] = []
        if added > 0 { lines.append(String(localized: "读到 \(added) 个账号。")) }
        if repeated && added == 0 { lines.append(String(localized: "这些账号已经读过了。")) }
        for problem in problems where !lines.contains(problem) {
            lines.append(problem)
        }
        show(lines.joined(separator: "\n"), error: added == 0 && !problems.isEmpty)
    }

    private func show(_ text: String, error: Bool) {
        message = text.isEmpty ? nil : text
        messageIsError = error
    }
}

// MARK: - View

struct AuthenticatorImportView: View {
    @ObservedObject var model: AuthenticatorImportModel
    let onImport: () -> Void
    let onCancel: () -> Void
    @State private var dropTargeted = false

    private var selectedCount: Int { model.importer.entries.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("支持 Google Authenticator「转移账号」生成的二维码，以及 otpauth:// 链接。Microsoft Authenticator 和 Authy 无法导出账号。安卓版 Google Authenticator 不能截图，可以用另一台设备拍下二维码，再传到这台 Mac。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            dropZone
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.importer.batches, id: \.id) { batch in
                Text(batchText(batch)).font(.callout)
            }
            if model.importer.candidates.isEmpty {
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(model.importer.candidates) { candidate in
                        row(candidate)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
            if let issue = model.importer.nameIssue {
                Text(issueText(issue)).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "导入 \(selectedCount) 个账号"), action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0 || model.importer.nameIssue != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 480)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Text("把二维码图片拖到这里").foregroundStyle(.secondary)
            HStack {
                Button("选择图片…") { model.chooseImages() }
                Button("粘贴") { model.paste() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            model.drop(providers)
        }
    }

    private func row(_ candidate: ImportCandidate) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { candidate.isSelected }, set: { model.setSelected($0, for: candidate.id) }))
                .labelsHidden()
                .disabled(candidate.url == nil)
            VStack(alignment: .leading, spacing: 2) {
                TextField("名称", text: Binding(get: { candidate.name }, set: { model.setName($0, for: candidate.id) }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(candidate.url == nil)
                Text([candidate.issuer, candidate.summary].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(statusText(candidate.status))
                .font(.caption)
                .foregroundStyle(statusColor(candidate.status))
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ status: ImportCandidate.Status) -> String {
        switch status {
        case .new: return String(localized: "新账号")
        case .exists(let name): return String(localized: "已存在：\(name)")
        case .renamed(let original): return String(localized: "已改名（「\(original)」已被使用）")
        case .unsupported: return String(localized: "不支持")
        }
    }

    private func statusColor(_ status: ImportCandidate.Status) -> Color {
        switch status {
        case .new: return .secondary
        case .exists, .renamed: return .orange
        case .unsupported: return .red
        }
    }

    private func batchText(_ batch: BatchProgress) -> String {
        let missing = batch.missing
        if missing.isEmpty {
            return String(localized: "Google Authenticator 导出的 \(batch.size) 张二维码都已读取。")
        }
        let numbers = missing.map(String.init).joined(separator: String(localized: "、"))
        return String(localized: "Google Authenticator 导出共 \(batch.size) 张二维码，还差第 \(numbers) 张。")
    }

    private func issueText(_ issue: ImportNameIssue) -> String {
        switch issue {
        case .empty(let row): return String(localized: "第 \(row) 行的名称为空。")
        case .duplicate(let row, let name): return String(localized: "第 \(row) 行的名称「\(name)」已被使用。")
        }
    }
}
