import CommonCrypto
import CryptoKit
import Foundation

public enum EncryptedBackupError: Error, Equatable, LocalizedError {
    case notABackup
    case newerVersion(Int)
    case unsupportedAlgorithm(String)
    case invalidParameters
    case passwordTooShort
    case wrongPasswordOrDamaged
    case unreadableContents

    public var errorDescription: String? {
        switch self {
        case .notABackup: return String(localized: "这不是 GoldenPassport 的加密备份文件。")
        case .newerVersion: return String(localized: "这份备份由更新版本的 GoldenPassport 创建，请先升级再导入。")
        case .unsupportedAlgorithm(let name): return String(localized: "备份使用了不支持的算法 \(name)。")
        case .invalidParameters: return String(localized: "备份文件的参数不合法，文件可能已损坏。")
        case .passwordTooShort:
            return String(localized: "密码至少需要 \(EncryptedBackup.minimumPasswordLength) 个字符。")
        case .wrongPasswordOrDamaged: return String(localized: "密码不对，或者文件已损坏。")
        case .unreadableContents: return String(localized: "备份已解密，但里面的内容无法识别。")
        }
    }
}

/// Password-protected backups (`.gpbackup`, docs/design/encrypted-backup.md): a JSON header with
/// the key derivation (PBKDF2-HMAC-SHA256) and cipher (AES-256-GCM) parameters, and the accounts
/// as encrypted JSON. The header is authenticated too, so a changed parameter fails like a wrong
/// password.
public enum EncryptedBackup {
    public static let fileExtension = "gpbackup"
    public static let minimumPasswordLength = 8
    /// What new backups use (OWASP's figure for PBKDF2-HMAC-SHA256); older files keep theirs.
    public static let iterations = 600_000

    static let format = "GoldenPassport encrypted backup"
    static let version = 1
    static let kdfName = "PBKDF2-HMAC-SHA256"
    static let cipherName = "AES-256-GCM"
    /// Counts accepted when opening; the upper bound keeps a tampered file from stalling the app.
    static let acceptedIterations = 100_000...10_000_000
    static let saltLength = 16
    static let nonceLength = 12
    static let keyLength = 32
    static let tagLength = 16

    struct File: Codable {
        struct KDF: Codable {
            var name: String
            var iterations: Int
            var salt: String
        }

        struct Cipher: Codable {
            var name: String
            var nonce: String
        }

        var format: String
        var version: Int
        var kdf: KDF
        var cipher: Cipher
        var ciphertext: String
    }

    struct Payload: Codable {
        struct Entry: Codable {
            var name: String
            var url: String
        }

        var version: Int
        var accounts: [Entry]
    }

    public static func seal(_ accounts: [Account], password: String) throws -> Data {
        try seal(accounts, password: password, iterations: iterations)
    }

    static func seal(_ accounts: [Account], password: String, iterations: Int) throws -> Data {
        let payload = Payload(version: 1, accounts: accounts.map { Payload.Entry(name: $0.name, url: $0.url) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try seal(payload: try encoder.encode(payload), password: password, iterations: iterations)
    }

    static func seal(payload: Data, password: String, iterations: Int) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw EncryptedBackupError.passwordTooShort }
        let salt = SymmetricKey(size: SymmetricKeySize(bitCount: saltLength * 8)).withUnsafeBytes { Data($0) }
        let nonce = AES.GCM.Nonce()
        var file = File(format: format, version: version,
                        kdf: File.KDF(name: kdfName, iterations: iterations, salt: salt.base64EncodedString()),
                        cipher: File.Cipher(name: cipherName, nonce: Data(nonce).base64EncodedString()),
                        ciphertext: "")
        guard let key = deriveKey(password: passwordBytes(password), salt: salt, iterations: iterations, length: keyLength)
        else { throw EncryptedBackupError.invalidParameters }
        let box = try AES.GCM.seal(payload, using: SymmetricKey(data: key), nonce: nonce,
                                   authenticating: additionalData(file))
        file.ciphertext = (box.ciphertext + box.tag).base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Checks the header without deriving a key: format, version, algorithms, parameter ranges.
    public static func inspect(_ data: Data) throws {
        _ = try parse(data)
    }

    /// The accounts in the backup, in order; entries whose URL can't be read are counted, not returned.
    public static func open(_ data: Data, password: String) throws -> (entries: [(name: String, url: String)], invalid: Int) {
        let parsed = try parse(data)
        guard let key = deriveKey(password: passwordBytes(password), salt: parsed.salt,
                                  iterations: parsed.file.kdf.iterations, length: keyLength)
        else { throw EncryptedBackupError.wrongPasswordOrDamaged }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: parsed.nonce),
                                            ciphertext: Data(parsed.ciphertext.dropLast(tagLength)),
                                            tag: Data(parsed.ciphertext.suffix(tagLength)))
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: additionalData(parsed.file))
        } catch {
            throw EncryptedBackupError.wrongPasswordOrDamaged
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: plaintext) else {
            throw EncryptedBackupError.unreadableContents
        }
        var entries: [(name: String, url: String)] = []
        var invalid = 0
        for entry in payload.accounts {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, (try? OTPAuthURL(string: entry.url)) != nil {
                entries.append((name: name, url: entry.url))
            } else {
                invalid += 1
            }
        }
        return (entries, invalid)
    }

    /// Writes the backup readable only by the current user.
    public static func write(_ data: Data, to url: URL) throws {
        try FileStorage.writeProtected(data, to: url)
    }

    private struct Parsed {
        let file: File
        let salt: Data
        let nonce: Data
        let ciphertext: Data
    }

    private static func parse(_ data: Data) throws -> Parsed {
        // Format and version come first, so a newer file is reported as newer even if its other
        // fields changed.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == format,
              let fileVersion = object["version"] as? Int, fileVersion >= 1 else {
            throw EncryptedBackupError.notABackup
        }
        guard fileVersion <= version else { throw EncryptedBackupError.newerVersion(fileVersion) }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw EncryptedBackupError.notABackup }
        guard file.kdf.name == kdfName else { throw EncryptedBackupError.unsupportedAlgorithm(file.kdf.name) }
        guard file.cipher.name == cipherName else { throw EncryptedBackupError.unsupportedAlgorithm(file.cipher.name) }
        guard acceptedIterations.contains(file.kdf.iterations),
              let salt = Data(base64Encoded: file.kdf.salt), salt.count >= saltLength,
              let nonce = Data(base64Encoded: file.cipher.nonce), nonce.count == nonceLength,
              let ciphertext = Data(base64Encoded: file.ciphertext), ciphertext.count >= tagLength else {
            throw EncryptedBackupError.invalidParameters
        }
        return Parsed(file: file, salt: salt, nonce: nonce, ciphertext: ciphertext)
    }

    /// The header fields the cipher authenticates, as written in the file.
    private static func additionalData(_ file: File) -> Data {
        Data([file.format, String(file.version), file.kdf.name, String(file.kdf.iterations), file.kdf.salt,
              file.cipher.name].joined(separator: "\n").utf8)
    }

    /// NFC first: the same password typed with a different input method gives the same bytes.
    private static func passwordBytes(_ password: String) -> Data {
        Data(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// PBKDF2-HMAC-SHA256 from CommonCrypto; nil if it fails.
    static func deriveKey(password: Data, salt: Data, iterations: Int, length: Int) -> Data? {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         output.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }
}
