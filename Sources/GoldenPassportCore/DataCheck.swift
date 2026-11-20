import Foundation

/// Step 3 of design 5.4: the new build runs `--migrate-data` on the real data while the old one
/// still runs, so a build that can't read the accounts never replaces one that can. It is also the
/// first time the new executable runs on this Mac, so security software that blocks it shows up here.
public enum DataCheck {
    /// Long enough to answer a Keychain prompt (locked keychain, or "Allow" instead of "Always Allow").
    public static let timeout: TimeInterval = 120

    /// Passes when the data was already in place (or there is none) and the new build reads it from
    /// the same storage as this one. A build that couldn't read its own Info.plist would look for
    /// accounts.json instead of the Keychain and could report "no-data": the storage line catches that.
    public static func evaluate(_ result: ProcessResult, expectedStorage: String) throws {
        let lines = result.output.split(whereSeparator: \.isNewline)
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let status = value("status"), storage = value("storage")
        guard result.status == 0, let status, ["already-migrated", "no-data"].contains(status), storage == expectedStorage else {
            throw UpdateError.dataCheck("exit=\(result.status) status=\(status ?? "none") storage=\(storage ?? "none")")
        }
    }

    public static func run(app: URL, expectedStorage: String, timeout: TimeInterval = DataCheck.timeout) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let name = info?["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else {
            throw UpdateError.dataCheck("CFBundleExecutable")
        }
        let executable = app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(executable, ["--migrate-data"], timeout: timeout)
        } catch ProcessRunnerError.timedOut {
            throw UpdateError.dataCheckTimedOut
        } catch {
            throw UpdateError.dataCheck("\(error)")
        }
        try evaluate(result, expectedStorage: expectedStorage)
    }
}
