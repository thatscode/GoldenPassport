import Foundation
import Testing
@testable import GoldenPassportCore

/// Keeps the list in memory, as the Keychain store will keep it outside the data directory.
final class MemoryStorage: AccountStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Account]

    init(_ accounts: [Account] = []) {
        stored = accounts
    }

    var accounts: [Account] {
        lock.withLock { stored }
    }

    func load() throws -> [Account] {
        lock.withLock { stored }
    }

    func save(_ accounts: [Account]) throws {
        lock.withLock { stored = accounts }
    }
}

struct SaveRefused: Error {}

/// Refuses every write, as the Keychain does when the user denies access.
struct RefusingStorage: AccountStorage {
    let accounts: [Account]

    func load() throws -> [Account] {
        accounts
    }

    func save(_ accounts: [Account]) throws {
        throw SaveRefused()
    }
}

enum Mutation: CaseIterable, Sendable {
    case add, rename, updateURL, move, remove, importAccounts, replaceAll
}

struct AccountStorageTests {
    @Test(arguments: Mutation.allCases)
    func failedSaveLeavesTheListAsItWas(_ mutation: Mutation) throws {
        let original = [Account(name: "a", url: validURL),
                        Account(name: "b", url: "otpauth://totp/B?secret=MZXW6YTBOI")]
        let store = try AccountStore(storage: RefusingStorage(accounts: original))
        let id = original[0].id

        #expect(throws: SaveRefused.self) {
            switch mutation {
            case .add: try store.add(name: "c", url: validURL)
            case .rename: try store.rename(id: id, to: "renamed")
            case .updateURL: try store.updateURL(id: id, to: "otpauth://totp/x?secret=MZXW6YTBOI&digits=8")
            case .move: try store.move(fromOffsets: IndexSet([0]), toOffset: 2)
            case .remove: try store.remove(id: id)
            case .importAccounts: _ = try store.importAccounts([(name: "d", url: validURL)])
            case .replaceAll: try store.replaceAll(with: [])
            }
        }
        // What the menu, hotkeys and HTTP API see must match what is stored.
        #expect(store.accounts == original)
    }

    @Test func storeLoadsFromAndSavesToItsStorage() throws {
        let storage = MemoryStorage([Account(name: "a", url: validURL), Account(name: "b", url: validURL)])
        let store = try AccountStore(storage: storage)
        #expect(store.accounts.map(\.name) == ["a", "b"])

        try store.add(name: "c", url: validURL)                    // a, b, c
        try store.rename(id: store.accounts[0].id, to: "a2")       // a2, b, c
        try store.move(fromOffsets: IndexSet([2]), toOffset: 0)    // c, a2, b
        try store.remove(id: store.accounts[2].id)                 // c, a2

        #expect(storage.accounts.map(\.name) == ["c", "a2"])
        #expect(try AccountStore(storage: storage).accounts.map(\.name) == ["c", "a2"])
    }
}
