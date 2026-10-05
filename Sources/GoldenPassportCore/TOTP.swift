import CryptoKit
import Foundation

public enum OTPAlgorithm: String, CaseIterable, Codable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
    case md5 = "MD5"
}

/// RFC 6238 time-based one-time password generator.
public struct TOTP: Equatable, Sendable {
    public static let digitsRange = 6...8
    public static let periodRange = 1...300

    public let secret: Data
    public let algorithm: OTPAlgorithm
    public let digits: Int
    public let period: Int

    public init(secret: Data, algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30) {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    public func code(at date: Date = Date()) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(period))
        return code(counter: counter)
    }

    /// Seconds until the code shown at `date` expires.
    public func secondsRemaining(at date: Date = Date()) -> Int {
        let elapsed = Int(max(0, date.timeIntervalSince1970)) % period
        return period - elapsed
    }

    func code(counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        let mac = hmac(message)

        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])

        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(truncated % modulus)
        return String(repeating: "0", count: digits - value.count) + value
    }

    private func hmac(_ message: Data) -> [UInt8] {
        let key = SymmetricKey(data: secret)
        switch algorithm {
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: return Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        case .md5: return Array(HMAC<Insecure.MD5>.authenticationCode(for: message, using: key))
        }
    }
}
