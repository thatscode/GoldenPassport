import Foundation

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The original otpauth URL, kept verbatim so export stays lossless.
    public var url: String

    public init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

public struct AccountCode: Sendable {
    public let account: Account
    public let result: Result<String, OTPAuthURLError>
    public let secondsRemaining: Int?

    public var displayCode: String {
        switch result {
        case .success(let code): return code
        case .failure: return String(localized: "<无效密钥>")
        }
    }
}

public enum AccountStoreError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "标识不能为空。")
        case .duplicateName(let name): return String(localized: "已存在名为「\(name)」的记录，请换一个标识。")
        case .notFound: return String(localized: "记录不存在，可能已被删除。")
        }
    }
}

/// Ordered account list persisted as JSON. Thread-safe: the HTTP server reads it
/// from a background queue while the menu mutates it on the main thread.
public final class AccountStore: @unchecked Sendable {
    public static let fileName = "accounts.json"

    private let fileURL: URL
    private let lock = NSLock()
    private var storage: [Account]

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        storage = Self.load(from: fileURL)
    }

    public var accounts: [Account] {
        lock.withLock { storage }
    }

    public var count: Int {
        lock.withLock { storage.count }
    }

    @discardableResult
    public func add(name rawName: String, url rawURL: String) throws -> Account {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OTPAuthURL(string: url)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try lock.withLock {
            try validate(name: name, excluding: nil)
            let account = Account(name: name, url: url)
            storage.append(account)
            try save()
            return account
        }
    }

    public func remove(id: UUID) throws {
        try lock.withLock {
            storage.removeAll { $0.id == id }
            try save()
        }
    }

    public func rename(id: UUID, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try lock.withLock {
            let index = try indexOf(id)
            try validate(name: name, excluding: id)
            storage[index].name = name
            try save()
        }
    }

    public func updateURL(id: UUID, to rawURL: String) throws {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OTPAuthURL(string: url)
        try lock.withLock {
            storage[try indexOf(id)].url = url
            try save()
        }
    }

    /// Same semantics as SwiftUI's `onMove`: `destination` is an index in the list before the move.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try lock.withLock {
            let moving = source.map { storage[$0] }
            for index in source.reversed() { storage.remove(at: index) }
            let target = destination - source.count(in: 0..<destination)
            storage.insert(contentsOf: moving, at: target)
            try save()
        }
    }

    /// Adds accounts whose names are not taken yet; returns how many were added.
    public func importAccounts(_ entries: [(name: String, url: String)]) throws -> Int {
        try lock.withLock {
            var added = 0
            for entry in entries where !storage.contains(where: { $0.name == entry.name }) {
                storage.append(Account(name: entry.name, url: entry.url))
                added += 1
            }
            if added > 0 { try save() }
            return added
        }
    }

    public func replaceAll(with accounts: [Account]) throws {
        try lock.withLock {
            storage = accounts
            try save()
        }
    }

    public func codes(at date: Date = Date()) -> [AccountCode] {
        accounts.map { Self.code(for: $0, at: date) }
    }

    public func code(named name: String, at date: Date = Date()) -> AccountCode? {
        accounts.first { $0.name == name }.map { Self.code(for: $0, at: date) }
    }

    public static func code(for account: Account, at date: Date) -> AccountCode {
        do {
            let totp = try OTPAuthURL(string: account.url).totp
            return AccountCode(account: account,
                               result: .success(totp.code(at: date)),
                               secondsRemaining: totp.secondsRemaining(at: date))
        } catch {
            return AccountCode(account: account,
                               result: .failure(error as? OTPAuthURLError ?? .invalidURL),
                               secondsRemaining: nil)
        }
    }

    // Must be called with the lock held.
    private func indexOf(_ id: UUID) throws -> Int {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { throw AccountStoreError.notFound }
        return index
    }

    // Must be called with the lock held.
    private func validate(name: String, excluding id: UUID?) throws {
        guard !name.isEmpty else { throw AccountStoreError.emptyName }
        if storage.contains(where: { $0.name == name && $0.id != id }) {
            throw AccountStoreError.duplicateName(name)
        }
    }

    // Must be called with the lock held.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileStorage.writeProtected(try encoder.encode(storage), to: fileURL)
    }

    private static func load(from url: URL) -> [Account] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }
}

enum FileStorage {
    /// Atomic write readable only by the current user (the files hold MFA secrets).
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
