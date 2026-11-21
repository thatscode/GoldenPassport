import AppKit
import GoldenPassportCore

/// Password entry for encrypted backups: alerts with secure text fields, modal like the import and
/// export flows around them.
enum PasswordPrompt {
    /// Two fields; asks again until they match and are long enough. nil when cancelled.
    static func newPassword() -> String? {
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.alertStyle = problem == nil ? .informational : .warning
            alert.messageText = String(localized: "为加密备份设置密码")
            let rule = String(localized: "密码至少需要 \(EncryptedBackup.minimumPasswordLength) 个字符。")
            let warning = String(localized: "忘记密码就无法恢复这份备份，GoldenPassport 不保存密码。")
            alert.informativeText = [problem, rule, warning].compactMap { $0 }.joined(separator: "\n")
            let first = secureField(String(localized: "密码"))
            let second = secureField(String(localized: "再次输入密码"))
            first.nextKeyView = second
            alert.accessoryView = stack([first, second])
            alert.addButton(withTitle: String(localized: "继续"))
            alert.addButton(withTitle: String(localized: "取消"))
            alert.layout()
            alert.window.initialFirstResponder = first
            activateApp()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if first.stringValue.count < EncryptedBackup.minimumPasswordLength {
                problem = String(localized: "密码太短。")
            } else if first.stringValue != second.stringValue {
                problem = String(localized: "两次输入的密码不一致。")
            } else {
                return first.stringValue
            }
        }
    }

    /// One field; `error` (say, a wrong password) is shown on a retry. nil when cancelled.
    static func password(for fileName: String, error: String?) -> String? {
        let alert = NSAlert()
        alert.alertStyle = error == nil ? .informational : .warning
        alert.messageText = String(localized: "输入「\(fileName)」的密码")
        alert.informativeText = error ?? String(localized: "也就是导出这份加密备份时设置的密码。")
        let field = secureField(String(localized: "密码"))
        alert.accessoryView = stack([field])
        alert.addButton(withTitle: String(localized: "导入"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.layout()
        alert.window.initialFirstResponder = field
        activateApp()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static let fieldWidth: CGFloat = 280
    private static let fieldHeight: CGFloat = 24
    private static let spacing: CGFloat = 8

    private static func secureField(_ placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: fieldHeight))
        field.placeholderString = placeholder
        return field
    }

    /// The fields top to bottom, in a view with a fixed frame as NSAlert's accessory view needs.
    private static func stack(_ fields: [NSTextField]) -> NSView {
        let height = CGFloat(fields.count) * fieldHeight + CGFloat(fields.count - 1) * spacing
        let view = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: height))
        for (index, field) in fields.enumerated() {
            field.frame.origin.y = height - CGFloat(index + 1) * fieldHeight - CGFloat(index) * spacing
            view.addSubview(field)
        }
        return view
    }
}
