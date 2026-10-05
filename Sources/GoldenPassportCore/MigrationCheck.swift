import Foundation

/// Headless data preparation for the installer: runs the same migration as a normal
/// launch, then proves `accounts.json` holds every legacy entry. Reports names only,
/// never secrets, because the output ends up in terminals and bug reports.
public struct MigrationCheck: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// `accounts.json` was created from `gp.secrets` during this run.
        case migrated
        /// `accounts.json` already existed (upgrade from 0.2.x); edits since then are expected.
        case alreadyMigrated = "already-migrated"
        /// Fresh install with no data at all.
        case noData = "no-data"
    }

    public var status: Status
    public var legacyCount: Int?
    public var accountCount: Int
    /// Legacy entries absent from `accounts.json` or stored with a different URL.
    /// Only meaningful for `.migrated`.
    public var mismatchedNames: [String]

    public var isConsistent: Bool { status != .migrated || mismatchedNames.isEmpty }

    public static func run(environment: AppEnvironment) throws -> MigrationCheck {
        let fm = FileManager.default
        let dir = environment.dataDirectory
        let accountsURL = dir.appendingPathComponent(AccountStore.fileName)
        let legacyURL = dir.appendingPathComponent(LegacyData.secretsFileName)
        let hadAccounts = fm.fileExists(atPath: accountsURL.path)

        try environment.prepareDataDirectory()

        let accounts: [Account] = fm.fileExists(atPath: accountsURL.path)
            ? try JSONDecoder().decode([Account].self, from: Data(contentsOf: accountsURL))
            : []
        let legacy = fm.fileExists(atPath: legacyURL.path) ? try LegacyData.readDictionary(at: legacyURL) : nil

        let status: Status = hadAccounts ? .alreadyMigrated : (legacy == nil ? .noData : .migrated)
        var mismatched: [String] = []
        if status == .migrated, let legacy {
            let migrated = Dictionary(accounts.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
            mismatched = legacy.keys.filter { migrated[$0] != legacy[$0] }.sorted()
        }
        return MigrationCheck(status: status, legacyCount: legacy?.count,
                              accountCount: accounts.count, mismatchedNames: mismatched)
    }

    /// `key=value` lines so shell scripts can parse the result without extra tools.
    public var report: String {
        var lines = ["status=\(status.rawValue)",
                     "legacy_count=\(legacyCount.map(String.init) ?? "none")",
                     "account_count=\(accountCount)",
                     "consistent=\(isConsistent)"]
        lines += mismatchedNames.map { "mismatch=\($0)" }
        return lines.joined(separator: "\n")
    }
}
