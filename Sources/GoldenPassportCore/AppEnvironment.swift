import Foundation

/// Per-build configuration read from Info.plist, so the Dev build never touches
/// the data, port or hotkeys of the installed release build.
public struct AppEnvironment: Sendable {
    public struct Defaults: Sendable {
        public var httpPort: Int
        public var hotkeysEnabled: Bool

        public init(httpPort: Int, hotkeysEnabled: Bool) {
            self.httpPort = httpPort
            self.hotkeysEnabled = hotkeysEnabled
        }
    }

    public var dataDirectory: URL
    /// Directory to copy legacy data from on first launch (Dev build only). Never written to.
    public var seedDirectory: URL?
    public var defaults: Defaults
    /// Keychain service holding the accounts (data format 2, docs/design/d3-keychain.md).
    /// nil keeps them in `accounts.json` (format 1): ad-hoc signed builds would make macOS ask
    /// for Keychain access after every update. Info.plist `GPKeychainService`.
    public var keychainService: String?
    /// Replaces the login Keychain in tests.
    var secretItems: (any SecretItems)?

    public init(dataDirectory: URL, seedDirectory: URL?, defaults: Defaults, keychainService: String? = nil) {
        self.dataDirectory = dataDirectory
        self.seedDirectory = seedDirectory
        self.defaults = defaults
        self.keychainService = keychainService
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> AppEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dirName = info["GPDataDirectoryName"] as? String ?? "GoldenPassport"
        let seedName = (info["GPSeedDirectoryName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let port = (info["GPDefaultHTTPPort"] as? NSNumber)?.intValue ?? 17304
        let hotkeys = (info["GPHotkeysEnabledByDefault"] as? NSNumber)?.boolValue ?? true
        let service = (info["GPKeychainService"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppEnvironment(
            dataDirectory: support.appendingPathComponent(dirName, isDirectory: true),
            seedDirectory: seedName.map { support.appendingPathComponent($0, isDirectory: true) },
            defaults: Defaults(httpPort: port, hotkeysEnabled: hotkeys),
            keychainService: service)
    }

    /// The data format this build keeps its accounts in (docs/compatibility.md).
    public var dataFormat: Int {
        keychainService == nil ? AccountStore.dataFormat : KeychainAccountStorage.formatVersion
    }

    var keychainStorage: KeychainAccountStorage? {
        keychainService.map {
            KeychainAccountStorage(items: secretItems ?? LoginKeychain(service: $0), service: $0, directory: dataDirectory)
        }
    }

    /// The accounts, from wherever `prepareDataDirectory` left them. Throws rather than
    /// return an empty list when they exist but can't be read.
    public func openAccountStore() throws -> AccountStore {
        if let storage = keychainStorage { return try AccountStore(storage: storage) }
        if let marker = try AccountsMarker.load(from: dataDirectory) {
            throw KeychainError.newerFormat(marker.formatVersion)
        }
        return try AccountStore(directory: dataDirectory)
    }

    /// Creates the data directory, seeds it (Dev only) and migrates older data: `gp.secrets`
    /// (format 0) and, in builds that use the Keychain, `accounts.json` (format 1). Never
    /// changes those files. Throws, and changes nothing, when data that exists can't be read.
    public func prepareDataDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let accountsURL = dataDirectory.appendingPathComponent(AccountStore.fileName)
        let legacySecretsURL = dataDirectory.appendingPathComponent(LegacyData.secretsFileName)
        let legacyConfigURL = dataDirectory.appendingPathComponent(LegacyData.configFileName)
        // A newer or damaged marker stops here, before anything could be migrated a second time.
        let marker = try AccountsMarker.load(from: dataDirectory)

        if let seed = seedDirectory, marker == nil,
           !fm.fileExists(atPath: accountsURL.path),
           !fm.fileExists(atPath: legacySecretsURL.path) {
            for name in [LegacyData.secretsFileName, LegacyData.configFileName] {
                let source = seed.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: dataDirectory.appendingPathComponent(name))
                }
            }
        }

        // 0.1.x left the directory 0755 and its files 0644, readable by every local user.
        // Tightening permissions leaves the contents (and the old app's access) unchanged.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
        for url in [legacySecretsURL, legacyConfigURL] where fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let migratedLegacy: Bool
        if let storage = keychainStorage {
            migratedLegacy = marker == nil ? try migrate(into: storage) : false
        } else {
            // This build only knows accounts.json. Migrating gp.secrets into it again would
            // hide every change made since the accounts moved to the Keychain.
            if let marker { throw KeychainError.newerFormat(marker.formatVersion) }
            migratedLegacy = try migrateToAccountsFile()
        }

        if !migratedLegacy, fm.fileExists(atPath: legacySecretsURL.path), (try? LegacyBaseline.load(from: dataDirectory)) == nil {
            // Migrated before I6 (or the baseline can't be read): start from gp.secrets as it is
            // now; earlier changes in 0.1.x can't be told apart any more. The accounts live
            // elsewhere now, so an unreadable gp.secrets is no reason to stop.
            if let legacy = try? LegacyData.readDictionary(at: legacySecretsURL) {
                try? LegacyBaseline.record(legacy, in: dataDirectory)
            }
        }
    }

    /// Data format 1: creates `accounts.json` from `gp.secrets`. Returns whether it did.
    private func migrateToAccountsFile() throws -> Bool {
        let accountsURL = dataDirectory.appendingPathComponent(AccountStore.fileName)
        // Refuse to start on an unreadable accounts.json rather than risk overwriting it.
        _ = try AccountStore.load(from: accountsURL)
        guard !FileManager.default.fileExists(atPath: accountsURL.path),
              let legacy = try readLegacySecrets() else { return false }
        try AccountStore(directory: dataDirectory).replaceAll(with: LegacyData.accounts(from: legacy))
        finishLegacyMigration(legacy)
        return true
    }

    /// Data format 2, before there is a marker (design 5.2): from `accounts.json` if there is
    /// one (beta builds), else from `gp.secrets` (0.1.x). Returns whether `gp.secrets` was the source.
    private func migrate(into storage: KeychainAccountStorage) throws -> Bool {
        let accountsURL = dataDirectory.appendingPathComponent(AccountStore.fileName)
        if FileManager.default.fileExists(atPath: accountsURL.path) {
            try storage.migrate(AccountStore.load(from: accountsURL), from: AccountStore.fileName)
            return false
        }
        if let legacy = try readLegacySecrets() {
            try storage.migrate(LegacyData.accounts(from: legacy), from: LegacyData.secretsFileName)
            finishLegacyMigration(legacy)
            return true
        }
        _ = try storage.adoptExistingItem()
        return false
    }

    /// Throws if `gp.secrets` exists but can't be read: carrying on would start with no
    /// accounts, and they would never be migrated.
    private func readLegacySecrets() throws -> [String: String]? {
        let url = dataDirectory.appendingPathComponent(LegacyData.secretsFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try LegacyData.readDictionary(at: url)
    }

    /// What follows a migration from 0.1.x: the I6 baseline and the 0.1.x settings.
    private func finishLegacyMigration(_ legacy: [String: String]) {
        // What gp.secrets held at migration, so that accounts 0.1.x changes later (after a
        // rollback) can be told apart from accounts deleted in 0.2.x (I6). Only a prompt
        // depends on it, so failing to write it must not stop startup.
        try? LegacyBaseline.record(legacy, in: dataDirectory)

        let settingsURL = dataDirectory.appendingPathComponent(SettingsStore.fileName)
        guard !FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        // 0.1.x wrote config.plist only once a setting was changed, and fell back
        // to defaults when it could not read it.
        let legacyConfigURL = dataDirectory.appendingPathComponent(LegacyData.configFileName)
        let config = (try? LegacyData.readDictionary(at: legacyConfigURL)) ?? [:]
        let store = SettingsStore(directory: dataDirectory, defaults: defaults)
        // 0.1.x started the HTTP API unless the user had turned that off. New installs
        // start with it off; upgraders keep the old behaviour so their scripts still work.
        store.httpServerAutoStart = config["http_server_auto_start"].map { $0 == "true" } ?? true
        // Only a port the user explicitly changed carries over; Dev keeps its own default.
        if seedDirectory == nil, let port = config["http_server_port"].flatMap(Int.init) {
            store.httpServerPort = port
        }
    }

    /// The data file the accounts can be migrated from again when the Keychain item is gone
    /// (design 5.5, decision 5): `accounts.json`, else `gp.secrets`. Both hold the accounts as
    /// they were before the move to the Keychain, not the changes made since.
    public var remigrationSource: String? {
        guard keychainService != nil else { return nil }
        return [AccountStore.fileName, LegacyData.secretsFileName].first {
            FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent($0).path)
        }
    }

    /// Migrates again from `remigrationSource`, only when the user chose to after the
    /// Keychain item went missing. Never replaces an item that is there.
    public func remigrate() throws {
        guard let storage = keychainStorage, let source = remigrationSource else { return }
        guard try storage.item.read() == nil else { return }
        if source == AccountStore.fileName {
            try storage.migrate(AccountStore.load(from: dataDirectory.appendingPathComponent(source)), from: source)
        } else if let legacy = try readLegacySecrets() {
            try storage.migrate(LegacyData.accounts(from: legacy), from: source)
            // The accounts now match gp.secrets as it is, so later 0.1.x changes start from here.
            try? LegacyBaseline.record(legacy, in: dataDirectory)
        }
    }
}
