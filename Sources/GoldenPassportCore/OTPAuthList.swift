import Foundation

/// Plain-text export: one otpauth URL per line, each preceded by a `# <name>` comment
/// so renamed accounts keep their names. Other authenticators can read the URLs directly.
public enum OTPAuthList {
    public static func render(_ accounts: [Account]) -> String {
        accounts.map { "# \($0.name)\n\($0.url)" }.joined(separator: "\n\n") + "\n"
    }

    /// Returns valid entries in file order. A `# name` line names the URL that follows it;
    /// URLs without one use their label. Invalid URLs are reported, not imported.
    public static func parse(_ text: String) -> (entries: [(name: String, url: String)], invalidLines: [Int]) {
        var entries: [(name: String, url: String)] = []
        var invalid: [Int] = []
        var pendingName: String?
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
                pendingName = name.isEmpty ? nil : name
                continue
            }
            if let parsed = try? OTPAuthURL(string: line) {
                let name = pendingName ?? parsed.suggestedName
                entries.append((name: name.isEmpty ? String(localized: "未命名 \(entries.count + 1)") : name, url: line))
            } else {
                invalid.append(offset + 1)
            }
            pendingName = nil
        }
        return (entries, invalid)
    }
}
