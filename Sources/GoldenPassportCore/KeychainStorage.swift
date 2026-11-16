import Foundation
import Security

/// One secret blob in a store outside the data directory. `LoginKeychainItem` is the real one;
/// tests use one kept in memory.
protocol SecretItem: Sendable {
    /// The stored bytes, or nil if the item doesn't exist.
    func read() throws -> Data?
    /// Creates the item or replaces its contents.
    func write(_ data: Data) throws
}

/// Why the accounts in the Keychain can't be used. Startup stops on any of these without
/// writing anything (docs/design/d3-keychain.md 5.5).
public enum KeychainError: Error, Equatable, LocalizedError {
    /// The marker file says the accounts are in the Keychain, but the item is gone.
    case missing
    /// The user denied access in the Keychain prompt.
    case denied
    /// The Keychain is locked and can't ask to be unlocked.
    case locked
    /// The item exists but doesn't hold a list this version understands.
    case unreadable
    /// Written by a newer version of GoldenPassport.
    case newerFormat(Int)
    case failed(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: self = .denied
        case errSecInteractionNotAllowed: self = .locked
        default: self = .failed(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missing:
            return String(localized: "钥匙串里找不到 GoldenPassport 的账号数据。")
        case .denied:
            return String(localized: "没有获得读取钥匙串的授权。")
        case .locked:
            return String(localized: "钥匙串已锁定，请先解锁。")
        case .unreadable:
            return String(localized: "钥匙串里的账号数据无法识别。")
        case .newerFormat(let version):
            return String(localized: "数据来自更新版本的 GoldenPassport（数据格式 \(version)），请升级后再打开。")
        case .failed(let status):
            return String(localized: "钥匙串操作失败（错误 \(String(status))）。")
        }
    }
}

/// A generic-password item in the login Keychain. Never synchronised to iCloud: the
/// data-protection Keychain is not used (docs/design/d3-keychain.md section 6).
struct LoginKeychainItem: SecretItem {
    let service: String
    let account: String
    /// Shown in Keychain Access.
    let label: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unreadable }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    /// Removes the item; succeeds if it doesn't exist.
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// `accounts-v2.json` in the data directory: says the accounts are in the Keychain and under
/// which service. Holds no names or secrets, so scripts can read it and old versions ignore it.
public struct AccountsMarker: Codable, Equatable, Sendable {
    public static let fileName = "accounts-v2.json"

    public var formatVersion: Int
    /// Always "keychain" for now.
    public var storage: String
    public var service: String
    /// `gp.secrets` or `accounts.json`; absent (not null) on a fresh install. `plutil -extract
    /// … raw` in the scripts fails on a null value just as on a missing key, so absent is the
    /// one way the file says "nothing was migrated".
    public var migratedFrom: String?
    /// When the marker was written, which is when the Keychain took over.
    public var migratedAt: Date

    public init(service: String, migratedFrom: String?, migratedAt: Date = Date()) {
        formatVersion = KeychainAccountStorage.formatVersion
        storage = "keychain"
        self.service = service
        self.migratedFrom = migratedFrom
        self.migratedAt = migratedAt
    }

    /// The marker in `directory`, or nil if there is none. Throws if it exists but can't be
    /// used, so that a newer or damaged marker never leads to a second migration.
    public static func load(from directory: URL) throws -> AccountsMarker? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UnreadableDataFileError(file: url, underlying: error)
        }
        struct Version: Decodable { var formatVersion: Int }
        if let version = (try? JSONDecoder().decode(Version.self, from: data))?.formatVersion,
           version > KeychainAccountStorage.formatVersion {
            throw KeychainError.newerFormat(version)
        }
        do {
            let marker = try decoder.decode(AccountsMarker.self, from: data)
            guard marker.storage == "keychain" else { throw CocoaError(.fileReadCorruptFile) }
            return marker
        } catch {
            throw UnreadableDataFileError(file: url, underlying: error)
        }
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileStorage.writeProtected(try encoder.encode(self), to: directory.appendingPathComponent(Self.fileName))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Data format 2: the whole list in one Keychain item, plus `AccountsMarker` in the data
/// directory (docs/design/d3-keychain.md 5.1).
struct KeychainAccountStorage: AccountStorage {
    static let formatVersion = 2
    /// The Keychain item's account attribute; the service comes from Info.plist.
    static let itemAccount = "accounts"

    let item: any SecretItem
    let service: String
    let directory: URL

    init(item: any SecretItem, service: String, directory: URL) {
        self.item = item
        self.service = service
        self.directory = directory
    }

    init(service: String, directory: URL) {
        self.init(item: LoginKeychainItem(service: service, account: Self.itemAccount, label: "GoldenPassport"),
                  service: service, directory: directory)
    }

    func load() throws -> [Account] {
        guard let data = try item.read() else {
            // With a marker the list was stored here, so a missing item is not an empty list.
            if try AccountsMarker.load(from: directory) != nil { throw KeychainError.missing }
            return []
        }
        return try Self.decode(data)
    }

    /// Writes the item first and the marker only after that, so a marker always points at data.
    func save(_ accounts: [Account]) throws {
        try item.write(Self.encode(accounts))
        if try AccountsMarker.load(from: directory) == nil {
            try AccountsMarker(service: service, migratedFrom: nil).write(to: directory)
        }
    }

    private struct Payload: Codable {
        var formatVersion: Int
        var accounts: [Account]
    }

    static func encode(_ accounts: [Account]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(formatVersion: formatVersion, accounts: accounts))
    }

    static func decode(_ data: Data) throws -> [Account] {
        struct Version: Decodable { var formatVersion: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data).formatVersion else {
            throw KeychainError.unreadable
        }
        guard version <= formatVersion else { throw KeychainError.newerFormat(version) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw KeychainError.unreadable
        }
        return payload.accounts
    }
}
