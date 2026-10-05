import Foundation

public enum OTPAuthURLError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme
    case unsupportedType(String)
    case missingSecret
    case invalidSecret
    case invalidParameter(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "无法识别的 URL，请检查是否完整复制。")
        case .unsupportedScheme: return String(localized: "不是 otpauth:// 开头的 URL。")
        case .unsupportedType(let type): return String(localized: "暂不支持 \(type) 类型，仅支持 totp。")
        case .missingSecret: return String(localized: "URL 中缺少 secret 参数。")
        case .invalidSecret: return String(localized: "secret 不是合法的 Base32 字符串。")
        case .invalidParameter(let name): return String(localized: "参数 \(name) 的取值不合法。")
        }
    }
}

/// A parsed `otpauth://totp/LABEL?secret=...&issuer=...` URL
/// (https://github.com/google/google-authenticator/wiki/Key-Uri-Format).
public struct OTPAuthURL: Equatable, Sendable {
    /// Percent-decoded label, e.g. "AWS:alice@123456789012".
    public let label: String
    public let issuer: String?
    public let totp: TOTP

    public init(string rawString: String) throws {
        let string = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: string)
            ?? URLComponents(string: string.replacingOccurrences(of: " ", with: "%20"))
        else {
            throw OTPAuthURLError.invalidURL
        }
        guard components.scheme?.lowercased() == "otpauth" else {
            throw OTPAuthURLError.unsupportedScheme
        }
        let type = (components.host ?? "").lowercased()
        guard type == "totp" else {
            throw OTPAuthURLError.unsupportedType(type.isEmpty ? String(localized: "未知") : type)
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                params[item.name.lowercased()] = value
            }
        }

        guard let secretString = params["secret"], !secretString.isEmpty else {
            throw OTPAuthURLError.missingSecret
        }
        guard let secret = Base32.decode(secretString), !secret.isEmpty else {
            throw OTPAuthURLError.invalidSecret
        }

        var algorithm = OTPAlgorithm.sha1
        if let value = params["algorithm"] {
            guard let parsed = OTPAlgorithm(rawValue: value.uppercased()) else {
                throw OTPAuthURLError.invalidParameter("algorithm")
            }
            algorithm = parsed
        }
        var digits = 6
        if let value = params["digits"] {
            guard let parsed = Int(value), TOTP.digitsRange.contains(parsed) else {
                throw OTPAuthURLError.invalidParameter("digits")
            }
            digits = parsed
        }
        var period = 30
        if let value = params["period"] {
            guard let parsed = Int(value), TOTP.periodRange.contains(parsed) else {
                throw OTPAuthURLError.invalidParameter("period")
            }
            period = parsed
        }

        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        self.label = label
        self.issuer = params["issuer"].flatMap { $0.isEmpty ? nil : $0 }
        self.totp = TOTP(secret: secret, algorithm: algorithm, digits: digits, period: period)
    }

    /// Default display name offered when adding an account.
    public var suggestedName: String {
        if !label.isEmpty { return label }
        return issuer ?? ""
    }
}
