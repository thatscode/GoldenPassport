import Foundation
import Testing
@testable import GoldenPassportCore

/// Builds protobuf bytes the way Google Authenticator's export does (MigrationPayload).
enum Protobuf {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }

    static func key(_ field: Int, _ wireType: Int) -> Data {
        varint(UInt64(field << 3 | wireType))
    }

    static func field(_ number: Int, varint value: Int) -> Data {
        key(number, 0) + varint(UInt64(bitPattern: Int64(value)))
    }

    static func field(_ number: Int, bytes: Data) -> Data {
        key(number, 2) + varint(UInt64(bytes.count)) + bytes
    }

    static func field(_ number: Int, string: String) -> Data {
        field(number, bytes: Data(string.utf8))
    }

    static func otp(secret: Data, name: String, issuer: String = "", algorithm: Int? = nil, digits: Int? = nil,
                    type: Int? = 2) -> Data {
        var data = field(1, bytes: secret) + field(2, string: name)
        if !issuer.isEmpty { data += field(3, string: issuer) }
        if let algorithm { data += field(4, varint: algorithm) }
        if let digits { data += field(5, varint: digits) }
        if let type { data += field(6, varint: type) }
        return data
    }

    static func payload(_ otps: [Data], batchSize: Int? = 1, batchIndex: Int? = 0, batchID: Int? = 7) -> Data {
        var data = Data()
        for otp in otps { data += field(1, bytes: otp) }
        data += field(2, varint: 1)
        if let batchSize { data += field(3, varint: batchSize) }
        if let batchIndex { data += field(4, varint: batchIndex) }
        if let batchID { data += field(5, varint: batchID) }
        return data
    }

    static func url(_ payload: Data, urlSafe: Bool = false, padded: Bool = true) -> String {
        var base64 = payload.base64EncodedString()
        if urlSafe { base64 = base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        if !padded { base64 = base64.replacingOccurrences(of: "=", with: "") }
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
        return "otpauth-migration://offline?data=\(encoded)"
    }
}

struct Base32EncodeTests {
    @Test(arguments: [("", ""), ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"), ("foob", "MZXW6YQ"),
                      ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI")])
    func rfc4648Vectors(decoded: String, encoded: String) {
        #expect(Base32.encode(Data(decoded.utf8)) == encoded)
    }

    @Test func roundTrips() {
        var generator = SystemRandomNumberGenerator()
        for length in 1...40 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            #expect(Base32.decode(Base32.encode(data)) == data)
        }
    }
}

struct ProtobufReaderTests {
    @Test func readsEveryWireType() throws {
        let data = Protobuf.field(1, varint: 300) + Protobuf.key(2, 1) + Data([1, 0, 0, 0, 0, 0, 0, 0])
            + Protobuf.field(3, string: "hi") + Protobuf.key(4, 5) + Data([2, 0, 0, 0])
        var reader = ProtobufReader(data)
        let expected: [(Int, ProtobufReader.Value)] = [(1, .varint(300)), (2, .fixed64(1)),
                                                       (3, .bytes(Data("hi".utf8))), (4, .fixed32(2))]
        for (field, value) in expected {
            let next = try #require(try reader.next())
            #expect(next.field == field)
            #expect(next.value == value)
        }
        #expect(try reader.next() == nil)
    }

    @Test func rejectsALengthPastTheEnd() {
        var reader = ProtobufReader(Protobuf.key(1, 2) + Protobuf.varint(10) + Data("abc".utf8))
        #expect(throws: ProtobufError.truncated) { _ = try reader.next() }
    }

    @Test func rejectsTruncatedFixedWidthValues() {
        var reader = ProtobufReader(Protobuf.key(1, 1) + Data([1, 2, 3]))
        #expect(throws: ProtobufError.truncated) { _ = try reader.next() }
    }

    @Test func rejectsVarintsLongerThanTenBytes() {
        var reader = ProtobufReader(Data(repeating: 0xFF, count: 11) + Data([1]))
        #expect(throws: ProtobufError.malformed) { _ = try reader.next() }
    }

    @Test func rejectsAVarintCutOff() {
        var reader = ProtobufReader(Protobuf.key(1, 0) + Data([0x80]))
        #expect(throws: ProtobufError.truncated) { _ = try reader.next() }
    }

    @Test(arguments: [3, 4, 6, 7])
    func rejectsGroupsAndUnknownWireTypes(wireType: Int) {
        var reader = ProtobufReader(Protobuf.key(1, wireType) + Data([0]))
        #expect(throws: ProtobufError.malformed) { _ = try reader.next() }
    }

    @Test func rejectsFieldNumberZero() {
        var reader = ProtobufReader(Protobuf.key(0, 0) + Data([1]))
        #expect(throws: ProtobufError.malformed) { _ = try reader.next() }
    }
}

struct GoogleAuthenticatorMigrationTests {
    static let secret = Data("12345678901234567890".utf8)

    private func parse(_ otps: [Data], batchSize: Int? = 1, batchIndex: Int? = 0, batchID: Int? = 7) throws -> MigrationBatch {
        try GoogleAuthenticatorMigration.parse(Protobuf.url(Protobuf.payload(otps, batchSize: batchSize,
                                                                               batchIndex: batchIndex, batchID: batchID)))
    }

    @Test func parsesOneAccountWithDefaults() throws {
        let batch = try parse([Protobuf.otp(secret: Self.secret, name: "alice@example.com", issuer: "Example", type: nil)])
        let account = try #require(batch.accounts.first)
        #expect(account.name == "alice@example.com")
        #expect(account.issuer == "Example")
        #expect(account.secret == Self.secret)
        #expect(account.algorithm == .sha1)
        #expect(account.digits == 6)
        #expect(account.problem == nil)
        #expect(account.label == "Example:alice@example.com")
    }

    @Test func labelsDontRepeatTheIssuer() throws {
        let batch = try parse([Protobuf.otp(secret: Self.secret, name: "Example:alice", issuer: "Example"),
                               Protobuf.otp(secret: Self.secret, name: "bob")])
        #expect(batch.accounts.map(\.label) == ["Example:alice", "bob"])
    }

    @Test func mapsAlgorithmsDigitsAndTypes() throws {
        let batch = try parse([
            Protobuf.otp(secret: Self.secret, name: "a", algorithm: 2, digits: 2),
            Protobuf.otp(secret: Self.secret, name: "b", algorithm: 3, digits: 1),
            Protobuf.otp(secret: Self.secret, name: "c", algorithm: 4),
            Protobuf.otp(secret: Self.secret, name: "d", type: 1),
            Protobuf.otp(secret: Self.secret, name: "e", algorithm: 9),
            Protobuf.otp(secret: Self.secret, name: "f", digits: 5),
            Protobuf.otp(secret: Self.secret, name: "g", type: 8),
            Protobuf.otp(secret: Data(), name: "h"),
        ])
        let accounts = batch.accounts
        #expect(accounts[0].algorithm == .sha256 && accounts[0].digits == 8 && accounts[0].problem == nil)
        #expect(accounts[1].algorithm == .sha512 && accounts[1].digits == 6)
        #expect(accounts[2].algorithm == .md5)
        #expect(accounts[3].problem == .hotp)
        #expect(accounts[4].problem == .unknownAlgorithm(9))
        #expect(accounts[5].problem == .unknownDigits(5))
        #expect(accounts[6].problem == .unknownType(8))
        #expect(accounts[7].problem == .emptySecret)
        #expect(accounts[3].otpauthURL == nil && accounts[7].otpauthURL == nil)
    }

    @Test func readsBatchInfo() throws {
        let batch = try parse([Protobuf.otp(secret: Self.secret, name: "a")], batchSize: 3, batchIndex: 1, batchID: 42)
        #expect(batch.batchSize == 3)
        #expect(batch.batchIndex == 1)
        #expect(batch.batchID == 42)
        let single = try parse([Protobuf.otp(secret: Self.secret, name: "a")], batchSize: nil, batchIndex: nil, batchID: nil)
        #expect(single.batchSize == 1 && single.batchIndex == 0)
    }

    @Test func acceptsURLSafeAndUnpaddedBase64() throws {
        // A secret whose base64 needs "+", "/" and padding.
        let otp = Protobuf.otp(secret: Data([0xFB, 0xFF, 0xBF, 0xFE, 0x01]), name: "x?y")
        for (urlSafe, padded) in [(false, true), (true, true), (true, false), (false, false)] {
            let url = Protobuf.url(Protobuf.payload([otp]), urlSafe: urlSafe, padded: padded)
            #expect(try GoogleAuthenticatorMigration.parse(url).accounts.first?.secret == Data([0xFB, 0xFF, 0xBF, 0xFE, 0x01]))
        }
    }

    @Test func recognizesMigrationURLs() {
        #expect(GoogleAuthenticatorMigration.isMigrationURL("otpauth-migration://offline?data=AA"))
        #expect(GoogleAuthenticatorMigration.isMigrationURL("  OTPAUTH-MIGRATION://offline?data=AA\n"))
        #expect(!GoogleAuthenticatorMigration.isMigrationURL("otpauth://totp/a?secret=MZXW6YTBOI"))
    }

    @Test func rejectsOtherURLsAndBrokenData() throws {
        #expect(throws: MigrationError.notAMigrationURL) {
            _ = try GoogleAuthenticatorMigration.parse("otpauth://totp/a?secret=MZXW6YTBOI")
        }
        let otp = Protobuf.otp(secret: Self.secret, name: "a")
        let payload = Protobuf.payload([otp])
        let broken = [
            "otpauth-migration://offline?data=%%%",
            "otpauth-migration://offline",
            "otpauth-migration://online?data=\(payload.base64EncodedString())",
            Protobuf.url(payload.dropLast(3)),
            Protobuf.url(Protobuf.key(1, 2) + Protobuf.varint(UInt64(otp.count)) + otp.dropLast(4)),
            Protobuf.url(Protobuf.field(1, bytes: Protobuf.key(1, 2) + Protobuf.varint(50) + Data([1, 2]))),
        ]
        for url in broken {
            #expect(throws: (any Error).self, "\(url)") { _ = try GoogleAuthenticatorMigration.parse(url) }
        }
        #expect(throws: MigrationError.invalidData) { _ = try GoogleAuthenticatorMigration.parse(Protobuf.url(payload.dropLast(3))) }
    }

    @Test func generatedURLsGiveTheSameCodes() throws {
        let cases: [(Int, Int, OTPAlgorithm, Int)] = [(1, 1, .sha1, 6), (2, 2, .sha256, 8), (3, 2, .sha512, 8), (4, 1, .md5, 6)]
        let otps = cases.map { Protobuf.otp(secret: Self.secret, name: "Alice & 张三 x", issuer: "My Co/Inc", algorithm: $0.0, digits: $0.1) }
        let batch = try parse(otps)
        for (account, (_, _, algorithm, digits)) in zip(batch.accounts, cases) {
            let parsed = try OTPAuthURL(string: try #require(account.otpauthURL))
            #expect(parsed.suggestedName == account.label)
            #expect(parsed.issuer == "My Co/Inc")
            let expected = TOTP(secret: Self.secret, algorithm: algorithm, digits: digits, period: 30)
            for time in [59.0, 1_111_111_109, 2_000_000_000] {
                let date = Date(timeIntervalSince1970: time)
                #expect(parsed.totp.code(at: date) == expected.code(at: date))
            }
        }
    }
}
