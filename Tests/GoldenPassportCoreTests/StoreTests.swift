import Foundation
import Testing
@testable import GoldenPassportCore

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gp-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let validURL = "otpauth://totp/Acme:alice?secret=MZXW6YTBOI&issuer=Acme"

struct AccountStoreTests {
    @Test func addPersistsInOrderAndRemove() throws {
        let dir = try makeTempDirectory()
        let store = AccountStore(directory: dir)
        try store.add(name: "b", url: validURL)
        let a = try store.add(name: " a ", url: "  \(validURL)\n")
        #expect(a.name == "a")
        #expect(a.url == validURL)

        let reloaded = AccountStore(directory: dir)
        #expect(reloaded.accounts.map(\.name) == ["b", "a"])

        try reloaded.remove(id: a.id)
        #expect(AccountStore(directory: dir).accounts.map(\.name) == ["b"])

        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(AccountStore.fileName).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func rejectsDuplicateEmptyAndInvalid() throws {
        let store = AccountStore(directory: try makeTempDirectory())
        try store.add(name: "a", url: validURL)
        #expect(throws: AccountStoreError.duplicateName("a")) { try store.add(name: "a", url: validURL) }
        #expect(throws: AccountStoreError.emptyName) { try store.add(name: "  ", url: validURL) }
        #expect(throws: OTPAuthURLError.missingSecret) { try store.add(name: "c", url: "otpauth://totp/x") }
        #expect(store.count == 1)
    }

    @Test func brokenEntryDoesNotBreakOthers() throws {
        let store = AccountStore(directory: try makeTempDirectory())
        try store.replaceAll(with: [Account(name: "bad", url: "garbage"), Account(name: "good", url: validURL)])
        let date = Date(timeIntervalSince1970: 1111111109)
        let codes = store.codes(at: date)
        #expect(codes.map(\.displayCode) == ["<无效密钥>", TOTP(secret: Data("foobar".utf8)).code(at: date)])
    }

    @Test func importSkipsExistingNames() throws {
        let store = AccountStore(directory: try makeTempDirectory())
        try store.add(name: "a", url: validURL)
        let added = try store.importAccounts([(name: "a", url: "x"), (name: "b", url: validURL)])
        #expect(added == 1)
        #expect(store.accounts.map(\.name) == ["a", "b"])
        #expect(store.accounts[0].url == validURL)
    }
}

struct MigrationTests {
    func writeLegacy(_ dictionary: [String: String], to url: URL) throws {
        // Same call the 0.1.7 app used: NSKeyedArchiver.archivedData(withRootObject:)
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSMutableDictionary(dictionary: dictionary),
                                                    requiringSecureCoding: false)
        try data.write(to: url)
    }

    @Test func legacyRoundTrip() throws {
        let file = try makeTempDirectory().appendingPathComponent("x.secrets")
        try LegacyData.writeDictionary(["a": validURL], to: file)
        #expect(try LegacyData.readDictionary(at: file) == ["a": validURL])
    }

    @Test func releaseMigratesInPlaceAndKeepsLegacyFiles() throws {
        let dir = try makeTempDirectory()
        try writeLegacy(["zeta": validURL, "Alpha": validURL, "beta": validURL],
                        to: dir.appendingPathComponent(LegacyData.secretsFileName))
        try writeLegacy(["http_server_auto_start": "false", "http_server_port": "18000"],
                        to: dir.appendingPathComponent(LegacyData.configFileName))

        let env = AppEnvironment(dataDirectory: dir, seedDirectory: nil,
                                 defaults: .init(httpPort: 17304, hotkeysEnabled: true))
        try env.prepareDataDirectory()

        #expect(AccountStore(directory: dir).accounts.map(\.name) == ["Alpha", "beta", "zeta"])
        let settings = SettingsStore(directory: dir, defaults: env.defaults)
        #expect(settings.httpServerAutoStart == false)
        #expect(settings.httpServerPort == 18000)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(LegacyData.secretsFileName).path))

        // A second launch must not re-import over user changes.
        try AccountStore(directory: dir).replaceAll(with: [])
        try env.prepareDataDirectory()
        #expect(AccountStore(directory: dir).count == 0)
    }

    @Test func devSeedsFromCopyWithoutTouchingSource() throws {
        let seed = try makeTempDirectory()
        let seedFile = seed.appendingPathComponent(LegacyData.secretsFileName)
        try writeLegacy(["a": validURL], to: seedFile)
        try writeLegacy(["http_server_port": "18000"], to: seed.appendingPathComponent(LegacyData.configFileName))
        let before = try Data(contentsOf: seedFile)
        let seedListing = try FileManager.default.contentsOfDirectory(atPath: seed.path).sorted()

        let dev = try makeTempDirectory().appendingPathComponent("Dev")
        let env = AppEnvironment(dataDirectory: dev, seedDirectory: seed,
                                 defaults: .init(httpPort: 17305, hotkeysEnabled: false))
        try env.prepareDataDirectory()

        #expect(AccountStore(directory: dev).accounts.map(\.name) == ["a"])
        #expect(SettingsStore(directory: dev, defaults: env.defaults).httpServerPort == 17305)
        #expect(SettingsStore(directory: dev, defaults: env.defaults).hotkeysEnabled == false)
        #expect(try Data(contentsOf: seedFile) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: seed.path).sorted() == seedListing)
    }
}

struct AccountEditingTests {
    func store(_ names: [String]) throws -> (AccountStore, URL) {
        let dir = try makeTempDirectory()
        let store = AccountStore(directory: dir)
        for name in names { try store.add(name: name, url: validURL) }
        return (store, dir)
    }

    @Test func renamePersistsAndKeepsPosition() throws {
        let (store, dir) = try store(["a", "b", "c"])
        try store.rename(id: store.accounts[1].id, to: "  B2 ")
        #expect(AccountStore(directory: dir).accounts.map(\.name) == ["a", "B2", "c"])
    }

    @Test func renameToOwnNameIsAllowed() throws {
        let (store, _) = try store(["a"])
        try store.rename(id: store.accounts[0].id, to: "a")
        #expect(store.accounts.map(\.name) == ["a"])
    }

    @Test func renameRejectsDuplicateAndEmpty() throws {
        let (store, _) = try store(["a", "b"])
        let id = store.accounts[1].id
        #expect(throws: AccountStoreError.duplicateName("a")) { try store.rename(id: id, to: "a") }
        #expect(throws: AccountStoreError.emptyName) { try store.rename(id: id, to: " ") }
        #expect(store.accounts.map(\.name) == ["a", "b"])
    }

    @Test func updateURLValidates() throws {
        let (store, _) = try store(["a"])
        let id = store.accounts[0].id
        let newURL = "otpauth://totp/x?secret=MZXW6YTBOI&digits=8"
        try store.updateURL(id: id, to: " \(newURL)\n")
        #expect(store.accounts[0].url == newURL)
        #expect(throws: OTPAuthURLError.missingSecret) { try store.updateURL(id: id, to: "otpauth://totp/x") }
        #expect(store.accounts[0].url == newURL)
    }

    @Test(arguments: [
        (IndexSet([0]), 3, ["b", "c", "a"]),
        (IndexSet([2]), 0, ["c", "a", "b"]),
        (IndexSet([0, 1]), 3, ["c", "a", "b"]),
    ])
    func moveMatchesSwiftUISemantics(source: IndexSet, destination: Int, expected: [String]) throws {
        let (store, dir) = try store(["a", "b", "c"])
        try store.move(fromOffsets: source, toOffset: destination)
        #expect(AccountStore(directory: dir).accounts.map(\.name) == expected)
    }

    @Test func unknownIDThrows() throws {
        let (store, _) = try store(["a"])
        #expect(throws: AccountStoreError.notFound) { try store.rename(id: UUID(), to: "x") }
    }
}

struct SettingsTests {
    @Test func hotkeyDefaultsAndPersistence() throws {
        let dir = try makeTempDirectory()
        let defaults = AppEnvironment.Defaults(httpPort: 17304, hotkeysEnabled: true)
        let settings = SettingsStore(directory: dir, defaults: defaults)
        #expect(settings.hotkeyModifiers == .controlOptionCommand)
        #expect(settings.hotkeysEnabled)
        settings.hotkeyModifiers = .shiftCommand
        settings.hotkeysEnabled = false
        let reloaded = SettingsStore(directory: dir, defaults: defaults)
        #expect(reloaded.hotkeyModifiers == .shiftCommand)
        #expect(reloaded.hotkeysEnabled == false)
    }

    @Test func hotkeyDigitsFollowLegacyNumbering() {
        #expect(HotkeyModifiers.digit(forAccountAt: 0) == 0)
        #expect(HotkeyModifiers.digit(forAccountAt: 9) == 9)
        #expect(HotkeyModifiers.digit(forAccountAt: 10) == nil)
    }
}

struct OTPAuthListTests {
    @Test func roundTripKeepsNamesAndOrder() {
        let accounts = [Account(name: "renamed", url: validURL), Account(name: "b", url: "otpauth://totp/B?secret=MZXW6YTBOI")]
        let parsed = OTPAuthList.parse(OTPAuthList.render(accounts))
        #expect(parsed.entries.map(\.name) == ["renamed", "b"])
        #expect(parsed.entries.map(\.url) == accounts.map(\.url))
        #expect(parsed.invalidLines.isEmpty)
    }

    @Test func plainURLListUsesLabelsAndReportsBadLines() {
        let text = """
        otpauth://totp/Acme:alice?secret=MZXW6YTBOI
        not-a-url
        # orphan comment

        # named
        otpauth://totp/x?secret=MZXW6YTBOI
        otpauth://totp/x?secret=bad!
        """
        let parsed = OTPAuthList.parse(text)
        #expect(parsed.entries.map(\.name) == ["Acme:alice", "named"])
        #expect(parsed.invalidLines == [2, 7])
    }
}
