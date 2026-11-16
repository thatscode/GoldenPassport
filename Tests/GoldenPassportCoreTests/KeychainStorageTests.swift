import Foundation
import Testing
@testable import GoldenPassportCore

/// A Keychain item kept in memory. `failure` makes every read and write throw, as the Keychain
/// does when access is denied or it is locked.
final class MemoryItem: SecretItem, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var error: KeychainError?

    init(_ data: Data? = nil, failure: KeychainError? = nil) {
        stored = data
        error = failure
    }

    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var failure: KeychainError? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }

    func read() throws -> Data? {
        try lock.withLock {
            if let error { throw error }
            return stored
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            if let error { throw error }
            stored = data
        }
    }
}

/// The items of one service, kept in memory. Asking twice for an account gives the same item.
final class MemoryKeychain: SecretItems, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: MemoryItem]

    init(_ items: [String: MemoryItem] = [:]) {
        stored = items
    }

    /// Accounts that have an item with data, sorted.
    var accounts: [String] {
        lock.withLock { stored.filter { $0.value.data != nil }.keys.sorted() }
    }

    func item(_ account: String) -> any SecretItem {
        memoryItem(account)
    }

    func memoryItem(_ account: String) -> MemoryItem {
        lock.withLock {
            if let item = stored[account] { return item }
            let item = MemoryItem()
            stored[account] = item
            return item
        }
    }
}

extension KeychainAccountStorage {
    init(item: MemoryItem, service: String, directory: URL) {
        self.init(items: MemoryKeychain([Self.itemAccount: item]), service: service, directory: directory)
    }
}

private let service = "site.stanzhai.GoldenPassport.tests"

private func markerURL(in dir: URL) -> URL {
    dir.appendingPathComponent(AccountsMarker.fileName)
}

private func contents(of dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

struct KeychainStorageTests {
    @Test func freshInstallStartsEmptyAndFirstSaveWritesItemThenMarker() throws {
        let dir = try makeTempDirectory()
        let item = MemoryItem()
        let store = try AccountStore(storage: KeychainAccountStorage(item: item, service: service, directory: dir))
        #expect(store.accounts.isEmpty)
        #expect(try contents(of: dir).isEmpty, "loading must not create anything")

        try store.add(name: "Acme", url: validURL)

        let payload = try #require(item.data)
        #expect(try KeychainAccountStorage.decode(payload).map(\.name) == ["Acme"])
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 2)

        let marker = try #require(try AccountsMarker.load(from: dir))
        #expect(marker.formatVersion == 2)
        #expect(marker.storage == "keychain")
        #expect(marker.service == service)
        #expect(marker.migratedFrom == nil)
        #expect(try contents(of: dir) == [AccountsMarker.fileName])
    }

    @Test func reopeningLoadsTheSameAccounts() throws {
        let dir = try makeTempDirectory()
        let item = MemoryItem()
        let storage = KeychainAccountStorage(item: item, service: service, directory: dir)
        let first = try AccountStore(storage: storage)
        try first.add(name: "b", url: validURL)
        try first.add(name: "a", url: "otpauth://totp/A?secret=MZXW6YTBOI")

        let second = try AccountStore(storage: storage)
        #expect(second.accounts == first.accounts)
        #expect(second.accounts.map(\.name) == ["b", "a"])
    }

    /// Design test 7: the data directory holds no secret and no account name.
    @Test func markerHoldsNoSecretsOrNames() throws {
        let dir = try makeTempDirectory()
        let store = try AccountStore(storage: KeychainAccountStorage(item: MemoryItem(), service: service, directory: dir))
        try store.add(name: "Secret Bank", url: validURL)

        let text = try String(contentsOf: markerURL(in: dir), encoding: .utf8)
        for needle in ["MZXW6YTBOI", "otpauth", "Secret Bank", "Acme", "alice"] {
            #expect(!text.contains(needle), "marker contains \(needle)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: markerURL(in: dir).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// The scripts read the marker with `plutil -extract … raw`; a fresh install has no
    /// `migratedFrom` key rather than a null one.
    @Test func freshMarkerLeavesOutMigratedFrom() throws {
        let dir = try makeTempDirectory()
        try AccountsMarker(service: service, migratedFrom: nil).write(to: dir)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL(in: dir))) as? [String: Any])
        #expect(Set(json.keys) == ["formatVersion", "storage", "service", "migratedAt"])

        try AccountsMarker(service: service, migratedFrom: LegacyData.secretsFileName).write(to: dir)
        #expect(try AccountsMarker.load(from: dir)?.migratedFrom == "gp.secrets")
    }

    @Test func missingItemWithMarkerStopsInsteadOfStartingEmpty() throws {
        let dir = try makeTempDirectory()
        try AccountsMarker(service: service, migratedFrom: nil).write(to: dir)
        let item = MemoryItem()

        #expect(throws: KeychainError.missing) {
            _ = try AccountStore(storage: KeychainAccountStorage(item: item, service: service, directory: dir))
        }
        #expect(item.data == nil)
    }

    static let unusableItems: [(Data, KeychainError)] = [
        (Data("not json".utf8), .unreadable),
        (Data(#"{"accounts": []}"#.utf8), .unreadable),
        (Data(#"{"formatVersion": 2, "accounts": [{"name": "x"}]}"#.utf8), .unreadable),
        (Data(#"{"formatVersion": 3, "accounts": [], "groups": []}"#.utf8), .newerFormat(3)),
    ]

    /// Design test 4: nothing is written when the item can't be used.
    @Test(arguments: unusableItems)
    func unusableItemStopsWithoutWriting(_ data: Data, _ expected: KeychainError) throws {
        let dir = try makeTempDirectory()
        let item = MemoryItem(data)

        #expect(throws: expected) {
            _ = try AccountStore(storage: KeychainAccountStorage(item: item, service: service, directory: dir))
        }
        #expect(item.data == data)
        #expect(try contents(of: dir).isEmpty)
    }

    @Test(arguments: [KeychainError.denied, .locked])
    func refusedReadStopsWithoutWriting(_ failure: KeychainError) throws {
        let dir = try makeTempDirectory()
        let item = MemoryItem(try KeychainAccountStorage.encode([]), failure: failure)

        #expect(throws: failure) {
            _ = try AccountStore(storage: KeychainAccountStorage(item: item, service: service, directory: dir))
        }
        #expect(try contents(of: dir).isEmpty)
    }

    /// Design test 6: a denied write leaves the list, the item and the data directory as they were.
    @Test func refusedSaveChangesNothing() throws {
        let dir = try makeTempDirectory()
        let original = [Account(name: "a", url: validURL)]
        let item = MemoryItem(try KeychainAccountStorage.encode(original))
        let store = try AccountStore(storage: KeychainAccountStorage(item: item, service: service, directory: dir))
        let before = item.data

        item.failure = .denied
        #expect(throws: KeychainError.denied) { try store.add(name: "b", url: validURL) }

        #expect(store.accounts == original)
        item.failure = nil
        #expect(item.data == before)
        #expect(try contents(of: dir).isEmpty, "no marker without a successful write")
    }

    @Test func newerMarkerStopsBeforeTheKeychainIsRead() throws {
        let dir = try makeTempDirectory()
        try Data(#"{"formatVersion": 3, "storage": "somewhere-else"}"#.utf8).write(to: markerURL(in: dir))
        let item = MemoryItem()

        #expect(throws: KeychainError.newerFormat(3)) { try AccountsMarker.load(from: dir) }
        #expect(throws: KeychainError.newerFormat(3)) {
            _ = try AccountStore(storage: KeychainAccountStorage(item: item, service: service, directory: dir))
        }
    }

    @Test(arguments: ["{", #"{"formatVersion": 2, "storage": "file", "service": "x", "migratedAt": "2026-11-17T00:00:00Z"}"#])
    func damagedMarkerIsUnreadable(_ text: String) throws {
        let dir = try makeTempDirectory()
        try Data(text.utf8).write(to: markerURL(in: dir))
        #expect(throws: UnreadableDataFileError.self) { try AccountsMarker.load(from: dir) }
    }

    @Test func statusCodesMapToReasons() {
        #expect(KeychainError(status: errSecUserCanceled) == .denied)
        #expect(KeychainError(status: errSecAuthFailed) == .denied)
        #expect(KeychainError(status: errSecInteractionNotAllowed) == .locked)
        #expect(KeychainError(status: errSecNoDefaultKeychain) == .failed(errSecNoDefaultKeychain))
        #expect(KeychainError.failed(-25307).errorDescription?.contains("-25307") == true)
    }
}

/// Writes to the real login Keychain under a throwaway service, then deletes the item.
/// Opt-in (`GP_KEYCHAIN_TESTS=1 make test`): CI runners may have no usable login Keychain,
/// and a developer's Mac should not get items unasked.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GP_KEYCHAIN_TESTS"] == "1"))
struct LoginKeychainTests {
    @Test func writesReadsReplacesAndDeletes() throws {
        let item = LoginKeychainItem(service: "site.stanzhai.GoldenPassport.tests.\(UUID().uuidString)",
                                     account: KeychainAccountStorage.itemAccount, label: "GoldenPassport tests")
        defer { try? item.delete() }

        #expect(try item.read() == nil)
        try item.write(Data("one".utf8))
        #expect(try item.read() == Data("one".utf8))
        try item.write(Data("two".utf8))
        #expect(try item.read() == Data("two".utf8))
        try item.delete()
        #expect(try item.read() == nil)
        try item.delete()
    }

    @Test func storeRoundTripsThroughTheLoginKeychain() throws {
        let dir = try makeTempDirectory()
        let testService = "site.stanzhai.GoldenPassport.tests.\(UUID().uuidString)"
        let storage = KeychainAccountStorage(service: testService, directory: dir)
        defer { try? (storage.item as? LoginKeychainItem)?.delete() }

        let store = try AccountStore(storage: storage)
        try store.add(name: "Acme", url: validURL)
        #expect(try AccountStore(storage: storage).accounts == store.accounts)
        #expect(try AccountsMarker.load(from: dir)?.service == testService)
    }
}
