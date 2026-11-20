import Foundation
import Testing
@testable import GoldenPassportCore

struct CodeSignatureTests {
    /// An ad-hoc signed bundle with /usr/bin/true as its executable.
    static func adHocBundle() throws -> URL {
        let app = try makeTempDirectory().appendingPathComponent("Probe.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources", isDirectory: true),
                                                withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.example.probe", "CFBundleExecutable": "probe",
                                  "CFBundlePackageType": "APPL"]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("probe"))
        let signed = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path], timeout: 60)
        try #require(signed.status == 0, "codesign: \(signed.output)")
        return app
    }

    @Test func designRequirementCompiles() throws {
        // Compiling proves this system accepts the wording, "notarized" included; CI runs it on macOS 15 and 26.
        try CodeSignature.compile(requirement: UpdatePackageCheck.requirement(bundleIdentifier: "com.thatscode.GoldenPassport",
                                                                              teamIdentifier: "928NN87B92"))
        #expect(throws: UpdateError.self) { try CodeSignature.compile(requirement: "identifier and and") }
    }

    @Test func adHocBundlesHaveNoTeamAndAreRejected() throws {
        let app = try Self.adHocBundle()
        #expect(CodeSignature.teamIdentifier(ofBundleAt: app) == nil)
        // The signature itself is intact: a requirement on the identifier alone passes.
        try CodeSignature.verify(bundleAt: app, requirement: #"identifier "com.example.probe""#)
        #expect(throws: UpdateError.self) {
            try CodeSignature.verify(bundleAt: app, requirement: UpdatePackageCheck.requirement(bundleIdentifier: "com.example.probe",
                                                                                                teamIdentifier: "928NN87B92"))
        }
    }

    @Test func tamperedBundlesAreRejected() throws {
        let app = try Self.adHocBundle()
        try Data("added later".utf8).write(to: app.appendingPathComponent("Contents/Resources/extra.txt"))
        #expect(throws: UpdateError.self) {
            try CodeSignature.verify(bundleAt: app, requirement: #"identifier "com.example.probe""#)
        }
    }

    @Test func unsignedOrMissingBundlesAreRejected() throws {
        let missing = try makeTempDirectory().appendingPathComponent("Nothing.app")
        #expect(CodeSignature.teamIdentifier(ofBundleAt: missing) == nil)
        #expect(throws: UpdateError.self) { try CodeSignature.verify(bundleAt: missing, requirement: #"identifier "x""#) }
    }
}
