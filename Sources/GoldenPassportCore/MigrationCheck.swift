import Foundation

/// Headless data preparation for the installer: runs the same migration as a normal
/// launch, then proves the stored accounts hold every entry of the file they came from.
/// Reports names only, never secrets, because the output ends up in terminals and bug reports.
public struct MigrationCheck: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// The accounts were moved into their storage during this run.
        case migrated
        /// They were already there (an earlier 0.2.x run); edits since then are expected.
        case alreadyMigrated = "already-migrated"
        /// Fresh install with no data at all.
        case noData = "no-data"
    }

    public enum Storage: String, Sendable {
        /// Data format 1, `accounts.json`.
        case file
        /// Data format 2, the login Keychain.
        case keychain
    }

    public var status: Status
    public var legacyCount: Int?
    public var accountCount: Int
    /// Entries of the migrated file absent from the stored accounts or stored with a different
    /// URL. Only meaningful for `.migrated`.
    public var mismatchedNames: [String]
    /// Changes 0.1.x made to `gp.secrets` after the migration that the app will ask about
    /// (I6), as in `LegacyChanges.summary`. Reported only; this check never settles them.
    public var legacyChanges: [String] = []
    /// How many of `legacyChanges` the app offers to import.
    public var legacyImportCount = 0
    public var storage: Storage = .file
    /// The file migrated from in this run, or recorded in the marker for the Keychain.
    public var source: String?
    /// Accounts in `accounts.json` whose otpauth URL the Keychain doesn't have, under any name:
    /// deleted since the migration, or changed in a beta build after a rollback (design 5.4,
    /// decision 4). `cleanup.sh` lists them before it deletes `accounts.json`.
    public var fileOnlyNames: [String] = []

    public var isConsistent: Bool { status != .migrated || mismatchedNames.isEmpty }

    public static func run(environment: AppEnvironment) throws -> MigrationCheck {
        let fm = FileManager.default
        let dir = environment.dataDirectory
        let accountsURL = dir.appendingPathComponent(AccountStore.fileName)
        let legacyURL = dir.appendingPathComponent(LegacyData.secretsFileName)
        let keychain = environment.keychainService != nil
        // prepareDataDirectory throws on a marker that can't be used, so `try?` loses nothing.
        let hadMarker = (try? AccountsMarker.load(from: dir)) != nil
        let hadAccounts = keychain ? hadMarker : fm.fileExists(atPath: accountsURL.path)

        try environment.prepareDataDirectory()

        let accounts = try environment.openAccountStore().accounts
        let legacy = fm.fileExists(atPath: legacyURL.path) ? try LegacyData.readDictionary(at: legacyURL) : nil

        let status: Status
        let source: String?
        if keychain {
            let marker = try AccountsMarker.load(from: dir)
            source = marker?.migratedFrom
            status = hadAccounts || (marker != nil && source == nil) ? .alreadyMigrated
                : (marker == nil ? .noData : .migrated)
        } else {
            status = hadAccounts ? .alreadyMigrated : (legacy == nil ? .noData : .migrated)
            source = status == .migrated ? LegacyData.secretsFileName : nil
        }

        var mismatched: [String] = []
        if status == .migrated {
            let original: [String: String]
            if source == AccountStore.fileName {
                original = Dictionary(try AccountStore.load(from: accountsURL).map { ($0.name, $0.url) },
                                      uniquingKeysWith: { first, _ in first })
            } else {
                original = legacy ?? [:]
            }
            let migrated = Dictionary(accounts.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
            mismatched = original.keys.filter { migrated[$0] != original[$0] }.sorted()
        }

        var fileOnly: [String] = []
        if keychain, fm.fileExists(atPath: accountsURL.path),
           let file = try? AccountStore.load(from: accountsURL) {
            let urls = Set(accounts.map(\.url))
            fileOnly = file.filter { !urls.contains($0.url) }.map(\.name)
        }

        let changes = LegacyChanges.detect(in: dir, accounts: accounts)
        return MigrationCheck(status: status, legacyCount: legacy?.count,
                              accountCount: accounts.count, mismatchedNames: mismatched,
                              legacyChanges: changes?.summary ?? [], legacyImportCount: changes?.imports.count ?? 0,
                              storage: keychain ? .keychain : .file, source: source, fileOnlyNames: fileOnly)
    }

    /// `key=value` lines so shell scripts can parse the result without extra tools.
    public var report: String {
        var lines = ["status=\(status.rawValue)",
                     "legacy_count=\(legacyCount.map(String.init) ?? "none")",
                     "account_count=\(accountCount)",
                     "consistent=\(isConsistent)",
                     "legacy_imports=\(legacyImportCount)",
                     "storage=\(storage.rawValue)",
                     "source=\(source ?? "none")"]
        // A line break in an account name must not start a line of its own.
        lines += mismatchedNames.map { "mismatch=\(Self.oneLine($0))" }
        lines += legacyChanges.map { "legacy_change=\(Self.oneLine($0))" }
        lines += fileOnlyNames.map { "file_only=\(Self.oneLine($0))" }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
