import Foundation
import Testing
@testable import GoldenPassportCore

/// Stores what is written but reads back a list without its last account, to stand in for a
/// write that didn't keep everything.
final class LossyKeychain: SecretItems, @unchecked Sendable {
    let inner = MemoryKeychain()

    func item(_ account: String) -> any SecretItem {
        Lossy(inner: inner.memoryItem(account))
    }

    struct Lossy: SecretItem {
        let inner: MemoryItem

        func read() throws -> Data? {
            guard let data = try inner.read() else { return nil }
            return try KeychainAccountStorage.encode(KeychainAccountStorage.decode(data).dropLast())
        }

        func write(_ data: Data) throws {
            try inner.write(data)
        }
    }
}

/// Design section 9, tests 1 to 5 and 8: moving the accounts into the Keychain.
struct KeychainMigrationTests {
    private let service = "site.stanzhai.GoldenPassport.tests"

    private func environment(_ dir: URL, _ items: any SecretItems) -> AppEnvironment {
        var env = AppEnvironment(dataDirectory: dir, seedDirectory: nil,
                                 defaults: .init(httpPort: 17304, hotkeysEnabled: true), keychainService: service)
        env.secretItems = items
        return env
    }

    private func file(_ dir: URL, _ name: String) -> URL { dir.appendingPathComponent(name) }

    private func exists(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: file(dir, name).path)
    }

    private func storedAccounts(_ keychain: MemoryKeychain) throws -> [Account] {
        try KeychainAccountStorage.decode(#require(keychain.memoryItem(KeychainAccountStorage.itemAccount).data))
    }

    private func writeAccountsFile(_ accounts: [Account], in dir: URL) throws {
        try AccountsFile(directory: dir).save(accounts)
    }

    @Test func migratesFromGPSecretsAndLeavesItAlone() throws {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(["zeta": validURL, "Alpha": validURL], to: file(dir, LegacyData.secretsFileName))
        let before = try Data(contentsOf: file(dir, LegacyData.secretsFileName))
        let keychain = MemoryKeychain()

        let env = environment(dir, keychain)
        try env.prepareDataDirectory()

        #expect(try storedAccounts(keychain).map(\.name) == ["Alpha", "zeta"])
        #expect(try env.openAccountStore().accounts.map(\.name) == ["Alpha", "zeta"])
        #expect(try Data(contentsOf: file(dir, LegacyData.secretsFileName)) == before)
        #expect(!exists(dir, AccountStore.fileName), "no plaintext accounts.json")
        #expect(try AccountsMarker.load(from: dir)?.migratedFrom == LegacyData.secretsFileName)
        #expect(try LegacyBaseline.load(from: dir) != nil, "I6 baseline as before")
        #expect(SettingsStore(directory: dir, defaults: env.defaults).httpServerAutoStart, "0.1.x settings carried over")
    }

    @Test func migratesFromAccountsFileKeepingIDsAndTheFile() throws {
        let dir = try makeTempDirectory()
        let accounts = [Account(name: "b", url: validURL), Account(name: "a", url: "otpauth://totp/A?secret=MZXW6YTBOI")]
        try writeAccountsFile(accounts, in: dir)
        // A beta user who came from 0.1.x still has gp.secrets; accounts.json is the newer data.
        try LegacyData.writeDictionary(["old": validURL], to: file(dir, LegacyData.secretsFileName))
        let before = try Data(contentsOf: file(dir, AccountStore.fileName))
        let keychain = MemoryKeychain()

        try environment(dir, keychain).prepareDataDirectory()

        #expect(try storedAccounts(keychain) == accounts)
        #expect(try Data(contentsOf: file(dir, AccountStore.fileName)) == before)
        #expect(try AccountsMarker.load(from: dir)?.migratedFrom == AccountStore.fileName)
    }

    @Test func migratesOnlyOnce() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "a", url: validURL)], in: dir)
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        try env.prepareDataDirectory()
        try env.openAccountStore().add(name: "b", url: validURL)

        // An older build writing accounts.json after a rollback must not replace the Keychain list.
        try writeAccountsFile([Account(name: "from a beta", url: validURL)], in: dir)
        try env.prepareDataDirectory()

        #expect(try env.openAccountStore().accounts.map(\.name) == ["a", "b"])
        #expect(keychain.accounts == [KeychainAccountStorage.itemAccount])
    }

    @Test func existingItemIsKeptAsideBeforeMigrating() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "restored", url: validURL)], in: dir)
        let keychain = MemoryKeychain()
        let earlier = try KeychainAccountStorage.encode([Account(name: "earlier", url: validURL)])
        keychain.memoryItem(KeychainAccountStorage.itemAccount).data = earlier

        try environment(dir, keychain).prepareDataDirectory()

        #expect(try storedAccounts(keychain).map(\.name) == ["restored"])
        let aside = try #require(keychain.accounts.first { $0.hasPrefix("accounts.replaced-") })
        #expect(keychain.memoryItem(aside).data == earlier)
    }

    @Test func freshInstallWritesNothingUntilTheFirstAccount() throws {
        let dir = try makeTempDirectory()
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        try env.prepareDataDirectory()

        #expect(try AccountsMarker.load(from: dir) == nil)
        #expect(keychain.accounts.isEmpty)
        let store = try env.openAccountStore()
        #expect(store.accounts.isEmpty)

        try store.add(name: "a", url: validURL)
        #expect(try storedAccounts(keychain).map(\.name) == ["a"])
        #expect(try AccountsMarker.load(from: dir)?.migratedFrom == nil)
        #expect(try AccountsMarker.load(from: dir) != nil)
    }

    @Test func freshDataDirectoryUsesAnItemLeftInTheKeychain() throws {
        let dir = try makeTempDirectory()
        let keychain = MemoryKeychain()
        keychain.memoryItem(KeychainAccountStorage.itemAccount).data =
            try KeychainAccountStorage.encode([Account(name: "kept", url: validURL)])
        let env = environment(dir, keychain)

        try env.prepareDataDirectory()

        #expect(try env.openAccountStore().accounts.map(\.name) == ["kept"])
        let marker = try #require(try AccountsMarker.load(from: dir))
        #expect(marker.migratedFrom == nil)
    }

    @Test func unreadableLeftoverItemStopsAndStaysAsItIs() throws {
        let dir = try makeTempDirectory()
        let keychain = MemoryKeychain()
        keychain.memoryItem(KeychainAccountStorage.itemAccount).data = Data("junk".utf8)

        #expect(throws: KeychainError.unreadable) { try environment(dir, keychain).prepareDataDirectory() }
        #expect(try AccountsMarker.load(from: dir) == nil)
        #expect(keychain.memoryItem(KeychainAccountStorage.itemAccount).data == Data("junk".utf8))
    }

    @Test func unreadableAccountsFileStopsBeforeTheKeychain() throws {
        let dir = try makeTempDirectory()
        try Data("not json".utf8).write(to: file(dir, AccountStore.fileName))
        let keychain = MemoryKeychain()

        #expect(throws: UnreadableDataFileError.self) { try environment(dir, keychain).prepareDataDirectory() }
        #expect(keychain.accounts.isEmpty)
        #expect(try AccountsMarker.load(from: dir) == nil)
    }

    @Test func readBackThatDiffersLeavesNoMarker() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "a", url: validURL), Account(name: "b", url: validURL)], in: dir)
        let before = try Data(contentsOf: file(dir, AccountStore.fileName))

        #expect(throws: KeychainError.notVerified) { try environment(dir, LossyKeychain()).prepareDataDirectory() }
        #expect(try AccountsMarker.load(from: dir) == nil, "the next launch migrates again")
        #expect(try Data(contentsOf: file(dir, AccountStore.fileName)) == before)
    }

    @Test func deniedWriteLeavesNoMarkerAndNoBaseline() throws {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(["a": validURL], to: file(dir, LegacyData.secretsFileName))
        let keychain = MemoryKeychain()
        keychain.memoryItem(KeychainAccountStorage.itemAccount).failure = .denied

        #expect(throws: KeychainError.denied) { try environment(dir, keychain).prepareDataDirectory() }
        #expect(try AccountsMarker.load(from: dir) == nil)
        #expect(!exists(dir, LegacyBaseline.fileName))
        #expect(!exists(dir, SettingsStore.fileName))
    }

    /// A build without the Keychain (format 1) must not migrate gp.secrets into a new
    /// accounts.json once the accounts have moved.
    @Test func buildWithoutKeychainStopsAtAMarker() throws {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(["a": validURL], to: file(dir, LegacyData.secretsFileName))
        try environment(dir, MemoryKeychain()).prepareDataDirectory()

        let fileBuild = AppEnvironment(dataDirectory: dir, seedDirectory: nil,
                                       defaults: .init(httpPort: 17304, hotkeysEnabled: true))
        #expect(throws: KeychainError.newerFormat(2)) { try fileBuild.prepareDataDirectory() }
        #expect(throws: KeychainError.newerFormat(2)) { try fileBuild.openAccountStore() }
        #expect(!exists(dir, AccountStore.fileName))
    }

    @Test func dataFormatFollowsTheStorage() {
        let defaults = AppEnvironment.Defaults(httpPort: 1, hotkeysEnabled: false)
        let dir = URL(fileURLWithPath: "/nonexistent")
        #expect(AppEnvironment(dataDirectory: dir, seedDirectory: nil, defaults: defaults).dataFormat == 1)
        #expect(AppEnvironment(dataDirectory: dir, seedDirectory: nil, defaults: defaults, keychainService: "x").dataFormat == 2)
    }

    // MARK: Item gone (design 5.5, decision 5)

    @Test func missingItemOffersTheOldFileAndRemigratesOnlyWhenAsked() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "a", url: validURL)], in: dir)
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        try env.prepareDataDirectory()
        try env.openAccountStore().add(name: "added later", url: validURL)

        keychain.memoryItem(KeychainAccountStorage.itemAccount).data = nil   // deleted in Keychain Access
        try env.prepareDataDirectory()
        #expect(throws: KeychainError.missing) { try env.openAccountStore() }
        #expect(env.remigrationSource == AccountStore.fileName)
        #expect(keychain.memoryItem(KeychainAccountStorage.itemAccount).data == nil, "nothing happens on its own")

        try env.remigrate()
        #expect(try env.openAccountStore().accounts.map(\.name) == ["a"], "the data from before the move")
    }

    @Test func remigrationFromGPSecretsRecordsANewBaseline() throws {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(["a": validURL], to: file(dir, LegacyData.secretsFileName))
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        try env.prepareDataDirectory()
        keychain.memoryItem(KeychainAccountStorage.itemAccount).data = nil
        // 0.1.x added an account after a rollback; the store is about to hold it anyway.
        try LegacyData.writeDictionary(["a": validURL, "b": validURL], to: file(dir, LegacyData.secretsFileName))

        #expect(env.remigrationSource == LegacyData.secretsFileName)
        try env.remigrate()

        let store = try env.openAccountStore()
        #expect(store.accounts.map(\.name) == ["a", "b"])
        #expect(LegacyChanges.detect(in: dir, accounts: store.accounts) == nil, "nothing left to offer")
    }

    @Test func startingOverWithNoAccountsNeedsTheItemToBeGone() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "a", url: validURL)], in: dir)
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        try env.prepareDataDirectory()

        try env.startWithNoAccounts()
        #expect(try env.openAccountStore().accounts.map(\.name) == ["a"], "an item that is there stays")

        keychain.memoryItem(KeychainAccountStorage.itemAccount).data = nil
        try FileManager.default.removeItem(at: file(dir, AccountStore.fileName))   // cleaned up earlier
        #expect(env.remigrationSource == nil)
        #expect(throws: KeychainError.missing) { try env.openAccountStore() }
        #expect(try AccountsMarker.load(from: dir)?.migratedFrom == AccountStore.fileName)
        try env.startWithNoAccounts()
        #expect(try env.openAccountStore().accounts.isEmpty)
        #expect(try AccountsMarker.load(from: dir)?.migratedFrom == nil)
    }

    @Test func remigrateNeverReplacesAnItemThatIsThere() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "old", url: validURL)], in: dir)
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        try env.prepareDataDirectory()
        try env.openAccountStore().add(name: "new", url: validURL)

        try env.remigrate()
        #expect(try env.openAccountStore().accounts.map(\.name) == ["old", "new"])
    }

    // MARK: --migrate-data

    @Test func checkReportsKeychainMigrationAndItsSource() throws {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(["b": validURL, "a": validURL], to: file(dir, LegacyData.secretsFileName))
        let keychain = MemoryKeychain()

        let first = try MigrationCheck.run(environment: environment(dir, keychain))
        #expect(first.status == .migrated)
        #expect(first.isConsistent)
        #expect(first.report.contains("storage=keychain\nsource=gp.secrets"))
        #expect(first.accountCount == 2 && first.legacyCount == 2)

        let second = try MigrationCheck.run(environment: environment(dir, keychain))
        #expect(second.status == .alreadyMigrated)
        #expect(second.source == LegacyData.secretsFileName)
    }

    /// install.sh restores the previous app and data when --migrate-data fails.
    @Test func checkFailsWhenTheKeychainDoesNotKeepEverything() throws {
        let dir = try makeTempDirectory()
        try writeAccountsFile([Account(name: "a", url: validURL), Account(name: "b", url: validURL)], in: dir)

        #expect(throws: KeychainError.notVerified) { try MigrationCheck.run(environment: environment(dir, LossyKeychain())) }
    }

    /// Decision 4: accounts only accounts.json still has are listed for cleanup.sh, by URL.
    @Test func checkListsAccountsOnlyTheFileHas() throws {
        let dir = try makeTempDirectory()
        let renamedURL = "otpauth://totp/R?secret=MZXW6YTBOI"
        try writeAccountsFile([Account(name: "kept", url: validURL),
                               Account(name: "renamed later", url: renamedURL),
                               Account(name: "deleted later", url: "otpauth://totp/D?secret=MZXW6YTBOI")], in: dir)
        let keychain = MemoryKeychain()
        let env = environment(dir, keychain)
        _ = try MigrationCheck.run(environment: env)
        let store = try env.openAccountStore()
        try store.rename(id: store.accounts[1].id, to: "renamed")
        try store.remove(id: store.accounts[2].id)
        // Back on a beta build, an account was added to accounts.json.
        var file = try AccountStore.load(from: self.file(dir, AccountStore.fileName))
        file.append(Account(name: "added in the beta", url: "otpauth://totp/N?secret=MZXW6YTBOI"))
        try writeAccountsFile(file, in: dir)

        let check = try MigrationCheck.run(environment: env)
        #expect(check.status == .alreadyMigrated)
        #expect(check.fileOnlyNames == ["deleted later", "added in the beta"])
        #expect(check.report.contains("file_only=added in the beta"))
    }
}
