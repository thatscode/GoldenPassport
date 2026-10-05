import AppKit
import GoldenPassportCore
import SwiftUI

final class ManageAccountsWindowController: HostedWindowController {
    private let store: AccountStore
    private let hotkeyLabel: (Int) -> String?
    private let onChange: () -> Void

    init(store: AccountStore, hotkeyLabel: @escaping (Int) -> String?, onChange: @escaping () -> Void) {
        self.store = store
        self.hotkeyLabel = hotkeyLabel
        self.onChange = onChange
    }

    override var title: String { "管理认证" }
    override var resizable: Bool { true }

    override func makeContent(close: @escaping () -> Void) -> AnyView {
        AnyView(ManageAccountsView(model: AccountListModel(store: store, onChange: onChange),
                                   hotkeyLabel: hotkeyLabel, onClose: close))
    }
}

final class AccountListModel: ObservableObject {
    @Published private(set) var accounts: [Account]
    @Published var errorMessage: String?
    private let store: AccountStore
    private let onChange: () -> Void

    init(store: AccountStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        accounts = store.accounts
    }

    /// Runs a store mutation, reloads, and reports whether it succeeded.
    @discardableResult
    func perform(_ change: (AccountStore) throws -> Void) -> Bool {
        defer {
            accounts = store.accounts
            onChange()
        }
        do {
            try change(store)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private enum EditField: Identifiable {
    case name(Account)
    case url(Account)

    var id: String {
        switch self {
        case .name(let a): return "name-\(a.id)"
        case .url(let a): return "url-\(a.id)"
        }
    }
}

struct ManageAccountsView: View {
    @ObservedObject var model: AccountListModel
    let hotkeyLabel: (Int) -> String?
    let onClose: () -> Void

    @State private var selection: UUID?
    @State private var editing: EditField?
    @State private var confirmingDelete: Account?

    private var selectedIndex: Int? {
        selection.flatMap { id in model.accounts.firstIndex { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("拖动可调整顺序，前 10 条依次对应全局快捷键 0–9。双击可重命名，右键有更多操作。")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                    HStack {
                        Text(account.name)
                        Spacer()
                        if let label = hotkeyLabel(index) {
                            Text(label)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(account.id)
                }
                .onMove { source, destination in
                    model.perform { try $0.move(fromOffsets: source, toOffset: destination) }
                }
            }
            // Unlike onTapGesture(count: 2) on the rows, this keeps single-click selection instant.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let account = account(for: ids) {
                    Button("重命名...") { editing = .name(account) }
                    Button("修改 URL...") { editing = .url(account) }
                    Divider()
                    Button("删除...") { confirmingDelete = account }
                }
            } primaryAction: { ids in
                if let account = account(for: ids) { editing = .name(account) }
            }
            .frame(minHeight: 320)

            HStack {
                Button("重命名...") { selectedAccount.map { editing = .name($0) } }
                    .disabled(selectedIndex == nil)
                Button("修改 URL...") { selectedAccount.map { editing = .url($0) } }
                    .disabled(selectedIndex == nil)
                Button("删除...") { confirmingDelete = selectedAccount }
                    .disabled(selectedIndex == nil)
                Spacer()
                Button { moveSelection(by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("上移")
                    .disabled((selectedIndex ?? 0) == 0)
                Button { moveSelection(by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("下移")
                    .disabled(selectedIndex.map { $0 >= model.accounts.count - 1 } ?? true)
                Button("完成", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .sheet(item: $editing) { field in
            EditFieldSheet(field: field, model: model) { editing = nil }
        }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil && editing == nil },
                                           set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("删除「\(confirmingDelete?.name ?? "")」？",
                            isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let account = confirmingDelete {
                    model.perform { try $0.remove(id: account.id) }
                }
                confirmingDelete = nil
            }
        } message: {
            Text("删除后无法恢复，建议先导出备份。")
        }
    }

    private func account(for ids: Set<UUID>) -> Account? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.accounts.first { $0.id == id }
    }

    private var selectedAccount: Account? {
        selectedIndex.map { model.accounts[$0] }
    }

    private func moveSelection(by offset: Int) {
        guard let index = selectedIndex else { return }
        let target = index + offset
        guard model.accounts.indices.contains(target) else { return }
        // onMove semantics: moving down by one means inserting before index + 2.
        model.perform { try $0.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target) }
    }
}

private struct EditFieldSheet: View {
    let field: EditField
    @ObservedObject var model: AccountListModel
    let dismiss: () -> Void
    @State private var text: String
    @State private var error: String?

    init(field: EditField, model: AccountListModel, dismiss: @escaping () -> Void) {
        self.field = field
        self.model = model
        self.dismiss = dismiss
        switch field {
        case .name(let a): _text = State(initialValue: a.name)
        case .url(let a): _text = State(initialValue: a.url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch field {
            case .name:
                Text("重命名").font(.headline)
                TextField("标识", text: $text).onSubmit(save)
            case .url:
                Text("修改 OTPAuth URL").font(.headline)
                Text("仅在服务端重新绑定 MFA 后需要修改。").font(.callout).foregroundStyle(.secondary)
                TextField("otpauth://totp/...", text: $text, axis: .vertical)
                    .lineLimit(3...6)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: field.isURL ? 520 : 360)
    }

    private func save() {
        let ok = model.perform { store in
            switch field {
            case .name(let a): try store.rename(id: a.id, to: text)
            case .url(let a): try store.updateURL(id: a.id, to: text)
            }
        }
        if ok {
            dismiss()
        } else {
            error = model.errorMessage
            model.errorMessage = nil
        }
    }
}

private extension EditField {
    var isURL: Bool {
        if case .url = self { return true }
        return false
    }
}
