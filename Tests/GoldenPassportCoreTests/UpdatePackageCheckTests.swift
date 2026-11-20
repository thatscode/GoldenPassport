import Foundation
import Testing
@testable import GoldenPassportCore

struct UpdatePackageCheckTests {
    static let url = URL(string: "https://download.example/gp.zip")!
    /// SHA-256 of "0123456789", from `printf 0123456789 | shasum -a 256`.
    static let digitsSHA256 = "84d89877f0d4041efb6bf91a16f0248f2fd573e6af05c19f96bedb9f882f7882"

    static func file(_ contents: String) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("package.zip")
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: Download

    @Test func acceptsMatchingSizeAndDigest() throws {
        try UpdatePackageCheck.verifyDownload(at: Self.file("0123456789"),
                                              package: UpdatePackage(url: Self.url, size: 10, sha256: Self.digitsSHA256))
    }

    @Test func sizeOrDigestMayBeMissing() throws {
        try UpdatePackageCheck.verifyDownload(at: Self.file("0123456789"), package: UpdatePackage(url: Self.url, size: nil, sha256: nil))
    }

    @Test func rejectsWrongSize() throws {
        let file = try Self.file("01234")
        #expect(throws: UpdateError.sizeMismatch(expected: 10, actual: 5)) {
            try UpdatePackageCheck.verifyDownload(at: file, package: UpdatePackage(url: Self.url, size: 10, sha256: nil))
        }
    }

    @Test func rejectsWrongDigest() throws {
        let file = try Self.file("0123456788")
        #expect(throws: UpdateError.digestMismatch) {
            try UpdatePackageCheck.verifyDownload(at: file, package: UpdatePackage(url: Self.url, size: 10, sha256: Self.digitsSHA256))
        }
    }

    @Test func captivePortalPageFailsTheSizeCheck() throws {
        let file = try Self.file("<html>login</html>")
        #expect(throws: UpdateError.sizeMismatch(expected: 3091969, actual: 18)) {
            try UpdatePackageCheck.verifyDownload(at: file, package: UpdatePackage(url: Self.url, size: 3091969, sha256: Self.digitsSHA256))
        }
        #expect(UpdateError.sizeMismatch(expected: 1, actual: 2).isNetworkProblem)
        #expect(UpdateError.digestMismatch.isNetworkProblem)
        #expect(UpdateError.download("offline").isNetworkProblem)
        #expect(!UpdateError.signature("x").isNetworkProblem)
        #expect(!UpdateError.appNotFound.isNetworkProblem)
    }

    // MARK: Unpacked layout

    static func unpacked(_ relativeApps: [String]) throws -> URL {
        let dir = try makeTempDirectory()
        for path in relativeApps {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(path, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        return dir
    }

    @Test func findsTheAppInTheVersionFolder() throws {
        let dir = try Self.unpacked(["GoldenPassport-0.2.4/GoldenPassport.app"])
        let found = try UpdatePackageCheck.findApp(inUnpacked: dir, version: #require(AppVersion("0.2.4")))
        #expect(found.path == dir.appendingPathComponent("GoldenPassport-0.2.4/GoldenPassport.app").path)
    }

    @Test(arguments: [[String](), ["GoldenPassport-0.2.4/GoldenPassport.app", "GoldenPassport.app"],
                      ["GoldenPassport-0.2.3/GoldenPassport.app"], ["GoldenPassport-0.2.4/Other.app"]])
    func rejectsMissingExtraOrMisplacedApps(apps: [String]) throws {
        let dir = try Self.unpacked(apps)
        let version = try #require(AppVersion("0.2.4"))
        #expect(throws: UpdateError.appNotFound) { try UpdatePackageCheck.findApp(inUnpacked: dir, version: version) }
    }

    // MARK: Info.plist

    static func expectations(current: String = "0.2.3") -> UpdatePackageCheck.Expectations {
        UpdatePackageCheck.Expectations(bundleIdentifier: "com.thatscode.GoldenPassport",
                                        version: AppVersion("0.2.4")!,
                                        current: AppVersion(current)!,
                                        dataDirectoryName: "GoldenPassport",
                                        keychainService: "site.stanzhai.GoldenPassport",
                                        systemVersion: AppVersion("13.6.1")!,
                                        architecture: "arm64")
    }

    static let validInfo: [String: Any] = [
        "CFBundleIdentifier": "com.thatscode.GoldenPassport",
        "CFBundleShortVersionString": "0.2.4",
        "GPDataDirectoryName": "GoldenPassport",
        "GPKeychainService": "site.stanzhai.GoldenPassport",
        "LSMinimumSystemVersion": "13.0",
    ]

    @Test func acceptsTheExpectedBundle() throws {
        try UpdatePackageCheck.checkInfo(Self.validInfo, architectures: ["arm64", "x86_64"], expectations: Self.expectations())
    }

    static func changed(_ key: String, _ value: Any?) -> [String: Any] {
        var info = validInfo
        info[key] = value
        return info
    }

    @Test func rejectsEachMismatch() throws {
        let cases: [(info: [String: Any], architectures: [String], current: String, error: UpdateError)] = [
            (Self.changed("CFBundleIdentifier", "com.thatscode.GoldenPassport.dev"), ["arm64"], "0.2.3", .wrongPackage("CFBundleIdentifier")),
            (Self.changed("GPPrerelease", "rc.1"), ["arm64"], "0.2.3", .wrongPackage("version")),
            (Self.changed("GPDataDirectoryName", "GoldenPassport-Dev"), ["arm64"], "0.2.3", .wrongPackage("GPDataDirectoryName")),
            (Self.changed("GPKeychainService", nil), ["arm64"], "0.2.3", .wrongPackage("GPKeychainService")),
            (Self.changed("LSMinimumSystemVersion", "99.0"), ["arm64"], "0.2.3", .needsNewerSystem("99.0")),
            (Self.validInfo, ["x86_64"], "0.2.3", .missingArchitecture("arm64")),
            (Self.validInfo, ["arm64"], "0.2.4", .notNewer),
        ]
        for item in cases {
            #expect(throws: item.error) {
                try UpdatePackageCheck.checkInfo(item.info, architectures: item.architectures,
                                                 expectations: Self.expectations(current: item.current))
            }
        }
    }

    @Test func treatsAnEmptyKeychainServiceAsNone() throws {
        var expectations = Self.expectations()
        expectations.keychainService = nil
        try UpdatePackageCheck.checkInfo(Self.changed("GPKeychainService", ""), architectures: ["arm64"], expectations: expectations)
    }

    // MARK: Mach-O

    static func bigEndian(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }

    static func littleEndian(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }

    static func executable(_ bytes: [UInt8]) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("exe")
        try Data(bytes + [UInt8](repeating: 0, count: 64)).write(to: url)
        return url
    }

    @Test func readsFatAndThinMachOHeaders() throws {
        // fat_header {0xcafebabe, 2}, then fat_arch {cputype, cpusubtype, offset, size, align} × 2.
        let fat = Self.bigEndian([0xcafe_babe, 2, 0x0100_0007, 3, 0x4000, 0x100, 14, 0x0100_000c, 0, 0x8000, 0x100, 14])
        #expect(try UpdatePackageCheck.architectures(ofExecutableAt: Self.executable(fat)) == ["x86_64", "arm64"])
        // mach_header_64 {magic 0xfeedfacf, cputype arm64, …}, little-endian on disk.
        let thin = Self.littleEndian([0xfeed_facf, 0x0100_000c, 0, 2])
        #expect(try UpdatePackageCheck.architectures(ofExecutableAt: Self.executable(thin)) == ["arm64"])
        let script = try Self.executable(Array("#!/bin/sh\necho hi\n".utf8))
        #expect(throws: UpdateError.self) { try UpdatePackageCheck.architectures(ofExecutableAt: script) }
    }

    @Test func currentArchitectureIsOneThePackageCanHave() {
        #expect(["arm64", "x86_64"].contains(UpdatePackageCheck.currentArchitecture))
    }

    // MARK: Signature requirement

    @Test func requirementMatchesTheDesign() {
        #expect(UpdatePackageCheck.requirement(bundleIdentifier: "com.thatscode.GoldenPassport", teamIdentifier: "928NN87B92")
            == #"anchor apple generic and identifier "com.thatscode.GoldenPassport" and certificate leaf[subject.OU] = "928NN87B92" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and notarized"#)
        #expect(UpdatePackageCheck.requirement(bundleIdentifier: #"a"b\c"#, teamIdentifier: "T").contains(#"identifier "a\"b\\c""#))
    }
}
