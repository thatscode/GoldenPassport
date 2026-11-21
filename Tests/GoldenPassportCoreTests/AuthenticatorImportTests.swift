import Foundation
import Testing
@testable import GoldenPassportCore

struct AuthenticatorImportTests {
    static let secretA = Data("12345678901234567890".utf8)
    static let secretB = Data("abcdefghijabcdefghij".utf8)
    static let secretC = Data("ABCDEFGHIJABCDEFGHIJ".utf8)

    private func link(_ label: String, _ secret: Data, digits: Int = 6) -> String {
        "otpauth://totp/\(label)?secret=\(Base32.encode(secret))&digits=\(digits)"
    }

    private func migration(_ otps: [Data], batchSize: Int = 1, batchIndex: Int = 0, batchID: Int = 7) -> String {
        Protobuf.url(Protobuf.payload(otps, batchSize: batchSize, batchIndex: batchIndex, batchID: batchID))
    }

    @Test func newAccountsAreSelected() {
        var importer = AuthenticatorImport(existing: [])
        #expect(importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "alice", issuer: "GitHub"),
                                                 Protobuf.otp(secret: Self.secretB, name: "bob")])) == .added(2))
        #expect(importer.candidates.map(\.name) == ["GitHub:alice", "bob"])
        #expect(importer.candidates.map(\.status) == [.new, .new])
        #expect(importer.candidates.allSatisfy { $0.isSelected })
        #expect(importer.candidates[0].issuer == "GitHub")
    }

    @Test func sameSecretAsAnExistingAccountIsUnselectedExists() {
        let existing = [Account(name: "My GitHub", url: link("GitHub:alice", Self.secretA))]
        var importer = AuthenticatorImport(existing: existing)
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "alice", issuer: "GitHub")]))
        #expect(importer.candidates.first?.status == .exists("My GitHub"))
        #expect(importer.candidates.first?.isSelected == false)
        #expect(importer.entries.isEmpty)
    }

    @Test func differentDigitsIsNotTheSameAccount() {
        var importer = AuthenticatorImport(existing: [Account(name: "x", url: link("x", Self.secretA, digits: 8))])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "y")]))
        #expect(importer.candidates.first?.status == .new)
    }

    @Test func nameClashesGetANumber() {
        let existing = [Account(name: "bob", url: link("bob", Self.secretC)),
                        Account(name: "carol (2)", url: link("carol", Self.secretC, digits: 8))]
        var importer = AuthenticatorImport(existing: existing)
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "bob"),
                                             Protobuf.otp(secret: Self.secretA, name: "carol", issuer: "", algorithm: 2),
                                             Protobuf.otp(secret: Self.secretB, name: "carol")]))
        #expect(importer.candidates.map(\.name) == ["bob (2)", "carol", "carol (3)"])
        #expect(importer.candidates.map(\.status) == [.renamed("bob"), .new, .renamed("carol")])
        #expect(importer.nameIssue == nil)
    }

    @Test func readingTheSameCodeTwiceAddsNothing() {
        var importer = AuthenticatorImport(existing: [])
        let code = migration([Protobuf.otp(secret: Self.secretA, name: "alice")])
        #expect(importer.add(payload: code) == .added(1))
        #expect(importer.add(payload: "  \(code)\n") == .alreadyRead)
        #expect(importer.candidates.count == 1)
    }

    @Test func theSameAccountFromAMigrationCodeAndALinkIsOneRow() {
        var importer = AuthenticatorImport(existing: [])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "alice", issuer: "GitHub")]))
        #expect(importer.add(payload: link("GitHub:alice", Self.secretA)) == .alreadyRead)
        #expect(importer.candidates.count == 1)
    }

    @Test func unsupportedRowsCannotBeSelected() throws {
        var importer = AuthenticatorImport(existing: [])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "counter", type: 1)]))
        let row = try #require(importer.candidates.first)
        #expect(row.status == .unsupported(.hotp))
        #expect(!row.isSelected && row.url == nil)
        importer.setSelected(true, for: row.id)
        #expect(importer.candidates.first?.isSelected == false)
        #expect(importer.entries.isEmpty)
    }

    @Test func entriesKeepOrderAndSkipUnselected() throws {
        var importer = AuthenticatorImport(existing: [])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "a"),
                                             Protobuf.otp(secret: Self.secretB, name: "b"),
                                             Protobuf.otp(secret: Self.secretC, name: "c")]))
        importer.setSelected(false, for: importer.candidates[1].id)
        importer.setName("  renamed c ", for: importer.candidates[2].id)
        #expect(importer.entries.map(\.name) == ["a", "renamed c"])
        let url = try #require(importer.entries.last?.url)
        #expect(try OTPAuthURL(string: url).totp.secret == Self.secretC)
    }

    @Test func nameIssuesPointAtTheRow() {
        var importer = AuthenticatorImport(existing: [Account(name: "taken", url: link("taken", Self.secretC))])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "a"),
                                             Protobuf.otp(secret: Self.secretB, name: "b")]))
        let first = importer.candidates[0].id, second = importer.candidates[1].id
        importer.setName("   ", for: second)
        #expect(importer.nameIssue == .empty(row: 2))
        importer.setName("a", for: second)
        #expect(importer.nameIssue == .duplicate(row: 2, name: "a"))
        importer.setName("taken", for: first)
        #expect(importer.nameIssue == .duplicate(row: 1, name: "taken"))
        importer.setSelected(false, for: first)
        #expect(importer.nameIssue == nil)
    }

    @Test func batchProgressListsMissingCodes() {
        var importer = AuthenticatorImport(existing: [])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "a")], batchSize: 3, batchIndex: 0, batchID: 42))
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretC, name: "c")], batchSize: 3, batchIndex: 2, batchID: 42))
        #expect(importer.batches.map(\.missing) == [[2]])
        #expect(importer.batches.first?.size == 3)
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretB, name: "b")], batchSize: 3, batchIndex: 1, batchID: 42))
        #expect(importer.batches.map(\.missing) == [[]])
    }

    @Test func singleCodesHaveNoBatchToTrack() {
        var importer = AuthenticatorImport(existing: [])
        _ = importer.add(payload: migration([Protobuf.otp(secret: Self.secretA, name: "a")]))
        #expect(importer.batches.isEmpty)
    }

    @Test func textWithSeveralLines() {
        var importer = AuthenticatorImport(existing: [])
        let text = """
        \(link("one", Self.secretA))

        \(migration([Protobuf.otp(secret: Self.secretB, name: "two"), Protobuf.otp(secret: Self.secretC, name: "three")]))
        hello
        otpauth://hotp/x?secret=MZXW6YTBOI&counter=1
        """
        let results = importer.add(text: text)
        #expect(results.count == 4)
        #expect(Array(results.prefix(3)) == [.added(1), .added(2), .notAnAccount])
        if case .invalid = results[3] {} else { Issue.record("an hotp link should be reported as invalid, got \(results[3])") }
        #expect(importer.candidates.map(\.name) == ["one", "two", "three"])
    }

    @Test func invalidMigrationDataIsReported() {
        var importer = AuthenticatorImport(existing: [])
        let result = importer.add(payload: "otpauth-migration://offline?data=AAAA%2F")
        if case .invalid = result {} else { Issue.record("expected .invalid, got \(result)") }
        #expect(importer.candidates.isEmpty)
    }

    @Test func linksWithoutALabelGetAPlaceholderName() {
        var importer = AuthenticatorImport(existing: [])
        _ = importer.add(payload: "otpauth://totp/?secret=\(Base32.encode(Self.secretA))")
        _ = importer.add(payload: "otpauth://totp/?secret=\(Base32.encode(Self.secretB))")
        let names = importer.candidates.map(\.name)
        #expect(names.count == 2 && names[0] != names[1] && !names[0].isEmpty)
        #expect(importer.nameIssue == nil)
    }
}
