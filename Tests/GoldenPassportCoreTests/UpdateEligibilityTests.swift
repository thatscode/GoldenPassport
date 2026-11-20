import Foundation
import Testing
@testable import GoldenPassportCore

struct UpdateEligibilityTests {
    static let package = UpdatePackage(url: URL(string: "https://download.example/gp.zip")!, size: 3091969, sha256: nil)
    static let bundle = URL(fileURLWithPath: "/Applications/GoldenPassport.app")

    static func update(notices: [AvailableUpdate.Notice] = [], package: UpdatePackage? = UpdateEligibilityTests.package) -> AvailableUpdate {
        AvailableUpdate(version: "0.2.4", releasePage: URL(string: "https://github.com/o/r/releases/tag/v0.2.4")!,
                        notices: notices, package: package)
    }

    static func app(team: String? = "928NN87B92", translocated: Bool = false, canReplace: Bool = true) -> RunningApp {
        RunningApp(bundleURL: bundle, teamIdentifier: team, isTranslocated: translocated, canReplace: canReplace)
    }

    @Test func installsWhenEverythingAllows() {
        #expect(Self.update().action(for: Self.app()) == .install(Self.package))
    }

    @Test func releaseNoticesComeFirst() {
        let action = Self.update(notices: [.dataFormatChange], package: nil)
            .action(for: Self.app(team: nil, translocated: true, canReplace: false))
        #expect(action == .releasePageOnly(.releaseNeedsInstaller))
    }

    @Test(arguments: [AvailableUpdate.Notice.compatibilityUnknown, .dataFormatChange,
                      .upgradeFirst(version: "0.2.3", releasePage: URL(string: "https://github.com/o/r/releases/tag/v0.2.3")!)])
    func anyNoticeBlocks(notice: AvailableUpdate.Notice) {
        #expect(Self.update(notices: [notice]).action(for: Self.app()) == .releasePageOnly(.releaseNeedsInstaller))
    }

    @Test func missingPackageBlocks() {
        #expect(Self.update(package: nil).action(for: Self.app(team: nil)) == .releasePageOnly(.noPackage))
    }

    @Test func adHocBuildsCannotUpdate() {
        #expect(Self.update().action(for: Self.app(team: nil, translocated: true)) == .releasePageOnly(.notReleaseBuild))
    }

    @Test func translocatedCopiesCannotUpdate() {
        #expect(Self.update().action(for: Self.app(translocated: true, canReplace: false)) == .releasePageOnly(.translocated))
    }

    @Test func readOnlyLocationsCannotUpdate() {
        #expect(Self.update().action(for: Self.app(canReplace: false))
            == .releasePageOnly(.notWritable(path: "/Applications/GoldenPassport.app")))
    }

    @Test func inspectDetectsTranslocation() {
        let url = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/GoldenPassport.app")
        let app = RunningApp.inspect(bundleURL: url, teamIdentifier: "T")
        #expect(app.isTranslocated)
        #expect(app.teamIdentifier == "T")
        #expect(!RunningApp.inspect(bundleURL: Self.bundle, teamIdentifier: "T").isTranslocated)
    }

    @Test func inspectChecksBothFolderAndBundle() throws {
        let folder = try makeTempDirectory()
        let app = folder.appendingPathComponent("X.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        }
        #expect(RunningApp.inspect(bundleURL: app, teamIdentifier: "T").canReplace)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(!RunningApp.inspect(bundleURL: app, teamIdentifier: "T").canReplace)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
        #expect(!RunningApp.inspect(bundleURL: app, teamIdentifier: "T").canReplace)
    }

    @Test func inspectResolvesSymlinks() throws {
        let folder = try makeTempDirectory()
        let app = folder.appendingPathComponent("X.app", isDirectory: true)
        let link = folder.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let inspected = RunningApp.inspect(bundleURL: link, teamIdentifier: "T")
        #expect(inspected.bundleURL.lastPathComponent == "X.app")
        #expect(inspected.bundleURL.path == app.resolvingSymlinksInPath().path)
    }
}
