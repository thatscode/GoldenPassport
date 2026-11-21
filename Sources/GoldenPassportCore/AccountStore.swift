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
    /// When the code stops being accepted (see `TOTP.validUntil(codeAt:)`).
    public let validUntil: Date?

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

/// Where the account list is kept. Data format 1 keeps it in `accounts.json` (`AccountsFile`);
/// D3 adds the login Keychain (docs/design/d3-keychain.md).
protocol AccountStorage: Sendable {
    /// The stored accounts, or none if nothing has been stored yet. Throws if they exist but
    /// can't be read, so that they are never replaced by an empty list.
    func load() throws -> [Account]
    /// Replaces the stored list with `accounts`.
    func save(_ accounts: [Account]) throws
}

/// Data format 1: the list as JSON in `accounts.json`, readable only by the current user.
struct AccountsFile: AccountStorage {
    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent(AccountStore.fileName)
    }

    func load() throws -> [Account] {
        try AccountStore.load(from: url)
    }

    func save(_ accounts: [Account]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileStorage.writeProtected(try encoder.encode(accounts), to: url)
    }
}

/// Ordered account list, kept in an `AccountStorage`. Thread-safe: the HTTP server reads it
/// from a background queue while the menu mutates it on the main thread.
public final class AccountStore: @unchecked Sendable {
    public static let fileName = "accounts.json"
    /// Version of the format of `fileName` (docs/compatibility.md); 0 is the 0.1.x `gp.secrets`.
    public static let dataFormat = 1

    private let storage: any AccountStorage
    private let lock = NSLock()
    private var list: [Account]

    /// Throws `UnreadableDataFileError` if the file exists but cannot be read: starting
    /// with an empty list would overwrite the user's accounts on the next save.
    public convenience init(directory: URL) throws {
        try self.init(storage: AccountsFile(directory: directory))
    }

    /// Throws if `storage` holds accounts it can't read, for the same reason.
    init(storage: any AccountStorage) throws {
        self.storage = storage
        list = try storage.load()
    }

    /// The accounts stored in `url`, or none if the file does not exist.
    public static func load(from url: URL) throws -> [Account] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([Account].self, from: Data(contentsOf: url))
        } catch {
            throw UnreadableDataFileError(file: url, underlying: error)
        }
    }

    public var accounts: [Account] {
        lock.withLock { list }
    }

    public var count: Int {
        lock.withLock { list.count }
    }

    @discardableResult
    public func add(name rawName: String, url rawURL: String) throws -> Account {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OTPAuthURL(string: url)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try lock.withLock {
            try validate(name: name, excluding: nil)
            let account = Account(name: name, url: url)
            try commit(list + [account])
            return account
        }
    }

    public func remove(id: UUID) throws {
        try lock.withLock {
            try commit(list.filter { $0.id != id })
        }
    }

    public func rename(id: UUID, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try lock.withLock {
            let index = try indexOf(id)
            try validate(name: name, excluding: id)
            var updated = list
            updated[index].name = name
            try commit(updated)
        }
    }

    public func updateURL(id: UUID, to rawURL: String) throws {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OTPAuthURL(string: url)
        try lock.withLock {
            var updated = list
            updated[try indexOf(id)].url = url
            try commit(updated)
        }
    }

    /// Same semantics as SwiftUI's `onMove`: `destination` is an index in the list before the move.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try lock.withLock {
            var updated = list
            let moving = source.map { updated[$0] }
            for index in source.reversed() { updated.remove(at: index) }
            let target = destination - source.count(in: 0..<destination)
            updated.insert(contentsOf: moving, at: target)
            try commit(updated)
        }
    }

    /// Adds accounts whose names are not taken yet; returns how many were added.
    public func importAccounts(_ entries: [(name: String, url: String)]) throws -> Int {
        try lock.withLock {
            var updated = list
            for entry in entries where !updated.contains(where: { $0.name == entry.name }) {
                updated.append(Account(name: entry.name, url: entry.url))
            }
            let added = updated.count - list.count
            if added > 0 { try commit(updated) }
            return added
        }
    }

    public func replaceAll(with accounts: [Account]) throws {
        try lock.withLock {
            try commit(accounts)
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
                               secondsRemaining: totp.secondsRemaining(at: date),
                               validUntil: totp.validUntil(codeAt: date))
        } catch {
            return AccountCode(account: account,
                               result: .failure(error as? OTPAuthURLError ?? .invalidURL),
                               secondsRemaining: nil, validUntil: nil)
        }
    }

    // Must be called with the lock held.
    private func indexOf(_ id: UUID) throws -> Int {
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw AccountStoreError.notFound }
        return index
    }

    // Must be called with the lock held.
    private func validate(name: String, excluding id: UUID?) throws {
        guard !name.isEmpty else { throw AccountStoreError.emptyName }
        if list.contains(where: { $0.name == name && $0.id != id }) {
            throw AccountStoreError.duplicateName(name)
        }
    }

    // Must be called with the lock held. Saves before changing the list, so that after a failed
    // save the menu, hotkeys and HTTP API still show what is stored.
    private func commit(_ accounts: [Account]) throws {
        try storage.save(accounts)
        list = accounts
    }
}

/// A data file exists but cannot be read. Callers stop rather than carry on as if it
/// were empty, so the file is never overwritten and its accounts are never skipped.
public struct UnreadableDataFileError: LocalizedError {
    public let file: URL
    public let underlying: Error

    public var errorDescription: String? {
        String(localized: "无法读取 \(file.lastPathComponent)：\(underlying.localizedDescription)")
    }
}

enum FileStorage {
    /// Atomic write readable only by the current user (the files hold MFA secrets).
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Where a file that can't be read is moved to instead of being overwritten:
    /// `<name>.unreadable-<time>` next to it.
    static func keptCopy(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).unreadable-\(timestamp())")
    }

    /// `yyyyMMdd-HHmmss` in local time, for names of kept copies.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
