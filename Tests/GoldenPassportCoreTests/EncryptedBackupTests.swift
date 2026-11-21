import Foundation
import Testing
@testable import GoldenPassportCore

struct EncryptedBackupTests {
    static let accounts = [
        Account(name: "GitHub", url: "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
        Account(name: "阿里云 主账号", url: "otpauth://totp/Aliyun:bob?secret=MZXW6YTBOI&issuer=Aliyun&digits=8"),
        Account(name: "AWS", url: "otpauth://totp/AWS:carol?secret=KRSXG5CTMVRXEZLU&algorithm=SHA256&period=60"),
    ]
    static let password = "correct horse"
    /// The lowest count `open` accepts, so most tests don't spend 600,000 iterations each.
    static let fastIterations = 100_000

    private func sealFast(_ accounts: [Account] = Self.accounts, password: String = Self.password) throws -> Data {
        try EncryptedBackup.seal(accounts, password: password, iterations: Self.fastIterations)
    }

    private func header(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func changing(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try header(data)
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func changingSection(_ data: Data, _ section: String, _ key: String, to value: Any) throws -> Data {
        try changing(data) { object in
            var inner = object[section] as? [String: Any] ?? [:]
            inner[key] = value
            object[section] = inner
        }
    }

    private func expectError(_ expected: EncryptedBackupError, opening data: Data, password: String = Self.password,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            _ = try EncryptedBackup.open(data, password: password)
        }
    }

    private func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // RFC 7914 section 11 (PBKDF2-HMAC-SHA256), also checked against Python's hashlib.
    @Test func pbkdf2MatchesRFC7914() {
        #expect(EncryptedBackup.deriveKey(password: Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 64)
            == hex("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"))
        #expect(EncryptedBackup.deriveKey(password: Data("Password".utf8), salt: Data("NaCl".utf8), iterations: 80000, length: 64)
            == hex("4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"))
    }

    @Test func roundTripKeepsNamesURLsAndOrder() throws {
        let opened = try EncryptedBackup.open(try EncryptedBackup.seal(Self.accounts, password: Self.password),
                                              password: Self.password)
        #expect(opened.entries.map(\.name) == Self.accounts.map(\.name))
        #expect(opened.entries.map(\.url) == Self.accounts.map(\.url))
        #expect(opened.invalid == 0)
    }

    @Test func sealUsesTheDocumentedHeader() throws {
        let object = try header(try EncryptedBackup.seal(Self.accounts, password: Self.password))
        #expect(object["format"] as? String == "GoldenPassport encrypted backup")
        #expect(object["version"] as? Int == 1)
        let kdf = try #require(object["kdf"] as? [String: Any])
        #expect(kdf["name"] as? String == "PBKDF2-HMAC-SHA256")
        #expect(kdf["iterations"] as? Int == 600_000)
        #expect(Data(base64Encoded: kdf["salt"] as? String ?? "")?.count == 16)
        let cipher = try #require(object["cipher"] as? [String: Any])
        #expect(cipher["name"] as? String == "AES-256-GCM")
        #expect(Data(base64Encoded: cipher["nonce"] as? String ?? "")?.count == 12)
        #expect((Data(base64Encoded: object["ciphertext"] as? String ?? "")?.count ?? 0) > 16)
    }

    private func field(_ object: [String: Any], _ section: String?, _ key: String) -> String? {
        let container = section.map { object[$0] as? [String: Any] ?? [:] } ?? object
        return container[key] as? String
    }

    @Test func sealingTwiceGivesDifferentSaltNonceAndCiphertext() throws {
        let first = try header(try sealFast()), second = try header(try sealFast())
        for (section, key) in [("kdf", "salt"), ("cipher", "nonce")] {
            let a = field(first, section, key), b = field(second, section, key)
            #expect(a != nil && a != b, "\(section).\(key) repeats")
        }
        let a = field(first, nil, "ciphertext"), b = field(second, nil, "ciphertext")
        #expect(a != nil && a != b)
    }

    @Test func sealRefusesShortPasswords() {
        #expect(throws: EncryptedBackupError.passwordTooShort) {
            _ = try EncryptedBackup.seal(Self.accounts, password: "1234567")
        }
    }

    @Test func wrongPasswordFails() throws {
        expectError(.wrongPasswordOrDamaged, opening: try sealFast(), password: "correct horsE")
    }

    @Test func flippedCiphertextByteFails() throws {
        let sealed = try sealFast()
        var ciphertext = try #require(Data(base64Encoded: try header(sealed)["ciphertext"] as? String ?? ""))
        ciphertext[3] ^= 0x01
        expectError(.wrongPasswordOrDamaged, opening: try changing(sealed) { $0["ciphertext"] = ciphertext.base64EncodedString() })
    }

    @Test func changedIterationsFail() throws {
        expectError(.wrongPasswordOrDamaged, opening: try changingSection(try sealFast(), "kdf", "iterations", to: 100_001))
    }

    @Test func changedSaltFails() throws {
        expectError(.wrongPasswordOrDamaged,
                    opening: try changingSection(try sealFast(), "kdf", "salt", to: Data(repeating: 7, count: 16).base64EncodedString()))
    }

    @Test func truncatedCiphertextFails() throws {
        let sealed = try sealFast()
        let ciphertext = try #require(Data(base64Encoded: try header(sealed)["ciphertext"] as? String ?? ""))
        expectError(.wrongPasswordOrDamaged,
                    opening: try changing(sealed) { $0["ciphertext"] = ciphertext.dropLast(5).base64EncodedString() })
    }

    @Test func newerVersionIsReported() throws {
        let newer = try changing(try sealFast()) { $0["version"] = 2 }
        expectError(.newerVersion(2), opening: newer)
        #expect(throws: EncryptedBackupError.newerVersion(2)) { try EncryptedBackup.inspect(newer) }
    }

    @Test func unknownAlgorithmsAreReported() throws {
        let sealed = try sealFast()
        expectError(.unsupportedAlgorithm("scrypt"), opening: try changingSection(sealed, "kdf", "name", to: "scrypt"))
        expectError(.unsupportedAlgorithm("ChaCha20-Poly1305"),
                    opening: try changingSection(sealed, "cipher", "name", to: "ChaCha20-Poly1305"))
    }

    /// If the count were used, this test would run for many minutes.
    @Test func hugeIterationCountIsRejectedBeforeDeriving() throws {
        let hostile = try changingSection(try sealFast(), "kdf", "iterations", to: 1_000_000_000)
        expectError(.invalidParameters, opening: hostile)
        #expect(throws: EncryptedBackupError.invalidParameters) { try EncryptedBackup.inspect(hostile) }
        expectError(.invalidParameters, opening: try changingSection(try sealFast(), "kdf", "iterations", to: 99_999))
    }

    @Test func badLengthsAreRejected() throws {
        let sealed = try sealFast()
        expectError(.invalidParameters,
                    opening: try changingSection(sealed, "kdf", "salt", to: Data(repeating: 1, count: 8).base64EncodedString()))
        expectError(.invalidParameters,
                    opening: try changingSection(sealed, "cipher", "nonce", to: Data(repeating: 1, count: 16).base64EncodedString()))
        expectError(.invalidParameters, opening: try changing(sealed) { $0["ciphertext"] = Data(count: 8).base64EncodedString() })
    }

    @Test func otherFilesAreNotBackups() throws {
        for data in [Data("not json".utf8), Data("{\"accounts\": []}".utf8), Data("[1, 2]".utf8),
                     try changing(try sealFast()) { $0["format"] = "Something else" }] {
            expectError(.notABackup, opening: data)
            #expect(throws: EncryptedBackupError.notABackup) { try EncryptedBackup.inspect(data) }
        }
    }

    @Test func fileHoldsNoPlaintext() throws {
        let text = String(decoding: try sealFast(), as: UTF8.self)
        for needle in ["GitHub", "阿里云", "JBSWY3DPEHPK3PXP", "MZXW6YTBOI", "otpauth"] {
            #expect(!text.contains(needle), "the file shows \(needle)")
        }
    }

    @Test func nfdPasswordOpensNFCBackup() throws {
        let sealed = try sealFast(password: "caf\u{E9} au lait")
        #expect(try EncryptedBackup.open(sealed, password: "cafe\u{301} au lait").entries.count == Self.accounts.count)
    }

    @Test func unreadablePayloadIsReported() throws {
        let sealed = try EncryptedBackup.seal(payload: Data("not json".utf8), password: Self.password,
                                              iterations: Self.fastIterations)
        expectError(.unreadableContents, opening: sealed)
    }

    @Test func invalidURLsAreSkippedAndCounted() throws {
        let accounts = [Self.accounts[0], Account(name: "broken", url: "otpauth://totp/x?secret=1")]
        let opened = try EncryptedBackup.open(try sealFast(accounts), password: Self.password)
        #expect(opened.entries.map(\.name) == ["GitHub"])
        #expect(opened.invalid == 1)
    }

    @Test func writeIsOwnerOnly() throws {
        let url = try makeTempDirectory().appendingPathComponent("GoldenPassport.gpbackup")
        try EncryptedBackup.write(try sealFast(), to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
