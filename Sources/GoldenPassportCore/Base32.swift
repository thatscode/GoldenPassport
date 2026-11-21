import Foundation

/// RFC 4648 Base32. Decoding is lenient about case, whitespace, dashes and padding
/// (secrets are often shown as "abcd efgh ijkl ..." by websites).
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let table: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() {
            table[c] = UInt8(i)
        }
        return table
    }()

    public static func decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
        guard !cleaned.isEmpty else { return nil }

        var output = Data()
        var buffer: UInt32 = 0
        var bitCount = 0
        for c in cleaned {
            guard let value = table[c] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> UInt32(bitCount)) & 0xFF))
            }
            buffer &= (1 << UInt32(bitCount)) - 1
        }
        return output
    }

    /// Uppercase, without padding, as otpauth URLs carry secrets.
    public static func encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bitCount = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(alphabet[Int((buffer >> UInt32(bitCount)) & 0x1F)])
            }
            buffer &= (1 << UInt32(bitCount)) - 1
        }
        if bitCount > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 0x1F)])
        }
        return output
    }
}
