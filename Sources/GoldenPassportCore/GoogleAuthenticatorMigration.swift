import Foundation

public enum MigrationError: Error, Equatable, LocalizedError {
    case notAMigrationURL
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .notAMigrationURL: return String(localized: "不是 Google Authenticator 的迁移二维码。")
        case .invalidData: return String(localized: "迁移二维码里的数据已损坏，无法读取。")
        }
    }
}

/// One account from a Google Authenticator export (docs/design/authenticator-import.md, section 3).
public struct MigratedAccount: Equatable, Sendable {
    /// Why the account can't become a TOTP account here.
    public enum Problem: Equatable, Sendable {
        case hotp
        case emptySecret
        case unknownAlgorithm(Int)
        case unknownDigits(Int)
        case unknownType(Int)

        public var reason: String {
            switch self {
            case .hotp: return String(localized: "按次数计数的验证码（HOTP），暂不支持")
            case .emptySecret: return String(localized: "没有密钥")
            case .unknownAlgorithm(let value): return String(localized: "未知的算法（\(value)）")
            case .unknownDigits(let value): return String(localized: "未知的位数（\(value)）")
            case .unknownType(let value): return String(localized: "未知的类型（\(value)）")
            }
        }
    }

    public let name: String
    public let issuer: String
    public let secret: Data
    /// SHA1 when the export names an algorithm this app doesn't know (then `problem` says so).
    public let algorithm: OTPAlgorithm
    public let digits: Int
    public let problem: Problem?

    /// "issuer:name", unless the name already starts with the issuer or there is none.
    public var label: String {
        guard !issuer.isEmpty, !name.hasPrefix("\(issuer):") else { return name }
        return "\(issuer):\(name)"
    }

    /// A standard otpauth URL with every parameter spelled out; nil for accounts with a problem.
    public var otpauthURL: String? {
        guard problem == nil else { return nil }
        var query = "secret=\(Base32.encode(secret))"
        if !issuer.isEmpty { query += "&issuer=\(Self.percentEncoded(issuer, keeping: ""))" }
        query += "&algorithm=\(algorithm.rawValue)&digits=\(digits)&period=30"
        return "otpauth://totp/\(Self.percentEncoded(label, keeping: ":@"))?\(query)"
    }

    /// Everything but RFC 3986's unreserved characters (and `extra`) percent-encoded, so "&", "/",
    /// "?" or "#" in a name can't change how the URL is read.
    private static func percentEncoded(_ string: String, keeping extra: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + extra)
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// One QR code of a Google Authenticator export. A large export is split into `batchSize` codes
/// that share `batchID`.
public struct MigrationBatch: Equatable, Sendable {
    public let accounts: [MigratedAccount]
    public let batchID: Int
    /// 0-based.
    public let batchIndex: Int
    public let batchSize: Int
}

/// Reads `otpauth-migration://offline?data=…`, the QR codes of Google Authenticator's "Transfer
/// accounts". The payload is protobuf (MigrationPayload); Google doesn't document it, the layout
/// is the one community implementations agree on.
public enum GoogleAuthenticatorMigration {
    public static func isMigrationURL(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth-migration://")
    }

    public static func parse(_ rawString: String) throws -> MigrationBatch {
        let string = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMigrationURL(string) else { throw MigrationError.notAMigrationURL }
        guard let components = URLComponents(string: string), components.host?.lowercased() == "offline",
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let payload = decodeBase64(encoded) else {
            throw MigrationError.invalidData
        }
        do {
            return try decodePayload(payload)
        } catch {
            throw MigrationError.invalidData
        }
    }

    /// Standard or URL-safe base64, with or without padding; a "+" that became a space is put back.
    private static func decodeBase64(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+").filter { !$0.isNewline }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func decodePayload(_ data: Data) throws -> MigrationBatch {
        var reader = ProtobufReader(data)
        var accounts: [MigratedAccount] = []
        var batchSize = 0, batchIndex = 0, batchID = 0
        while let next = try reader.next() {
            switch (next.field, next.value) {
            case (1, .bytes(let bytes)): accounts.append(try decodeAccount(bytes))
            case (3, .varint(let value)): batchSize = int32(value)
            case (4, .varint(let value)): batchIndex = int32(value)
            case (5, .varint(let value)): batchID = int32(value)
            default: break // version, and fields added later
            }
        }
        if batchSize == 0 { batchSize = 1 }
        guard batchSize >= 1, (0..<batchSize).contains(batchIndex) else { throw ProtobufError.malformed }
        return MigrationBatch(accounts: accounts, batchID: batchID, batchIndex: batchIndex, batchSize: batchSize)
    }

    private static func decodeAccount(_ data: Data) throws -> MigratedAccount {
        var reader = ProtobufReader(data)
        var secret = Data(), name = "", issuer = ""
        var algorithmValue = 0, digitsValue = 0, typeValue = 0
        while let next = try reader.next() {
            switch (next.field, next.value) {
            case (1, .bytes(let bytes)): secret = bytes
            case (2, .bytes(let bytes)): name = try text(bytes)
            case (3, .bytes(let bytes)): issuer = try text(bytes)
            case (4, .varint(let value)): algorithmValue = int32(value)
            case (5, .varint(let value)): digitsValue = int32(value)
            case (6, .varint(let value)): typeValue = int32(value)
            default: break // counter (HOTP only), and fields added later
            }
        }

        var problems: [MigratedAccount.Problem] = []
        switch typeValue {
        case 0, 2: break // unspecified (some tools leave it out) or TOTP
        case 1: problems.append(.hotp)
        default: problems.append(.unknownType(typeValue))
        }
        if secret.isEmpty { problems.append(.emptySecret) }
        let algorithm: OTPAlgorithm
        switch algorithmValue {
        case 0, 1: algorithm = .sha1
        case 2: algorithm = .sha256
        case 3: algorithm = .sha512
        case 4: algorithm = .md5
        default:
            algorithm = .sha1
            problems.append(.unknownAlgorithm(algorithmValue))
        }
        let digits: Int
        switch digitsValue {
        case 0, 1: digits = 6
        case 2: digits = 8
        default:
            digits = 6
            problems.append(.unknownDigits(digitsValue))
        }
        return MigratedAccount(name: name, issuer: issuer, secret: secret, algorithm: algorithm, digits: digits,
                               problem: problems.first)
    }

    /// protobuf int32 fields arrive as varints; negative values are sign-extended to 64 bits.
    private static func int32(_ value: UInt64) -> Int {
        Int(Int32(truncatingIfNeeded: value))
    }

    private static func text(_ bytes: Data) throws -> String {
        guard let string = String(data: bytes, encoding: .utf8) else { throw ProtobufError.malformed }
        return string
    }
}
