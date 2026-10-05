import Foundation
import Testing
@testable import GoldenPassportCore

struct Base32Tests {
    @Test(arguments: [
        ("MY======", "f"), ("MZXQ====", "fo"), ("MZXW6===", "foo"), ("MZXW6YQ=", "foob"),
        ("MZXW6YTB", "fooba"), ("MZXW6YTBOI======", "foobar"),
    ])
    func rfc4648Vectors(encoded: String, decoded: String) {
        #expect(Base32.decode(encoded) == Data(decoded.utf8))
    }

    @Test func lenientInput() {
        #expect(Base32.decode("mzxw 6ytb-oi") == Data("foobar".utf8))
        #expect(Base32.decode("  MZXW6YTBOI\n") == Data("foobar".utf8))
    }

    @Test func rejectsInvalid() {
        #expect(Base32.decode("MZXW1") == nil)
        #expect(Base32.decode("") == nil)
        #expect(Base32.decode("====") == nil)
    }
}

struct TOTPTests {
    static let sha1Secret = Data("12345678901234567890".utf8)
    static let sha256Secret = Data("12345678901234567890123456789012".utf8)
    static let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    // RFC 6238 Appendix B.
    @Test(arguments: [
        (59.0, "94287082", "46119246", "90693936"),
        (1111111109.0, "07081804", "68084774", "25091201"),
        (1111111111.0, "14050471", "67062674", "99943326"),
        (1234567890.0, "89005924", "91819424", "93441116"),
        (2000000000.0, "69279037", "90698825", "38618901"),
        (20000000000.0, "65353130", "77737706", "47863826"),
    ])
    func rfc6238Vectors(time: Double, sha1: String, sha256: String, sha512: String) {
        let date = Date(timeIntervalSince1970: time)
        #expect(TOTP(secret: Self.sha1Secret, algorithm: .sha1, digits: 8).code(at: date) == sha1)
        #expect(TOTP(secret: Self.sha256Secret, algorithm: .sha256, digits: 8).code(at: date) == sha256)
        #expect(TOTP(secret: Self.sha512Secret, algorithm: .sha512, digits: 8).code(at: date) == sha512)
    }

    @Test func sixDigitsKeepsLeadingZeros() {
        let date = Date(timeIntervalSince1970: 1111111109)
        #expect(TOTP(secret: Self.sha1Secret).code(at: date) == "081804")
    }

    @Test func secondsRemaining() {
        let totp = TOTP(secret: Self.sha1Secret, period: 30)
        #expect(totp.secondsRemaining(at: Date(timeIntervalSince1970: 60)) == 30)
        #expect(totp.secondsRemaining(at: Date(timeIntervalSince1970: 89)) == 1)
    }
}

struct OTPAuthURLTests {
    @Test func parsesIssuerPrefixedLabel() throws {
        let url = try OTPAuthURL(string: "otpauth://totp/Amazon%20Web%20Services:alice@123456789012?secret=MZXW6YTBOI&issuer=Amazon%20Web%20Services")
        #expect(url.label == "Amazon Web Services:alice@123456789012")
        #expect(url.issuer == "Amazon Web Services")
        #expect(url.suggestedName == "Amazon Web Services:alice@123456789012")
        #expect(url.totp == TOTP(secret: Data("foobar".utf8)))
    }

    @Test func honoursParameters() throws {
        let url = try OTPAuthURL(string: "otpauth://totp/x?secret=MZXW6YTBOI&algorithm=sha256&digits=8&period=60")
        #expect(url.totp.algorithm == .sha256)
        #expect(url.totp.digits == 8)
        #expect(url.totp.period == 60)
    }

    @Test func toleratesWhitespaceAndRawSpaces() throws {
        let url = try OTPAuthURL(string: "  otpauth://totp/My Site:bob?secret=mzxw6ytboi \n")
        #expect(url.label == "My Site:bob")
    }

    @Test func labelWithoutIssuerFallsBackToIssuerParam() throws {
        #expect(try OTPAuthURL(string: "otpauth://totp/?secret=MZXW6YTBOI&issuer=Acme").suggestedName == "Acme")
    }

    @Test(arguments: [
        ("not a url at all", OTPAuthURLError.unsupportedScheme),
        ("https://example.com/?secret=MZXW6YTBOI", .unsupportedScheme),
        ("otpauth://hotp/x?secret=MZXW6YTBOI&counter=1", .unsupportedType("hotp")),
        ("otpauth://totp/x", .missingSecret),
        ("otpauth://totp/x?issuer=a", .missingSecret),
        ("otpauth://totp/x?secret=0189", .invalidSecret),
        ("otpauth://totp/x?secret=MZXW6YTBOI&digits=12", .invalidParameter("digits")),
        ("otpauth://totp/x?secret=MZXW6YTBOI&period=0", .invalidParameter("period")),
        ("otpauth://totp/x?secret=MZXW6YTBOI&algorithm=SHA3", .invalidParameter("algorithm")),
    ])
    func rejectsInvalid(input: String, expected: OTPAuthURLError) {
        #expect(throws: expected) { try OTPAuthURL(string: input) }
    }
}
